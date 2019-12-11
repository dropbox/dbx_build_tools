package runfiles

// +build linux

import (
	"errors"
	"os"
	"path"
	"path/filepath"
	"strings"
)

var compiledStandalone string // "yes" if we don't have a runfiles tree at all

var (
	errBadPath          = errors.New("absolute Bazel path required")
	errBazelTarget      = errors.New("absolute Bazel target not allowed - use path")
	errRelativePath     = errors.New("absolute Bazel path only - no relative paths")
	errNoConfigRunfiles = errors.New("external config has no .runfiles")
	errEnvNotSet        = errors.New("$RUNFILES variable not set")
	errStandalone       = errors.New("binary doesn't have runfiles because it was compiled standalone")
)

// get the path to the runfiles folder (the folder ending in .runfiles)
func FolderPath() (string, error) {
	return DataPath("@")
}

func validateRepoPath(repoPath string) error {
	if !(strings.HasPrefix(repoPath, "//") || strings.HasPrefix(repoPath, "@")) {
		return &os.PathError{Op: "resolve", Path: repoPath, Err: errBadPath}
	}
	if strings.Contains(repoPath, ":") {
		return &os.PathError{Op: "resolve", Path: repoPath, Err: errBazelTarget}
	}
	for _, name := range strings.Split(repoPath, "/") {
		if name == "." || name == ".." {
			return &os.PathError{Op: "resolve", Path: repoPath, Err: errRelativePath}
		}
	}
	return nil
}

func IsBazelPath(repoPath string) bool {
	return validateRepoPath(repoPath) == nil
}

// repoPath should be an absolute Bazel path. We don't use colons to
// reference targets and we don't expand implicit targets.
func DataPath(repoPath string) (string, error) {
	if compiledStandalone == "yes" {
		return "", errStandalone
	}
	if err := validateRepoPath(repoPath); err != nil {
		return "", err
	}
	runfilesDir := os.Getenv("RUNFILES")
	if runfilesDir == "" {
		return "", errEnvNotSet
	}
	if strings.HasPrefix(repoPath, "@") {
		return filepath.Clean(path.Join(runfilesDir, "..", repoPath[1:])), nil
	}
	return path.Join(runfilesDir, repoPath[2:]), nil
}

// Same as DataPath but instead of returning an error, panics.
func MustDataPath(repoPath string) string {
	r, err := DataPath(repoPath)
	if err != nil {
		panic(err)
	}
	return r
}

func ConfigDataPath(repoPath, externalConfigPath string) (string, error) {
	if err := validateRepoPath(repoPath); err != nil {
		return "", err
	}

	runfilesDir := externalConfigPath + ".runfiles"
	stat, err := os.Stat(runfilesDir)
	if err != nil {
		return "", err
	} else if !stat.IsDir() {
		return "", &os.PathError{Op: "resolve", Path: externalConfigPath, Err: errNoConfigRunfiles}
	}

	return path.Join(runfilesDir, "__main__", repoPath[2:]), nil
}

// Same as ConfigDataPath but instead of returning an error, panics.
func MustConfigDataPath(repoPath, externalConfigPath string) string {
	r, err := ConfigDataPath(repoPath, externalConfigPath)
	if err != nil {
		panic(err)
	}
	return r
}
