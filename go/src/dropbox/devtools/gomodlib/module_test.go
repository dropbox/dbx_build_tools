package gomodlib

import (
	"testing"

	"github.com/stretchr/testify/require"

	"dropbox/runfiles"
)

func TestResolveGoModVersion(t *testing.T) {
	type test struct {
		name    string
		input   string
		rev     string
		revType string
	}

	testCases := []test{
		{"semver", "v1.2.3", "v1.2.3", "version"},
		{"v2", "v2.4.5+incompatible", "v2.4.5", "version"},
		{"v1", "v0.0.0-20180517173623-c85619274f5d", "c85619274f5d", "commit"},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(st *testing.T) {
			rev, revType := ResolveGoModVersion(tc.input)
			require.Equal(st, tc.rev, rev)
			require.Equal(st, tc.revType, revType)
		})
	}
}

func TestFindGoModDeps(t *testing.T) {
	fixture := runfiles.MustDataPath("@dbx_build_tools//go/src/dropbox/devtools/gomodlib/fixtures")
	deps, err := FindGoModDeps(fixture + "/go.mod")
	require.NoError(t, err)
	require.NotEmpty(t, deps)
}

func TestParsePackageVersionFromString(t *testing.T) {
	type parseOutput struct {
		versionString   string
		majorVersionNum string
	}

	type test struct {
		input  string
		output parseOutput
	}

	testCases := []test{
		{"v1.2.3", parseOutput{"1.2.3", "1"}},
		{"v2.4.5+incompatible", parseOutput{"2.4.5", "2"}},
		{"v0.0.0-20180517173623-c85619274f5d", parseOutput{"0.0.0", "0"}},
		{"check.v1", parseOutput{"1", "1"}},
		{"1", parseOutput{"1", "1"}},
		{"v1-", parseOutput{"", ""}},
	}

	for _, tc := range testCases {
		versionString, majorVersionNum := ParsePackageVersionFromString(tc.input)
		if tc.output.versionString != versionString || tc.output.majorVersionNum != majorVersionNum {
			t.Errorf("got %s and %s, wanted %s and %s",
				versionString, majorVersionNum, tc.output.versionString, tc.output.majorVersionNum)
		}
	}
}
