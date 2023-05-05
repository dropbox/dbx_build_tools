package gomodlib

import (
	"io/ioutil"
	"path/filepath"
	"regexp"
	"strings"

	"golang.org/x/mod/modfile"
	"golang.org/x/mod/module"
)

// FindGoModDeps parses the go.mod file to extract a list of versions this module requires.
func FindGoModDeps(goModPath string) ([]module.Version, error) {
	modData, err := ioutil.ReadFile(goModPath)
	if err != nil {
		return nil, err
	}
	mf, err := modfile.Parse(goModPath, modData, nil)
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
func ResolveGoModVersion(versionString string) (string, string) {
	// Handle v2+ packages without go.mod
	if strings.Contains(versionString, "+") {
		return strings.Split(versionString, "+")[0], "version"
	}
	// Handle a v0/1 package without a go.mod
	if strings.Contains(versionString, "-") {
		versionStringComponents := strings.Split(versionString, "-")
		// If the version string follows the 3 segment format. Eg: v0.0.0-20210603081109-ebe580a85c40
		if len(versionStringComponents) == 3 {
			return versionStringComponents[2], "commit"
		}
		// If the version string doesn't follow the format but still contains a dash. Eg: v1.26.0-rc.1
		return versionStringComponents[0], "version"
	}
	// Everything else has semantic versioning
	return versionString, "version"
}

func DetermineModulePathAndMajorVersion(rootPath string) (string, string, error) {
	mfPath := filepath.Join(rootPath, "go.mod")
	modData, err := ioutil.ReadFile(mfPath)
	if err != nil {
		return "", "", err
	}
	mf, err := modfile.Parse(mfPath, modData, nil)
	if err != nil {
		return "", "", err
	}
	_, majorVersion := ParsePackageVersionFromString(mf.Module.Mod.Path)
	if majorVersion != "" {
		majorVersion = "v" + majorVersion
	}
	return mf.Module.Mod.Path, majorVersion, nil
}

func ParsePackageVersionFromString(pkg string) (string, string) {
	regexpObj := regexp.MustCompile(`(.*[vV]|^)(?P<versionString>(?P<majorVersionNum>[0-9]+)([.][0-9.]*|$))`)
	match := regexpObj.FindStringSubmatch(pkg)
	if len(match) > 0 {
		result := make(map[string]string)
		for i, name := range regexpObj.SubexpNames() {
			if i != 0 && name != "" {
				result[name] = match[i]
			}
		}
		return result["versionString"], result["majorVersionNum"]
	}
	return "", ""
}
