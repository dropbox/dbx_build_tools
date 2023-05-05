package main

import (
	"io/ioutil"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestIsFailingJunit(t *testing.T) {
	runTest := func(t *testing.T, xml string, expectHasFail bool) {
		tempf, err := ioutil.TempFile("", "*.xml")
		require.NoError(t, err)
		tempf.WriteString(xml)
		tempf.Close()

		res, err := isFailingJUnit(tempf.Name())
		require.NoError(t, err)
		require.Equal(t, res, expectHasFail)
	}

	runTest(t, "<testsuite><testcase><failure></failure></testcase></testsuite>", true)
	runTest(t, "<testsuite><testcase></testcase></testsuite>", false)

	runTest(t, "<testsuites><testsuite/><testsuite><testcase><failure></failure></testcase></testsuite></testsuites>", true)
	runTest(t, "<testsuites><testsuite><testcase></testcase></testsuite></testsuites>", false)
}
