package svclib

import (
	"os"
	"path/filepath"
)

func mustTmpdirPath(path string) string {
	tmp := os.Getenv("TEST_TMPDIR")
	if tmp == "" {
		panic("TEST_TMPDIR not set. Service tests must be run with |bazel test| or |bzl itest-run|. See https://dbx.link/bazel/bzl_itest_manual for more information on running service tests.")
	}
	return filepath.Join(tmp, path)
}

var SvcdPortLocation = mustTmpdirPath("svcd-port")

// These next two variables are used to keep track of stale service definitions

// path to the current version file of the service definitions
var CurrentServiceDefsVersionFile = mustTmpdirPath("current-svc-defs-version")

// path to a version file frozen at the time of service startup
var FrozenServiceDefsVersionFile = mustTmpdirPath("frozen-svc-defs-version")
