package gomodlib

import (
	"io/ioutil"
	"path/filepath"
	"strings"

	"golang.org/x/mod/modfile"
	"golang.org/x/mod/module"
)

// FindGoModDeps parses the go.mod file to extract a list of versions this module requires.
func FindGoModDeps(rootPath string) ([]module.Version, error) {
	mfPath := filepath.Join(rootPath, "go.mod")
	modData, err := ioutil.ReadFile(mfPath)
	if err != nil {
		return nil, err
	}
	mf, err := modfile.Parse(mfPath, modData, nil)
	if err != nil {
		return nil, err
	}
	// TODO(rossd): We are ignoring Exclude and Replace to make this simple
	reqs := make([]module.Version, 0, len(mf.Require))
	for _, r := range mf.Require {
		reqs = append(reqs, r.Mod)
	}
	return reqs, nil
}

// ResolveGoModVersion is used to extract the actual version to request from upstream. There are 3
// different ways versions are written depending on how the upstream does its version tagging and
// if it supports go modules. More information is available on the go website:
// https://golang.org/cmd/go/#hdr-Modules__module_versions__and_more
func ResolveGoModVersion(ver module.Version) string {
	// Handle v2+ packages without go.mod
	if strings.Contains(ver.Version, "+") {
		return strings.Split(ver.Version, "+")[0]
	}
	// Handle a v0/1 package without a go.mod
	if strings.Contains(ver.Version, "-") {
		versionStringComponents := strings.Split(ver.Version, "-")
		// If the version string follows the 3 segment format. Eg: v0.0.0-20210603081109-ebe580a85c40
		if len(versionStringComponents) == 3 {
			return versionStringComponents[2]
		}
		// If the version string doesn't follow the format but still contains a dash. Eg: v1.26.0-rc.1
		return versionStringComponents[0]
	}
	// Everything else has semantic versioning
	return ver.Version
}
