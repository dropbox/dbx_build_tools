package gomodlib

import (
	"testing"

	"github.com/stretchr/testify/require"
	"golang.org/x/mod/module"

	"dropbox/runfiles"
)

func TestResolveGoModVersion(t *testing.T) {
	type test struct {
		name   string
		input  string
		output string
	}

	testCases := []test{
		{"semver", "v1.2.3", "v1.2.3"},
		{"v2", "v2.4.5+incompatible", "v2.4.5"},
		{"v1", "v0.0.0-20180517173623-c85619274f5d", "c85619274f5d"},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(st *testing.T) {
			require.Equal(st, tc.output, ResolveGoModVersion(module.Version{Version: tc.input}))
		})
	}
}

func TestFindGoModDeps(t *testing.T) {
	fixture := runfiles.MustDataPath("@dbx_build_tools//go/src/dropbox/devtools/gomodlib/fixtures")
	deps, err := FindGoModDeps(fixture)
	require.NoError(t, err)
	require.NotEmpty(t, deps)
}
