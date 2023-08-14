package main

import (
	"os"
	"testing"

	"github.com/stretchr/testify/require"

	"dropbox/runfiles"
)

func TestSrcsAreUpToDate(t *testing.T) {
	srcsPath := runfiles.MustDataPath("@dbx_build_tools//build_tools/go/dbx_go_gen_build_srcs.bzl")
	actualContent, err := os.ReadFile(srcsPath)
	require.NoError(t, err)

	expectedContent := generateSrcs()
	require.Equal(t, string(expectedContent), string(actualContent))
}
