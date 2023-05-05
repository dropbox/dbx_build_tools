package main

// SvcInit is a wrapper process which launches services required by a test (as defined in a service
// definitions file) and executes a test binary. When not given a test binary, if
// --svc.services-only is passed, it exits and leaves the service controller and services
// running. If --svc.services-only is not passed, it errors out in that case.

import (
	"flag"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	// We can't use the suggested dropbox/protobuf/proto package here because
	// we want to easily be able to export to the open-source dbx_build_tools.
	// See the open-source-bazel-validation project on Changes.
	"github.com/gogo/protobuf/proto"

	"dropbox/build_tools/junit"
	"dropbox/build_tools/svcctl"
	"dropbox/build_tools/svcctl/svclib"
	svclib_proto "dropbox/proto/build_tools/svclib"
	"dropbox/runfiles"
)

func performCleanups(cleanups []func() error, insideBazelTest bool) {
	// do not perform clean up if this is not inside bazel test, to let developers
	// inspect the services as is
	if !insideBazelTest {
		return
	}
	for i := len(cleanups) - 1; i >= 0; i-- {
		_ = cleanups[i]()
	}
}

func copyFile(dst, src string) error {
	content, err := ioutil.ReadFile(src)
	if err != nil {
		return fmt.Errorf("can't open file for reading: %w", err)
	}
	return ioutil.WriteFile(dst, content, 0644)
}

type serviceResult struct {
	name           string
	startDuration  time.Duration
	failed         bool
	failureMessage *svclib_proto.StatusResp_FailureMessage
	cpuTime        time.Duration
	rssMb          int64
}

func getServiceStatusAndDiagnostics() ([]serviceResult, error) {
	svcStatus, svcStatusErr := svclib.StatusAll()
	if svcStatusErr != nil {
		// This typically means svcd is dead - might as well give up here
		return nil, svcStatusErr
	}

	svcDiagnostics, svcDiagnosticsErr := svclib.DiagnosticsAll()
	if svcDiagnosticsErr != nil {
		return nil, svcStatusErr
	}

	svcDiagnosticsMapping := make(map[string]*svclib_proto.DiagnosticsResp_Metrics)
	for _, svc := range svcDiagnostics {
		svcDiagnosticsMapping[svc.GetServiceName()] = svc
	}

	var result []serviceResult
	for _, svc := range svcStatus {
		var cpuTime time.Duration
		var rssMb int64
		metrics := svcDiagnosticsMapping[svc.GetServiceName()]
		if metrics != nil {
			cpuTime = time.Duration(metrics.GetCpuTimeMs()) * time.Millisecond
			rssMb = metrics.GetRssMb()
		}

		result = append(result, serviceResult{
			name:           svc.GetServiceName(),
			startDuration:  time.Duration(svc.GetStartDurationMs()) * time.Millisecond,
			failed:         svc.GetStatusCode() == svclib_proto.StatusResp_ERROR,
			failureMessage: svc.GetFailureMessage(),
			cpuTime:        cpuTime,
			rssMb:          rssMb,
		})
	}

	return result, nil
}

type serviceResults []serviceResult

func (s serviceResults) Err() error {
	var failingServiceNames []string
	for _, svc := range s {
		if svc.failed {
			failingServiceNames = append(failingServiceNames, svc.name)
		}
	}
	if len(failingServiceNames) == 0 {
		return nil
	}
	sort.Strings(failingServiceNames)
	return fmt.Errorf("Services unhealthy: %v", failingServiceNames)
}

func (s serviceResults) AnyFailed() bool {
	return s.Err() != nil
}

func junitTestcasesForServices(testTarget string, services []serviceResult) []junit.JUnitTestCase {
	var additionalTests []junit.JUnitTestCase

	for _, svc := range services {
		failMsg := ""
		if svc.failed {
			failMsg = fmt.Sprintf("Service %s failed\nhttps://dbx.link/effective-integration-testing includes tools that may help diagnose service issues in service-heavy targets.", svc.name)
			if data := svc.failureMessage.GetLog(); data != "" {
				failMsg += "\n" + data
			}
		}
		tc := junit.GenerateTestCase(testTarget, svc.name, svc.startDuration, failMsg, junit.ServiceTestCaseProperty())
		if svc.failureMessage.GetType() == svclib_proto.StatusResp_FailureMessage_HAS_RACES {
			tc.Properties = append(tc.Properties, junit.FailedBecause(junit.HasRaces))
		}
		tc.Properties = append(tc.Properties, junit.JUnitProperty{Name: junit.SvcStartDurationPropertyName, Value: strconv.Itoa(int(svc.startDuration.Seconds()))})
		tc.Properties = append(tc.Properties, junit.JUnitProperty{Name: junit.CpuTimeMsPropertyName, Value: strconv.Itoa(int(svc.cpuTime.Seconds() * 1000))})
		tc.Properties = append(tc.Properties, junit.JUnitProperty{Name: junit.RssMbProperyName, Value: strconv.Itoa(int(svc.rssMb))})
		additionalTests = append(additionalTests, tc)
	}

	return additionalTests
}

type testInfo struct {
	target         string
	binary         string
	failed         bool
	duration       time.Duration
	totalDuration  time.Duration
	serviceResults []serviceResult
}

// we want to mark failed only raced services and ignore all other failures
func markRacedAsFailed(services []serviceResult) []serviceResult {
	var newServices []serviceResult
	for _, s := range services {
		var failed bool
		if s.failureMessage.GetType() == svclib_proto.StatusResp_FailureMessage_HAS_RACES {
			failed = true
		}
		s.failed = failed
		newServices = append(newServices, s)
	}
	return newServices
}

func overwriteJunitForServicesWithRaces(XMLOutputFile string, services []serviceResult, totalDuration time.Duration, testBinary string) error {
	services = markRacedAsFailed(services)
	// overwrite only if there was race
	if serviceResults(services).AnyFailed() {
		ti := testInfo{
			target:         junit.ConstructTestNameFromEnv(),
			binary:         testBinary,
			serviceResults: services,
			totalDuration:  totalDuration,
		}
		if err := overwriteJunitForServices(nil, XMLOutputFile, ti); err != nil {
			return fmt.Errorf("overwriting junit for services: %w", err)
		}
	}
	return nil
}

func overwriteJunitForServices(src io.ReadSeeker, XMLOutputFile string, ti testInfo) error {
	// don't need to generate xml
	if XMLOutputFile == "" {
		return nil
	}

	// Attempt to write XML file before exiting
	destFile, destErr := os.Create(XMLOutputFile) // creates if file doesn't exist
	if destErr != nil {
		log.Printf("Error trying to create XML output file: %s", destErr)
		return fmt.Errorf("create XML output file: %w", destErr)
	}

	var testcases []junit.JUnitTestCase

	if src == nil {
		// The test binary didn't generate any junit, so we'll be creating it from scratch.
		// Add an extra test case for the result & duration of the test alone, minus services
		failMsg := ""
		if ti.failed {
			failMsg = "Test failed"
		}
		testcases = append(testcases, junit.GenerateTestCase(ti.target, ti.binary, ti.duration, failMsg))
	}

	testcases = append(testcases, junitTestcasesForServices(ti.target, ti.serviceResults)...)

	overWriteErr := junit.OverwriteXMLDuration(src, ti.totalDuration, ti.target, testcases, destFile)
	if overWriteErr != nil {
		log.Printf("Error trying to write XML output: %s", overWriteErr)
		return fmt.Errorf("write XML output: %w", overWriteErr)
	}

	return nil
}

func main() {
	log.SetFlags(log.Lmicroseconds | log.Lshortfile)
	var verbose bool
	var serviceDefsFile string
	var serviceDefsVersionFile string
	var createOnly bool
	var servicesOnly bool
	var testOnly bool
	var testBinary string
	var gracefulStop bool

	flags := flag.NewFlagSet("svcinit", flag.ExitOnError)

	flags.BoolVar(&verbose, "svc.verbose", false, "Verbose output for services")
	flags.StringVar(&serviceDefsVersionFile, "svc.service-defs-version-file", "",
		"Path to a file representing the version of service definitions, to keep track of stale and incorrect service definitions.")
	flags.StringVar(&serviceDefsFile, "svc.service-defs", "",
		"Path to file containing service definitions in proto text form")
	flags.BoolVar(&createOnly, "svc.create-only", false,
		"Don't start any services, only create the definitions based on spec")
	flags.BoolVar(&servicesOnly, "svc.services-only", false,
		"Don't run any binaries after services have launched. Just exit and leave "+
			"the services running.")
	flags.BoolVar(&testOnly, "svc.test-only", false,
		"Don't launch services. Just run tests.")
	flags.StringVar(&testBinary, "svc.test-bin", "",
		"Test binary name to be used in junit output")
	flags.BoolVar(&gracefulStop, "svc.graceful-stop", false,
		"When shutting down services, try to do a quick but graceful stop. Not recommended by default as it will slow down test times, but can be useful when e.g. integrating with asan as it needs time to dump goroutines on exit.")
	failTestOnCrashSvcsStr := flags.String("svc.fail-test-on-crash-services", "",
		"Comma-separated list of services to ensure they are healthy after the test completed")

	startTime := time.Now()
	// the flags library doesn't have a good way to ignore unknown args and return them
	// so we do a hacky thing to achieve that behavior here.
	// only support -flag=value and -flag style flags for svcinit (-flag value is *not* supported)
	// everythign else is passed to the test runner
	isSvcInitFlag := func(flagName string) bool {
		return flagName == "help" || flagName == "h" || flags.Lookup(flagName) != nil
	}
	svcInitArgs := []string{}
	testArgs := []string{}
	for i := 1; i < len(os.Args); i++ {
		if os.Args[i] == "--" {
			testArgs = append(testArgs, os.Args[i+1:]...)
			break
		}
		if !strings.HasPrefix(os.Args[i], "-") {
			// not a flag, just assume this is a test args
			testArgs = append(testArgs, os.Args[i])
			continue
		}

		flagArg := os.Args[i]
		flagName := strings.TrimLeft(strings.Split(flagArg, "=")[0], "-")
		if isSvcInitFlag(flagName) {
			svcInitArgs = append(svcInitArgs, flagArg)
		} else {
			testArgs = append(testArgs, flagArg)
		}
	}
	_ = flags.Parse(svcInitArgs)
	failTestOnCrashServices := strings.Split(*failTestOnCrashSvcsStr, ",")
	for i, service := range failTestOnCrashServices {
		failTestOnCrashServices[i] = strings.TrimSpace(service)
	}

	if len(testArgs) == 0 && !servicesOnly {
		log.Fatalf("When no arguments are passed in, --svc.services-only must be explicitly passed.")
	}

	if testOnly {
		if execErr := syscall.Exec(testArgs[0], testArgs, os.Environ()); execErr != nil {
			log.Fatalf("Unable to exec: %s", execErr)
		}
	}

	if svclib.SvcCtlListening() {
		log.Fatal("svcd is already running. Perhaps you want --svc.test-only.")
	}

	if err := copyFile(svclib.FrozenServiceDefsVersionFile, serviceDefsVersionFile); err != nil {
		log.Fatalf("Unable to copy version file. %s", err)
	}
	// symlink the version file so we know how to find it. Need to first remove if the symlink
	// exists already, which can happen in the event of a persistent `bzl develop` container
	if _, err := os.Stat(svclib.CurrentServiceDefsVersionFile); err == nil {
		_ = os.Remove(svclib.CurrentServiceDefsVersionFile)
	}
	if err := os.Symlink(serviceDefsVersionFile, svclib.CurrentServiceDefsVersionFile); err != nil {
		log.Fatalf("Unable to symlink version file. %s", err)
	}

	var cleanups []func() error

	verbosityFlag := "--verbose=0"
	if verbose {
		verbosityFlag = "--verbose=1"
	}

	// -svc.services-only should never be true inside `bazel test`
	insideBazelTest := !servicesOnly

	svcCtlCmd := exec.Command(runfiles.MustDataPath("@dbx_build_tools//go/src/dropbox/build_tools/svcctl/cmd/svcd/svcd_norace"), verbosityFlag)
	svcCtlCmd.Stdout = os.Stdout
	svcCtlCmd.Stderr = os.Stderr
	svcCtlCmd.Dir = os.Getenv("RUNFILES")
	if err := svcCtlCmd.Start(); err != nil {
		log.Fatalf("failed to start svcd: %v", err)
	}

	cleanups = append(cleanups, func() error {
		log.Println("Shutting down service controller")
		_ = svcCtlCmd.Process.Signal(os.Kill)
		_ = svcCtlCmd.Wait()
		log.Printf("Services resource utilization: User: %v System: %v", svcCtlCmd.ProcessState.UserTime(), svcCtlCmd.ProcessState.SystemTime())
		return nil
	})

	// Make the service logs available, to help debug service issues/failures.
	// Service logs will appear in the outputs.bazel.zip file for the target.
	tmpdir, tmpdir_ok := os.LookupEnv("TEST_TMPDIR")
	outputsdir, outputsdir_ok := os.LookupEnv("TEST_UNDECLARED_OUTPUTS_DIR")
	if tmpdir_ok && outputsdir_ok {
		os.Symlink(tmpdir+"/logs", outputsdir+"/logs")
	}

	// Wait till svcctl is up and accepting requests.
	// we must do this wait unconditionally, otherwise there's a small race
	// where tests that want svcctl up but do not register services upfront may begin
	// before svcctl is up
	waitStart := time.Now()
	for !svclib.SvcCtlListening() {
		time.Sleep(10 * time.Millisecond)
		if time.Since(waitStart) > 5*time.Second {
			// In case svcd is still running, force kill it before exiting. Otherwise, svcd will reparent
			// to the testrunner and cause a test timeout.
			performCleanups(cleanups, insideBazelTest)
			log.Fatal("Deadline exceeded waiting for svcd")
		}
	}

	// for now we catch only Go races
	checkServicesFailures := func() error {
		if insideBazelTest {
			services, err := getServiceStatusAndDiagnostics()
			if err != nil {
				log.Printf("get services status %v", err)
			} else {
				if overWriteErr := overwriteJunitForServicesWithRaces(os.Getenv("XML_OUTPUT_FILE"), services, time.Since(startTime), testBinary); overWriteErr != nil {
					log.Printf("Error overwriting junit.xml file for failed services: %s", overWriteErr)
				}
			}
		}
		return nil
	}

	// check for service failures after stop
	cleanups = append(cleanups, checkServicesFailures)

	if serviceDefsFile != "" {
		svcDefBytes, readErr := ioutil.ReadFile(serviceDefsFile)
		if readErr != nil {
			log.Fatalf("Error reading service definitions file %s: %s", serviceDefsFile, readErr)
		} else {
			createServicesReq := new(svclib_proto.CreateBatchReq)
			unmarshalErr := proto.UnmarshalText(string(svcDefBytes), createServicesReq)
			if unmarshalErr != nil {
				log.Fatal(unmarshalErr)
			} else {
				var createErr error
				_, createErr = svclib.CreateServices(createServicesReq)
				if createErr != nil {
					log.Fatal(createErr)
				}

				if !createOnly {
					if gracefulStop {
						cleanups = append(cleanups, svclib.StopAll)
					} else {
						cleanups = append(cleanups, svclib.StopAllUnsafe)
					}
					if startErr := svclib.StartAll(); startErr != nil {
						log.Printf("Services did not start correctly. %s", startErr)
						if insideBazelTest {
							servicesFromSvcd, svcErr := getServiceStatusAndDiagnostics()
							if svcErr != nil {
								log.Printf("Error getting service status from svcd: %s", svcErr)
							} else {
								ti := testInfo{
									target:         junit.ConstructTestNameFromEnv(),
									binary:         testBinary,
									totalDuration:  time.Since(startTime),
									serviceResults: servicesFromSvcd,
								}
								// Only try to write junit files if we're in a test.
								_ = overwriteJunitForServices(nil, os.Getenv("XML_OUTPUT_FILE"), ti)
							}
						}
						performCleanups(cleanups, insideBazelTest)
						os.Exit(1)
					}
				}
			}
		}
	}

	servicesFromSvcd, svcErr := getServiceStatusAndDiagnostics()
	if svcErr != nil {
		log.Printf("Error getting service status from svcd: %s", svcErr)
		performCleanups(cleanups, insideBazelTest)
		os.Exit(1)
	} else if serviceResults(servicesFromSvcd).Err() != nil {
		log.Printf("Some services are no longer healthy, exiting. %s\n", serviceResults(servicesFromSvcd).Err())
		if insideBazelTest {
			ti := testInfo{
				target:         junit.ConstructTestNameFromEnv(),
				binary:         testBinary,
				totalDuration:  time.Since(startTime),
				serviceResults: servicesFromSvcd,
			}
			if overWriteErr := overwriteJunitForServices(nil, os.Getenv("XML_OUTPUT_FILE"), ti); overWriteErr != nil {
				log.Printf("Error overwriting junit.xml file for failed services: %s", overWriteErr)
			}
		}
		performCleanups(cleanups, insideBazelTest)
		os.Exit(1)
	}

	log.Printf("Services healthy %v", svcctl.FmtDuration(time.Since(startTime)))

	if insideBazelTest {
		tempXMLOutputDir, tempDirErr := ioutil.TempDir(os.Getenv("TEST_TMPDIR"), "svcctl-xml-output")
		if tempDirErr != nil {
			log.Fatalf("Unable to create temp dir for XML output. %s", tempDirErr)
		}
		tempXMLOutputFile := filepath.Join(tempXMLOutputDir, "test.xml")

		testFailed := false
		testDuration := time.Duration(0)

		copyXMLOutput := func() error {
			defer func() {
				// If we can't delete XML file during sandboxed execution, exiting sandbox will delete the file.
				// In other cases, this leaves a "small" stray file on disk, which is acceptable.
				_ = os.RemoveAll(tempXMLOutputDir)
			}()

			actualXMLOutputFile := os.Getenv("XML_OUTPUT_FILE")
			if actualXMLOutputFile == "" {
				// Test runner did not request output
				return nil
			}

			var src io.ReadSeeker

			srcFile, srcErr := os.Open(tempXMLOutputFile)
			if srcErr != nil {
				if !os.IsNotExist(srcErr) {
					// Couldn't open generated XML file
					log.Printf("Couldn't open generated XML file")
					return srcErr
				}

				// Underlying test did not generate XML output
			} else {
				defer func() {
					_ = srcFile.Close()
				}()
				src = srcFile
			}

			ti := testInfo{
				target:         junit.ConstructTestNameFromEnv(),
				binary:         testBinary,
				failed:         testFailed,
				duration:       testDuration,
				totalDuration:  time.Since(startTime),
				serviceResults: servicesFromSvcd,
			}
			if overWriteErr := overwriteJunitForServices(src, actualXMLOutputFile, ti); overWriteErr != nil {
				log.Printf("Error overwriting junit XML file: %s", overWriteErr)
				return fmt.Errorf("overwrite junit XML file: %w", overWriteErr)
			}

			return nil
		}
		cleanups = append(cleanups, copyXMLOutput)

		log.Printf("Executing command: %s\n", strings.Join(testArgs, " "))
		testCmd := exec.Command(testArgs[0], testArgs[1:]...)
		testCmd.Stdout = os.Stdout
		testCmd.Stderr = os.Stderr

		testCmd.Env = append(os.Environ(), fmt.Sprintf("XML_OUTPUT_FILE=%s", tempXMLOutputFile))

		testStartTime := time.Now()

		if err := testCmd.Start(); err != nil {
			// Error while trying to launch test command
			testFailed = true
			performCleanups(cleanups, insideBazelTest)
			os.Exit(1)
		}

		testErr := testCmd.Wait()

		testDuration = time.Since(testStartTime)
		if testErr != nil {
			log.Printf("Encountered error during test run: %s\n", testErr)
			testFailed = true
			performCleanups(cleanups, insideBazelTest)
			os.Exit(1)
		}
		log.Printf("Test duration: %s\n", testDuration)
		log.Printf("Test resource utilization: User: %v System: %v", testCmd.ProcessState.UserTime(), testCmd.ProcessState.SystemTime())
		log.Printf("Checking services health before cleaning up.")
		statuses, err := getServiceStatusAndDiagnostics()
		if err != nil {
			log.Printf("Failed to get service status: %s", err)
		} else {
			failedServices := make(map[string]struct{})
			for _, status := range statuses {
				if status.failed {
					failedServices[status.name] = struct{}{}
				}
			}
			if len(failedServices) > 0 {
				log.Printf("Unhealthy services: %s", failedServices)
				for _, service := range failTestOnCrashServices {
					if _, failed := failedServices[service]; failed {
						log.Printf("Service %s is configured to fail tests when it is unhealthy. "+
							"Marking the test failed.", service)
						testFailed = true
						os.Exit(1)
					}
				}
			}
		}

		performCleanups(cleanups, insideBazelTest)
		log.Printf("Cleanup complete\n")
		if actualXMLOutputFile := os.Getenv("XML_OUTPUT_FILE"); actualXMLOutputFile != "" {
			failing, jerr := isFailingJUnit(actualXMLOutputFile)
			if jerr != nil {
				log.Printf("Failed to interpret final junit file %s: %v\n", actualXMLOutputFile, jerr)
			}
			if failing {
				log.Println("Test exited successfully, but JUnit indicates failure; failing.")
				os.Exit(1)
			}
		}
	}
}

func isFailingJUnit(path string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer func() {
		_ = f.Close()
	}()
	var suites []junit.JUnitTestSuite
	// First try to parse as a single test suite.
	suite, serr := junit.ParseFromReader(f)
	if serr == nil {
		suites = []junit.JUnitTestSuite{*suite}
	} else {
		// If that fails, parse as a set of multiple suites.
		f.Seek(0, io.SeekStart)
		suitesObj, serr := junit.ParseFromReaderSuites(f)
		if serr != nil {
			return false, serr
		}
		suites = suitesObj.Suites
	}
	for _, suite := range suites {
		if suite.HasFailingTest() {
			return true, nil
		}
	}

	return false, nil
}
