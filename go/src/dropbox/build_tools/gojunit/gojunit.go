package gojunit

import (
	"bytes"
	"dropbox/build_tools/junit"
	"fmt"
	"strings"
)

type Event struct {
	Action  string
	Test    string   `json:",omitempty"`
	Elapsed *float64 `json:",omitempty"`
	Output  string   `json:",omitempty"`
}

// Expand tabs to spaces, treating them as tabulation of length tabLength.
func expandTabs(input string, tabLength int) string {
	buffer := &bytes.Buffer{}
	for _, r := range input {
		if r != '\t' {
			buffer.WriteRune(r)
		} else {
			numSpaces := tabLength - (buffer.Len() % tabLength)
			for j := 0; j < numSpaces; j++ {
				buffer.WriteRune(' ')
			}
		}
	}
	return buffer.String()
}

// Parses a list of events from test2json
func ParseEvents(prefix string, events []Event) ([]junit.JUnitTestCase, float64) {
	testCases := make(map[string]*junit.JUnitTestCase, 0)
	outputBuffers := make(map[string]*bytes.Buffer)
	elapsedTime := 0.0

	for _, event := range events {
		switch event.Action {
		case "run":
			testCases[event.Test] = &junit.JUnitTestCase{
				Name: prefix + event.Test,
			}
			outputBuffers[event.Test] = &bytes.Buffer{}
		case "cont":
			// nothing
		case "output":
			// ignore PASS at the end
			if event.Test != "" {
				// The output of testify is ugly and includes \r which is unfortunate
				// We want to display only text to the right of a \r, just like a terminal
				// would. (Note, in go, unlike python, strings.Split never returns an
				// empty slice).
				//
				// But before we do the split, replace \r\n line endings if they exist with
				// \n (otherwise, picking the last element will just get the newline)
				carriageSplit := strings.Split(strings.Replace(event.Output, "\r\n", "\n", -1), "\r")

				// Why 8 spaces? Because it looks good with testify output, which is
				// probably the main thing outputting tabs (4 is too short)
				actualOutput := expandTabs(carriageSplit[len(carriageSplit)-1], 8)
				// event.Output includes a \n
				outputBuffers[event.Test].WriteString(actualOutput)
			}
		case "pass":
			// pass and fail have some silly events with empty test that we can ignore
			if event.Test != "" {
				elapsedTime += *event.Elapsed
				testCases[event.Test].Time = fmt.Sprintf("%f", *event.Elapsed)
			}
		case "skip":
			// unsure if skip has the silly events, but playing it safe
			if event.Test != "" {
				elapsedTime += *event.Elapsed
				testCases[event.Test].Time = fmt.Sprintf("%f", *event.Elapsed)
				testCases[event.Test].SkipMessage = &junit.JUnitSkipMessage{
					Message: "go test skipped",
				}
			}
		case "fail":
			// pass and fail have some silly events with empty test that we can ignore
			if event.Test != "" {
				testCases[event.Test].Failure = &junit.JUnitFailure{
					Message: "go test failed",
				}
				elapsedTime += *event.Elapsed
				testCases[event.Test].Time = fmt.Sprintf("%f", *event.Elapsed)
			}
		}
	}

	for testName, testCase := range testCases {
		testCase.SystemOut = outputBuffers[testName].String()
	}

	result := make([]junit.JUnitTestCase, 0, len(testCases))
	for _, testCase := range testCases {
		result = append(result, *testCase)
	}
	return result, elapsedTime
}
