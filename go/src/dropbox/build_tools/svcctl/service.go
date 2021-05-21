package svcctl

import (
	"bytes"
	"crypto/md5"
	"crypto/tls"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"dropbox/build_tools/logwriter"
	"dropbox/build_tools/svcctl/proc"
	"dropbox/build_tools/svcctl/state_machine"
	"dropbox/cputime"
	"dropbox/procfs"
	svclib_proto "dropbox/proto/build_tools/svclib"
	"dropbox/runfiles"
)

const interruptWaitDuration = time.Duration(250 * time.Millisecond)
const pollInterval = time.Duration(10 * time.Millisecond)
const serviceLogsDir = "logs/service_logs"

// Command is a convenient representation of svclib.Command proto.
type Command struct {
	Cmd     string
	EnvVars []string
}

// Return the command in copy-pastable form for debugging.
func (cmd Command) String() string {
	return cmd.Cmd
}

func CommandFromProto(proto_cmd *svclib_proto.Command) *Command {
	cmd := &Command{
		Cmd: *proto_cmd.Cmd,
		EnvVars: []string{
			// services expect to be able to use TEST_TMPDIR as the directory they can safely write to
			fmt.Sprintf("TEST_TMPDIR=%s", os.Getenv("TEST_TMPDIR")),

			// leak $RUNFILES so services that are pure bash scripts can use it
			fmt.Sprintf("RUNFILES=%s", os.Getenv("RUNFILES")),

			// leak $HOME because in itest, we are manually overriding this to a custom location
			// and this is the easiest way to propagate it to services for use with local development
			fmt.Sprintf("HOME=%s", os.Getenv("HOME")),
		},
	}
	for _, ev := range proto_cmd.EnvVars {
		value := os.ExpandEnv(*ev.Value)
		cmd.EnvVars = append(cmd.EnvVars, fmt.Sprintf("%s=%s", *ev.Key, value))
	}
	return cmd
}

func (c Command) GetExecutor() *proc.Pcmd {
	// no need to do $RUNFILES substitution here, bash does it automatically
	executor := proc.New("/bin/bash", "-c", "--", c.Cmd)
	executor.Cmd.Env = c.EnvVars

	return executor
}

// serviceDef is the internal representation of a service (and its state)
// Some of these fields are copied from the svclib.Service proto, and the remaining constitute
// runtime state.
type serviceDef struct {
	// fields that can be accessed freely without locking, because
	// (1) they are never assigned to past the initialization, and
	// (2) the data structures themselves are threadsafe
	Dependents   []*serviceDef
	LaunchCmd    *Command
	StopCmd      *Command
	ServiceType  svclib_proto.Service_Type
	StateMachine state_machine.StateMachine
	Stderr       io.Writer
	Stdout       io.Writer
	logger       *log.Logger
	name         string
	owner        string
	verbose      bool
	version      atomic.Value
	versionFiles []string
	// waitCh is closed on process exit
	waitCh chan struct{}

	// health checks
	HttpHealthChecks []*svclib_proto.HttpHealthCheck
	VerifyCmds       []*Command

	// mutable fields, need to acquire lock to read
	lock            sync.Mutex
	Process         *proc.Pcmd
	startTime       time.Time
	startDuration   time.Duration
	stopTime        time.Time
	stopDuration    time.Duration
	sanitizerErrors []string
}

func (svc *serviceDef) String() string {
	return svc.name
}

func NewService(svc *svclib_proto.Service, services map[string]*serviceDef, verbose bool) (*serviceDef, error) {
	svcDef := &serviceDef{
		LaunchCmd:    CommandFromProto(svc.LaunchCmd),
		ServiceType:  svc.GetType(),
		name:         *svc.ServiceName,
		owner:        svc.GetOwner(),
		verbose:      verbose,
		startTime:    time.Now(),
		StateMachine: state_machine.New(svclib_proto.StatusResp_STOPPED),
	}
	svcDef.logger = svcDef.createLogger(os.Stderr, log.Lshortfile)
	if svcDef.verbose {
		svcDef.Stdout = logwriter.New(svcDef.createLogger(os.Stdout, 0))
		svcDef.Stderr = logwriter.New(svcDef.createLogger(os.Stderr, 0))
	}

	if svc.StopCmd != nil {
		svcDef.StopCmd = CommandFromProto(svc.StopCmd)
	}

	for _, depName := range svc.GetDependencies() {
		if dep, ok := services[depName]; !ok {
			return nil, fmt.Errorf("Undeclared dependency %v for %v", depName, svc.GetServiceName())
		} else {
			svcDef.Dependents = append(svcDef.Dependents, dep)
		}
	}

	for _, hc := range svc.HealthChecks {
		if hc.GetType() == svclib_proto.HealthCheck_COMMAND {
			svcDef.VerifyCmds = append(svcDef.VerifyCmds, CommandFromProto(hc.GetCmd()))
		} else if hc.GetType() == svclib_proto.HealthCheck_HTTP {
			svcDef.HttpHealthChecks = append(svcDef.HttpHealthChecks, hc.GetHttpHealthCheck())
		} else {
			return nil, fmt.Errorf("Unsupported health check type %s", hc.GetType())
		}
	}

	// initialize version with a default value
	defaultVersion := []byte{}
	svcDef.version.Store(defaultVersion)

	for _, runfilesPath := range svc.VersionFiles {
		fullPath, err := runfiles.DataPath(runfilesPath)
		if err != nil {
			return nil, fmt.Errorf("unable to resolve runfiles path %s: %w", runfilesPath, err)
		}
		svcDef.versionFiles = append(svcDef.versionFiles, fullPath)
	}

	sort.Strings(svcDef.versionFiles)

	return svcDef, nil
}

// Return the pid of the service or 0 if it isn't running.
func (svc *serviceDef) getPid() int {
	svc.lock.Lock()
	defer svc.lock.Unlock()
	if svc.Process != nil && svc.Process.Cmd.Process != nil {
		return svc.Process.Cmd.Process.Pid
	}
	return 0
}

func (svc *serviceDef) getSanitizerErrors() []string {
	svc.lock.Lock()
	defer svc.lock.Unlock()
	return svc.sanitizerErrors
}

func (svc *serviceDef) openLogFile() (*os.File, error) {
	logFilePath := svc.getLogsPath()
	if err := os.MkdirAll(filepath.Dir(logFilePath), 0777); err != nil {
		return nil, err
	}
	logFile, openErr := os.OpenFile(logFilePath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0777)
	if openErr != nil {
		return nil, openErr
	}
	return logFile, nil
}

func (svc *serviceDef) getLogsPath() string {
	tmpRoot := os.Getenv("TEST_TMPDIR")
	if tmpRoot == "" {
		panic("TEST_TMPDIR not set")
	}
	return filepath.Join(tmpRoot, serviceLogsDir, strings.TrimLeft(svc.name, "/"), "service.log")
}

func (svc *serviceDef) createLogger(writer io.Writer, flag int) *log.Logger {
	return log.New(writer, fmt.Sprintf("[%s] ", svc.name),
		log.Lmicroseconds|flag)
}

func (svc *serviceDef) readVersionFiles() ([]byte, error) {
	hasher := md5.New()
	for _, versionFile := range svc.versionFiles {
		f, err := os.Open(versionFile)
		if err != nil {
			return nil, fmt.Errorf("unable to open %s: %w", versionFile, err)
		}
		_, copyErr := io.Copy(hasher, f)
		f.Close()
		if copyErr != nil {
			return nil, fmt.Errorf("unable to read %s: %w", versionFile, err)
		}
	}
	return hasher.Sum(nil), nil
}

func (svc *serviceDef) needsRestart() bool {
	if len(svc.versionFiles) == 0 {
		// no version file configured, does not support autorestarting
		return false
	}

	curContent, readErr := svc.readVersionFiles()
	if readErr != nil {
		svc.logger.Printf("Unable to read version file. %s", readErr)
		return false
	}
	frozenVersion := svc.version.Load().([]byte)
	return !bytes.Equal(frozenVersion, curContent)
}

func (svc *serviceDef) StartDuration() time.Duration {
	svc.lock.Lock()
	defer svc.lock.Unlock()
	return svc.startDuration
}

func (svc *serviceDef) StartTime() time.Time {
	svc.lock.Lock()
	defer svc.lock.Unlock()
	return svc.startTime
}

func (svc *serviceDef) StopDuration() time.Duration {
	svc.lock.Lock()
	defer svc.lock.Unlock()
	return svc.stopDuration
}

func (svc *serviceDef) StopTime() time.Time {
	svc.lock.Lock()
	defer svc.lock.Unlock()
	return svc.stopTime
}

func (svc *serviceDef) markStarted() {
	// lock the entire function, so we only transition state to STARTED if
	// we are in STARTING
	svc.lock.Lock()
	defer svc.lock.Unlock()
	if svc.StateMachine.GetState() == svclib_proto.StatusResp_STARTING {
		svc.startDuration = time.Since(svc.startTime)
		svc.StateMachine.SetState(svclib_proto.StatusResp_STARTED)
	}
}

func expBackoff(gen int) {
	delay := math.Min(math.Pow(1.1, float64(gen))*float64(pollInterval), float64(500*time.Millisecond))
	time.Sleep(time.Duration(delay))
}

func (svc *serviceDef) PollChkCmd(checkCmd *Command, wg *sync.WaitGroup) {
	for attempt := 0; true; attempt++ {
		if svc.StateMachine.GetState() != svclib_proto.StatusResp_STARTING {
			svc.logger.Printf("Giving up executing health check command %s", checkCmd)
			return
		}
		cmd := checkCmd.GetExecutor()
		// Here is where we would redirect cmd.Stdout to svc.Stdout if we wanted that noise.
		cmd.Cmd.Stderr = svc.Stderr
		if startErr := cmd.Start(); startErr == nil {
			if exitErr := cmd.Wait(); exitErr == nil {
				if svc.verbose {
					svc.logger.Printf("Health check command passed: %s", checkCmd)
				}
				wg.Done()
				return
			} else {
				if svc.verbose {
					svc.logger.Printf("Error executing health check command %s: %s", checkCmd, exitErr)
				}
			}
		} else {
			if svc.verbose {
				svc.logger.Printf("Error starting health check command %s: %s", checkCmd, startErr)
			}
		}
		expBackoff(attempt)
	}
}

func (svc *serviceDef) PollHttpHealthCheck(hc *svclib_proto.HttpHealthCheck, wg *sync.WaitGroup) {
	for attempt := 0; true; attempt++ {
		if svc.StateMachine.GetState() != svclib_proto.StatusResp_STARTING {
			svc.logger.Printf("Giving up executing Http health check: %s", hc)
			return
		}
		tr := &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		}
		client := &http.Client{Transport: tr}
		resp, err := client.Get(hc.GetUrl())
		if err != nil {
			if svc.verbose {
				svc.logger.Printf("Http health check failed for %s: %s", hc, err)
			}
			goto retry
		}
		_, err = io.Copy(ioutil.Discard, resp.Body)
		resp.Body.Close()
		if err != nil {
			if svc.verbose {
				svc.logger.Printf("Http health check failed for %s: %s", hc, err)
			}
			goto retry
		}
		if resp.StatusCode == http.StatusOK {
			wg.Done()
			return
		}
		if svc.verbose {
			svc.logger.Printf("Http health check failed for %s. Status is %d\n", hc, resp.StatusCode)
		}
	retry:
		expBackoff(attempt)
	}
}

// This function waits until the service is healthy, then mark it as such.
// it should only be called once, from Start()
func (svc *serviceDef) waitTillHealthyAndMark() {
	svc.lock.Lock()
	process := svc.Process
	svc.lock.Unlock()
	var waitForHealthChecks sync.WaitGroup
	switch svc.ServiceType {

	case svclib_proto.Service_DAEMON:
		for _, checkCmd := range svc.VerifyCmds {
			waitForHealthChecks.Add(1)
			go svc.PollChkCmd(checkCmd, &waitForHealthChecks)
		}
		for _, hc := range svc.HttpHealthChecks {
			waitForHealthChecks.Add(1)
			go svc.PollHttpHealthCheck(hc, &waitForHealthChecks)
		}
		go func() {
			exitErr := process.Wait()
			svc.appendSanitizerErrors()
			close(svc.waitCh)
			svc.lock.Lock()
			defer svc.lock.Unlock()
			switch svc.StateMachine.GetState() {
			case svclib_proto.StatusResp_STARTING, svclib_proto.StatusResp_STARTED:
				svc.logger.Printf("Daemon unexpectedly stopped: %s", exitErr)
				svc.StateMachine.SetState(svclib_proto.StatusResp_ERROR)
			}

		}()
		waitForHealthChecks.Wait()
		svc.markStarted()

		// Ignore the error here - we aren't going to do anything anyway. A zero CPU time should
		// be suspicious enough anyway.
		cpuTime, _ := cputime.RecursiveCPUTime(process.Cmd.Process.Pid)
		svc.logger.Printf("Daemon healthy: wall-time:%v cpu-time:%v", FmtDuration(svc.startDuration), FmtDuration(cpuTime))
	case svclib_proto.Service_TASK:
		exitErr := process.Wait()
		svc.appendSanitizerErrors()
		close(svc.waitCh)

		if exitErr != nil {
			svc.lock.Lock()
			defer svc.lock.Unlock()
			switch svc.StateMachine.GetState() {
			case svclib_proto.StatusResp_STARTING, svclib_proto.StatusResp_STARTED:
				svc.logger.Printf("Task exited with an error: %s", exitErr)
				svc.StateMachine.SetState(svclib_proto.StatusResp_ERROR)
			}
		} else {
			svc.markStarted()
			svc.logger.Printf("Task completed: wall-time:%v cpu-time:%v", FmtDuration(svc.startDuration),
				FmtDuration(process.Cmd.ProcessState.UserTime()+process.Cmd.ProcessState.SystemTime()))
		}
	}
}

// This function waits until the service is healthy, then return.
// An error is returned if the process exits before it should.
func (svc *serviceDef) waitTillHealthy() error {
	state := svc.StateMachine.WaitTillNotState(svclib_proto.StatusResp_STARTING)
	if state == svclib_proto.StatusResp_STARTED {
		return nil
	} else {
		return fmt.Errorf("Service %s in unexpected state %s", svc, state)
	}
}

// Bring up a service with the following sequence of steps:
// - Fork the launcher command
// - Mark service as "starting"
// - Poll for all declared TCP ports to accept connections.
// - Repeatedly execute any "verification commands" that need to be executed till they return with a
//   zero exit code once.
// - if no health checks ports or commands were given, then wait for the process to
//   exit successfully.
// - Mark service as "started"/"healthy"
//
// If the forked launcher exits the service is marked to be in an error state.
//
// Start method doesn't wait for the service to be healthy. Instead it forks the launcher and issues
// health checking code in separate goroutines.
func (svc *serviceDef) Start() error {
	svc.lock.Lock()
	defer svc.lock.Unlock()

	if svc.StateMachine.GetState() == svclib_proto.StatusResp_STOPPED {
		var version []byte
		var readErr error
		if len(svc.versionFiles) > 0 {
			version, readErr = svc.readVersionFiles()
			if readErr != nil {
				svc.logger.Printf("Unable to read version file. %s\n", readErr)
			}
		}

		svc.startTime = time.Now()
		svc.waitCh = make(chan struct{})

		logFile, logFileErr := svc.openLogFile()
		if logFileErr != nil {
			return fmt.Errorf("Failed to open log file for %s: %s\n", svc.name, logFileErr)
		}
		svc.startDuration = time.Duration(0)
		process := svc.LaunchCmd.GetExecutor()
		svc.Process = process
		svc.Process.Cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		if svc.verbose {
			svc.Process.Cmd.Stdout = io.MultiWriter(svc.Stdout, logFile)
			svc.Process.Cmd.Stderr = io.MultiWriter(svc.Stderr, logFile)
		} else {
			svc.Process.Cmd.Stdout = logFile
			svc.Process.Cmd.Stderr = logFile
		}
		fmt.Fprintf(
			svc.Process.Cmd.Stdout,
			"\n\nService starting at %s\n\nCommand line:\n%s"+
				"\n\nEnvironment:\n%s\n\n",
			svc.startTime,
			svc.LaunchCmd.Cmd,
			svc.LaunchCmd.EnvVars,
		)
		if err := svc.Process.Start(); err != nil {
			svc.logger.Println("Service start error:", svc.Process.Cmd.Args)
			svc.StateMachine.SetState(svclib_proto.StatusResp_ERROR)
			_ = logFile.Close()
			return err
		}
		svc.StateMachine.SetState(svclib_proto.StatusResp_STARTING)
		if svc.verbose {
			svc.logger.Println("Service starting:", svc.Process.Cmd.Args)
		}

		go svc.waitTillHealthyAndMark()
		go func() {
			// close the log file when the process exits.
			// NOTE: process is not exec.Cmd, but our own wrapper, which is why
			// it's ok to call Wait() multiple times.
			<-svc.waitCh
			_ = logFile.Close()
		}()
		go func() {
			healthyErr := svc.waitTillHealthy()
			if healthyErr == nil {
				// no need to log errors, there are logging elsewhere
				svc.version.Store(version)
			}
		}()
	}

	return nil
}

func (svc *serviceDef) appendSanitizerErrors() {
	errs := svc.Process.SanitizerErrors()
	if len(errs) != 0 {
		fmt.Printf("SANITIZER ERRORS in %s:\n%s\n", svc.name, strings.Join(errs, "\n"))
	}
	svc.sanitizerErrors = append(svc.sanitizerErrors, errs...)
}

// this kill is much harder to escape from than the regular kill of negative pid.
func forceSignalProcessTree(pids []int, sig syscall.Signal) error {
	var lastErr error
	for _, pid := range pids {
		allChildren, err := procfs.GetProcessDescendents(pid)
		if err != nil {
			lastErr = err
			continue
		}
		for _, child := range allChildren {
			if err := syscall.Kill(child, sig); err != nil {
				lastErr = err
				continue
			}
		}
	}
	return lastErr
}

// exited() returns true when process is finished
func (svc *serviceDef) exited() bool {
	select {
	case <-svc.waitCh:
		return true
	default:
		return false
	}
}

// Stop a service using the following sequence of steps:
// - Send specified signal to process group which launched the service
// - If process didn't die in 250ms, send SIGKILL to every child process and their descendents (according to procfs) every 250ms till the process dies.
//
// Stop method is synchronous and doesn't exit till the process has terminated.
func (svc *serviceDef) stop(sig syscall.Signal) error {
	svc.lock.Lock()
	defer svc.lock.Unlock()

	if svc.StateMachine.GetState() != svclib_proto.StatusResp_STOPPED {
		svc.stopTime = time.Now()
		svc.StateMachine.SetState(svclib_proto.StatusResp_STOPPING)
		switch svc.ServiceType {
		case svclib_proto.Service_DAEMON:
			if svc.verbose {
				svc.logger.Printf("Stopping daemon with signal %v", sig)
			}

			allPidsToForceKill := []int{svc.Process.Cmd.Process.Pid}
			childPids, err := procfs.ChildPids(svc.Process.Cmd.Process.Pid)
			if err != nil {
				svc.logger.Printf("Failed to get child processes")
			} else {
				allPidsToForceKill = append(allPidsToForceKill, childPids...)
			}

			var killErr error
			if sig == syscall.SIGKILL {
				// not graceful anyways, so go ahead and use the forceful kill
				killErr = forceSignalProcessTree(allPidsToForceKill, sig)
			} else {
				// make the first kill graceful to give process group a chance to clean up
				killErr = syscall.Kill(-svc.Process.Cmd.Process.Pid, sig)
			}

			if killErr != nil {
				if svc.exited() {
					// we failed to send signal because the process already exited
					svc.Process = nil
					svc.StateMachine.SetState(svclib_proto.StatusResp_STOPPED)
					svc.stopDuration = time.Since(svc.stopTime)
					return nil
				}
				svc.stopDuration = time.Since(svc.stopTime)
				return killErr
			}

			// TODO(anupc): Loop limits?
			stopped := false
			for !stopped {
				select {
				case <-time.After(interruptWaitDuration):
					if svc.verbose {
						svc.logger.Println("Process not dead yet - issuing SIGKILL to entire tree")
					}
					if killErr := forceSignalProcessTree(allPidsToForceKill, syscall.SIGKILL); killErr != nil {
						if svc.exited() {
							stopped = true
						}
					}
				case <-svc.waitCh:
					stopped = true
				}
			}
			svc.Process = nil
			svc.StateMachine.SetState(svclib_proto.StatusResp_STOPPED)
			svc.stopDuration = time.Since(svc.stopTime)

		case svclib_proto.Service_TASK:
			// synchronous process, stop() doesn't do anything but set the status
			if svc.verbose {
				svc.logger.Println("Stopping task")
			}
			svc.StateMachine.SetState(svclib_proto.StatusResp_STOPPED)
			svc.stopDuration = time.Since(svc.stopTime)
		}
	}

	return nil
}

func (svc *serviceDef) Stop() error {
	return svc.stop(syscall.SIGINT)
}

func (svc *serviceDef) StopUnsafe() error {
	return svc.stop(syscall.SIGKILL)
}

func FmtDuration(d time.Duration) string {
	u := uint64(d)
	neg := d < 0
	if neg {
		u = -u
	}

	msecs := (u / 1e6) % 1000
	secs := (u / 1e9)
	str := fmt.Sprintf("%d.%03ds", secs, msecs)
	if neg {
		return "-" + str
	}

	return str
}
