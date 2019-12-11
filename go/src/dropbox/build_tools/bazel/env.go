package bazel

import "os"

// Drop-in replacement for os.TempDir() that respects Bazel test environment.
func TempDir() string {
	tmpDir := os.Getenv("TEST_TMPDIR")
	if tmpDir != "" {
		return tmpDir
	}
	return os.TempDir()
}
