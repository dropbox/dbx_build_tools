package junit

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"io"
	"log"
	"os"
	"strconv"
	"time"
)

// <testsuites> is sometimes used as a top-level entry in junit.xml to wrap multiple test suites.
// This is used in Bazel test's default test XML. It is not used in any of our py.test junit outputs.
type JUnitTestSuites struct {
	XMLName xml.Name         `xml:"testsuites"`
	Time    string           `xml:"time,attr"`
	Suites  []JUnitTestSuite `xml:"testsuite,omitempty"`
}

// Copied from rSERVER/go/src/github.com/jstemmer/go-junit-report/junit-formatter.go

// JUnitTestSuite is a single JUnit test suite which may contain many
// testcases.
type JUnitTestSuite struct {
	XMLName    xml.Name        `xml:"testsuite"`
	Errors     int             `xml:"errors,attr"`
	Failures   int             `xml:"failures,attr"`
	Name       string          `xml:"name,attr"`
	Skips      int             `xml:"skips,attr"`
	Tests      int             `xml:"tests,attr"`
	Time       string          `xml:"time,attr"`
	Properties []JUnitProperty `xml:"properties>property,omitempty"`
	TestCases  []JUnitTestCase `xml:"testcase,omitempty"`
}

func (s JUnitTestSuite) HasFailingTest() bool {
	for _, tc := range s.TestCases {
		if tc.HasFailure() || tc.HasErrors() {
			return true
		}
	}

	return false
}

func (s JUnitTestSuites) HasFailingTest() bool {
	for _, ts := range s.Suites {
		if ts.HasFailingTest() {
			return true
		}
	}

	return false
}

// JUnitTestCase is a single test case with its result.
type JUnitTestCase struct {
	XMLName     xml.Name          `xml:"testcase"`
	Classname   string            `xml:"classname,attr"`
	File        string            `xml:"file,attr"`
	Line        string            `xml:"line,attr"`
	Name        string            `xml:"name,attr"`
	Time        string            `xml:"time,attr"`
	SkipMessage *JUnitSkipMessage `xml:"skipped,omitempty"`
	Failure     *JUnitFailure     `xml:"failure,omitempty"`
	SystemOut   string            `xml:"system-out,omitempty"`
	SystemErr   string            `xml:"system-err,omitempty"`
	Properties  []JUnitProperty   `xml:"properties>property,omitempty"`
	Errors      *JUnitError       `xml:"error,omitempty"`
	Rerun       string            `xml:"rerun,attr,omitempty"`
	Artifacts   []JUnitArtifact   `xml:"test-artifacts>artifact,omitempty"`
}

// An artifact declaration
type JUnitArtifact struct {
	Base64 string `xml:"base64,attr"`
	Name   string `xml:"name,attr"`
	Type   string `xml:"type,attr"`
}

// Returns the test type as classified from the properties, if available.
func (j JUnitTestCase) TestType() (TestCaseType, bool) {
	for _, p := range j.Properties {
		if p.Name == TestCaseTypePropertyName {
			return TestCaseType(p.Value), true
		}
	}
	return "", false
}

// JUnitSkipMessage contains the reason why a testcase was skipped.
type JUnitSkipMessage struct {
	Message string `xml:"message,attr"`
}

type JUnitError struct {
	Message  string `xml:"message,attr"`
	Contents string `xml:",chardata"`
}

// JUnitProperty represents a key/value pair used to define properties.
type JUnitProperty struct {
	Name  string `xml:"name,attr"`
	Value string `xml:"value,attr"`
}

// JUnitFailure contains data related to a failed test.
type JUnitFailure struct {
	Message  string `xml:"message,attr"`
	Type     string `xml:"type,attr,omitempty"`
	Contents string `xml:",chardata"`
}

const FailureReasonPropertyName = "failure-reason"

type FailureReason string

func FailedBecause(reason FailureReason) JUnitProperty {
	return JUnitProperty{Name: FailureReasonPropertyName, Value: string(reason)}
}

const (
	ExceededMemoryLimits FailureReason = "exceeded-memory-limits"
	TimedOut             FailureReason = "timed-out"
	HasRaces             FailureReason = "has-races"
)

const TestCaseTypePropertyName = "test-type"

type TestCaseType string

const ServiceTestCase TestCaseType = "service"

func ServiceTestCaseProperty() JUnitProperty {
	return JUnitProperty{Name: TestCaseTypePropertyName, Value: string(ServiceTestCase)}
}

const CpuTimeMsPropertyName = "cpu-ms"
const RssMbProperyName = "rss-mb"

func GenerateTestCase(class string, testname string, duration time.Duration, failureMessage string, properties ...JUnitProperty) JUnitTestCase {
	tc := JUnitTestCase{
		Classname: class,
		Name:      testname,
		Time:      fmt.Sprintf("%f", duration.Seconds()),
	}

	if failureMessage != "" {
		tc.Failure = &JUnitFailure{
			Contents: failureMessage,
		}
	}

	if len(properties) > 0 {
		tc.Properties = append(tc.Properties, properties...)
	}

	return tc
}

func (tc JUnitTestCase) GetCanonicalName() string {
	if tc.Classname != "" {
		return tc.Classname + "." + tc.Name
	}
	return tc.Name
}

func (tc JUnitTestCase) HasFailure() bool {
	return tc.Failure != nil
}

func (tc JUnitTestCase) HasErrors() bool {
	return tc.Errors != nil
}

func (tc JUnitTestCase) HasSkip() bool {
	return tc.SkipMessage != nil
}

func (tc JUnitTestCase) Reruns() int {
	reruns, err := strconv.ParseInt(tc.Rerun, 10, 32)
	if err != nil {
		return 0
	}
	// we never expect reruns to be > 5 in most cases, so casting it seems fine
	return int(reruns)
}

func (tc JUnitTestCase) GetProperty(name string) (string, bool) {
	for _, property := range tc.Properties {
		if property.Name == name {
			return property.Value, true
		}
	}

	return "", false
}

func (tc JUnitTestCase) GetFailureReason() (FailureReason, bool) {
	value, ok := tc.GetProperty(FailureReasonPropertyName)
	return FailureReason(value), ok
}

func ParseFromReader(src io.Reader) (*JUnitTestSuite, error) {
	dec := xml.NewDecoder(src)
	dec.Strict = true

	suite := new(JUnitTestSuite)
	if decodeErr := dec.Decode(suite); decodeErr != nil {
		return nil, decodeErr
	}

	return suite, nil
}

func ParseFromReaderSuites(src io.Reader) (*JUnitTestSuites, error) {
	dec := xml.NewDecoder(src)
	dec.Strict = true

	suites := new(JUnitTestSuites)
	if decodeErr := dec.Decode(suites); decodeErr != nil {
		return nil, decodeErr
	}

	return suites, nil
}

func OverwriteXMLDuration(src io.ReadSeeker, totalTime time.Duration, testTarget string, additionalTests []JUnitTestCase, dst io.Writer) error {
	var suite *JUnitTestSuite
	var parseErr error
	if src == nil {
		// If we don't have a source XML file to mangle, start with an empty test suite
		suite = new(JUnitTestSuite)
	} else {
		suite, parseErr = ParseFromReader(src)
	}
	var toEncode interface{}
	toEncode = suite
	if parseErr != nil {
		var seekErr error
		_, seekErr = src.Seek(0, 0)
		if seekErr != nil {
			return seekErr
		}
		// maybe we were given multiple test suites, in which case we create a new test suite
		// and append to it
		suites, parseSuitesErr := ParseFromReaderSuites(src)
		if parseSuitesErr != nil {
			return parseErr
		}
		toEncode = suites
		suites.Suites = append(suites.Suites, JUnitTestSuite{})
		suite = &suites.Suites[len(suites.Suites)-1]
	}

	if suite.Name == "" {
		suite.Name = testTarget
	}

	suite.Time = fmt.Sprintf("%f", totalTime.Seconds())

	suite.Tests += len(additionalTests)
	suite.TestCases = append(suite.TestCases, additionalTests...)

	for _, test := range additionalTests {
		if test.HasFailure() {
			suite.Failures += 1
		}
		if test.HasErrors() {
			suite.Errors += 1
		}
		if test.HasSkip() {
			suite.Skips += 1
		}
	}

	if _, wErr := io.WriteString(dst, xml.Header); wErr != nil {
		return wErr
	}

	enc := xml.NewEncoder(dst)
	return enc.Encode(toEncode)
}

func ParseTime(time string) (int32, error) {
	if time == "" {
		return int32(0), nil
	}
	durSecs, durParseErr := strconv.ParseFloat(time, 64)
	if durParseErr != nil {
		return 0, durParseErr
	} else {
		if durSecs < 0 || durSecs > 2147483647 {
			// NOTE(utsav): some buggy junit output processors might give negative time
			// or too large values. Just ignore those.
			// This is in sync with Changes
			durSecs = 0
		}
		return int32(durSecs * 1000), nil
	}
}

// Attempt to try parsing the input as a testsuite or as a list of
// testsuites.
func ParseAsSuites(b []byte) (*JUnitTestSuites, error) {
	parsedSuites, perr := ParseFromReaderSuites(bytes.NewReader(b))

	if perr == nil {
		return parsedSuites, nil
	}

	// It could also be a single test suite, so try parsing that
	parsedSuite, paerr := ParseFromReader(bytes.NewReader(b))
	if paerr != nil {
		return nil, fmt.Errorf("errors trying to parse junit suites: %s %s", perr, paerr)
	}

	parsedSuites = &JUnitTestSuites{
		Suites: []JUnitTestSuite{
			*parsedSuite,
		},
	}

	return parsedSuites, nil
}

// Copied from generate_test_main.go
func parseIntFromEnv(envVar string, def int, failOnErr bool) int {
	envValue := os.Getenv(envVar)
	if envValue == "" {
		return def
	}

	intValue, err := strconv.ParseUint(envValue, 10, 64)
	if err != nil {
		if failOnErr {
			log.Fatal(err)
		} else {
			return def
		}
	}

	return int(intValue)
}

// Constructs a repeatable, unique test name suitable to be used as test name in Junit XML files
// from TEST_BINARY and test sharding-related environment variables.
func ConstructTestNameFromEnv() string {
	name := os.Getenv("TEST_BINARY")
	if name == "" {
		// This is guaranteed to be present for `bazel test` invocations.
		panic("Unable to get TEST_BINARY env var")
	}

	// Note: Paper's run_bazel_named_tests script depends on these environment
	// variables being used here to make test names distinct across shards. Keep
	// that script in sync with any changes made to the use of these variables,
	// including that TEST_SHARD_INDEX is currently set as a random int value since
	// Changes doesn't pass the executor shard id anywhere we can use it.
	totalShards := parseIntFromEnv("TEST_TOTAL_SHARDS", 0, true)
	if totalShards > 0 {
		// TEST_SHARD_INDEX is 0-indexed. Convert it to 1-indexed form.
		shardId := parseIntFromEnv("TEST_SHARD_INDEX", 0, true) + 1
		name = fmt.Sprintf("%s_shard_%d_of_%d", name, shardId, totalShards)
	}

	return name
}
