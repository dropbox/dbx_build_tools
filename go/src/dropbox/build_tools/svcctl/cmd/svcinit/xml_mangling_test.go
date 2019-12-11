package main

import (
	"bytes"
	"io"
	"io/ioutil"
	"os"
	"path"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"dropbox/build_tools/bazel"
	"dropbox/build_tools/junit"
	svclib_proto "dropbox/proto/build_tools/svclib"
)

func TestOverwriteJunitForServices(t *testing.T) {
	// TODO: No tests to handle actual XML overwrite. All test cases below only handle new XML
	// being generated.

	cases := []struct {
		description       string
		src               []byte
		services          []serviceResult
		testTarget        string
		testBinary        string
		testFailed        bool
		expectXMLFailures bool
	}{
		{
			description:       "Test process succeeded, no services, no test-generated XML",
			src:               nil,
			services:          []serviceResult{},
			testTarget:        "fooTarget",
			testBinary:        "fooBinary",
			testFailed:        false,
			expectXMLFailures: false,
		},
		{
			description:       "Test process failed, no services, no test-generated XML",
			src:               nil,
			services:          []serviceResult{},
			testTarget:        "fooTarget",
			testBinary:        "fooBinary",
			testFailed:        true,
			expectXMLFailures: true,
		},
		{
			description: "Test process succeeded, at least one service failure, no test-generated XML",
			src:         nil,
			services: []serviceResult{{
				name:          "fakeservice",
				startDuration: time.Millisecond,
				failed:        true,
			}},
			testTarget:        "fooTarget",
			testBinary:        "fooBinary",
			testFailed:        false,
			expectXMLFailures: true,
		},
		{
			description: "Test process failed, at least one service failure, no test-generated XML",
			src:         nil,
			services: []serviceResult{{
				name:          "fakeservice",
				startDuration: time.Millisecond,
				failed:        true,
			}},
			testTarget:        "fooTarget",
			testBinary:        "fooBinary",
			testFailed:        true,
			expectXMLFailures: true,
		},
		{
			description: "Test process succeeded, all services launched correctly, no test-generated XML",
			src:         nil,
			services: []serviceResult{{
				name:          "fakeservice",
				startDuration: time.Millisecond,
				failed:        false,
			}},
			testTarget:        "fooTarget",
			testBinary:        "fooBinary",
			testFailed:        false,
			expectXMLFailures: false,
		},
		{
			description: "Test process failed, all services launched correctly, no test-generated XML",
			src:         nil,
			services: []serviceResult{{
				name:          "fakeservice",
				startDuration: time.Millisecond,
				failed:        false,
			}},
			testTarget:        "fooTarget",
			testBinary:        "fooBinary",
			testFailed:        true,
			expectXMLFailures: true,
		},
	}

	bazelTempDir := bazel.TempDir()
	for _, c := range cases {
		tmpDir, tErr := ioutil.TempDir(bazelTempDir, "test1")
		require.NoError(t, tErr, "Unexpected error creating tempdir")

		xmlPath := path.Join(tmpDir, "test.xml")
		var src io.ReadSeeker
		if c.src != nil {
			src = bytes.NewReader(c.src)
		}

		ti := testInfo{
			target:         c.testTarget,
			binary:         c.testBinary,
			failed:         c.testFailed,
			duration:       1 * time.Second,
			totalDuration:  1 * time.Second,
			serviceResults: c.services,
		}

		err := overwriteJunitForServices(src, xmlPath, ti)
		require.NoError(t, err, "Unexpected error while overwriting junit")

		// Now, read the XML file generated and assert it has/doesnt-have tests with failures
		reader, openErr := os.Open(xmlPath)
		require.NoError(t, openErr, "Unexpected error while opening junit file")

		suite, parseErr := junit.ParseFromReader(reader)
		require.NoError(t, parseErr, "Unexpected error while parsing junit file")

		if c.expectXMLFailures {
			if !suite.HasFailingTest() {
				t.Errorf("For case '%s', expected test failures, but found none in junit XML: %+v", c.description, suite)
			}
		} else {
			if suite.HasFailingTest() {
				t.Errorf("For case '%s', expected no test failures, but junit XML has failures: %+v", c.description, suite)
			}
		}
	}
}

func TestOverwriteJunitForServicesWithRaces(t *testing.T) {
	tmpDir, tErr := ioutil.TempDir(bazel.TempDir(), "test1")
	require.NoError(t, tErr, "Unexpected error creating tempdir")
	defer os.RemoveAll(tmpDir)
	xmlPath := path.Join(tmpDir, "test.xml")

	services := serviceResults{
		{
			name:   "service1",
			failed: true,
			failureMessage: &svclib_proto.StatusResp_FailureMessage{
				Type: svclib_proto.StatusResp_FailureMessage_HAS_RACES.Enum(),
			},
		},
		{
			name:   "service2",
			failed: false,
		},
	}

	ti := testInfo{
		target:         "//target",
		binary:         "binary",
		failed:         true,
		duration:       1 * time.Second,
		totalDuration:  1 * time.Second,
		serviceResults: services,
	}
	require.NoError(t, overwriteJunitForServices(nil, xmlPath, ti))

	require.NoError(t, overwriteJunitForServicesWithRaces(xmlPath, services, 0, "racy_binary"))

	reader, openErr := os.Open(xmlPath)
	require.NoError(t, openErr, "Unexpected error while opening junit file")

	suite, parseErr := junit.ParseFromReader(reader)
	require.NoError(t, parseErr, "Unexpected error while parsing junit file")

	require.True(t, suite.HasFailingTest())
	var hasRaces bool
	for _, tc := range suite.TestCases {
		fr, ok := tc.GetFailureReason()
		if ok && fr == junit.HasRaces {
			hasRaces = true
			break
		}
	}
	require.True(t, hasRaces)
}

func TestOverwriteFailedWithNoRace(t *testing.T) {
	tmpDir, tErr := ioutil.TempDir(bazel.TempDir(), "test1")
	require.NoError(t, tErr, "Unexpected error creating tempdir")
	defer os.RemoveAll(tmpDir)
	xmlPath := path.Join(tmpDir, "test.xml")

	services := serviceResults{
		{
			name:   "service1",
			failed: false,
		},
		{
			name:   "service2",
			failed: false,
		},
	}

	ti := testInfo{
		target:         "//target",
		binary:         "binary",
		failed:         true,
		duration:       1 * time.Second,
		totalDuration:  1 * time.Second,
		serviceResults: services,
	}
	require.NoError(t, overwriteJunitForServices(nil, xmlPath, ti))

	require.NoError(t, overwriteJunitForServicesWithRaces(xmlPath, services, 0, "not_racy_binary"))

	reader, openErr := os.Open(xmlPath)
	require.NoError(t, openErr, "Unexpected error while opening junit file")

	suite, parseErr := junit.ParseFromReader(reader)
	require.NoError(t, parseErr, "Unexpected error while parsing junit file")

	// check that suite is still failed, but there is no races
	require.True(t, suite.HasFailingTest())
	var hasRaces bool
	for _, tc := range suite.TestCases {
		fr, ok := tc.GetFailureReason()
		if ok && fr == junit.HasRaces {
			hasRaces = true
			break
		}
	}
	require.False(t, hasRaces)
}

func TestOverwriteJunitForServicesWithRacesEmptyFile(t *testing.T) {
	tmpDir, tErr := ioutil.TempDir(bazel.TempDir(), "test1")
	require.NoError(t, tErr, "Unexpected error creating tempdir")
	defer os.RemoveAll(tmpDir)
	xmlPath := path.Join(tmpDir, "test.xml")

	services := serviceResults{
		{
			name:   "service1",
			failed: true,
			failureMessage: &svclib_proto.StatusResp_FailureMessage{
				Type: svclib_proto.StatusResp_FailureMessage_HAS_RACES.Enum(),
			},
		},
		{
			name:   "service2",
			failed: false,
		},
	}

	require.NoError(t, overwriteJunitForServicesWithRaces(xmlPath, services, 0, "racy_binary"))

	reader, openErr := os.Open(xmlPath)
	require.NoError(t, openErr, "Unexpected error while opening junit file")

	suite, parseErr := junit.ParseFromReader(reader)
	require.NoError(t, parseErr, "Unexpected error while parsing junit file")

	require.True(t, suite.HasFailingTest())
	var hasRaces bool
	for _, tc := range suite.TestCases {
		fr, ok := tc.GetFailureReason()
		if ok && fr == junit.HasRaces {
			hasRaces = true
			break
		}
	}
	require.True(t, hasRaces)
}
