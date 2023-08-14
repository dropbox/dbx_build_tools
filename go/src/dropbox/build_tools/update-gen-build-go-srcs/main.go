package main

import (
	"bytes"
	"fmt"
	"log"
	"os"
	"path"
	"path/filepath"
	"sort"

	"github.com/bazelbuild/buildtools/wspace"

	"dropbox/runfiles"
)

const rootPath = "//go/src/dropbox/build_tools/gen-build-go"

func mustGoLabels(runfilesPath string) []string {
	dir := runfiles.MustDataPath(runfilesPath)
	goFiles, err := filepath.Glob(path.Join(dir, "*.go"))
	if err != nil {
		log.Fatal(err)
	}
	labels := make([]string, len(goFiles))
	for i, goFile := range goFiles {
		relGoFile, err := filepath.Rel(dir, goFile)
		if err != nil {
			log.Fatal(err)
		}
		labels[i] = fmt.Sprintf("%s:%s", runfilesPath, relGoFile)
	}
	return labels
}

func generateSrcs() []byte {
	labels := []string{
		rootPath + ":go.mod",
		rootPath + ":go.sum",
	}
	labels = append(labels, mustGoLabels(rootPath)...)
	labels = append(labels, mustGoLabels(rootPath+"/lib")...)
	sort.Strings(labels)

	var buffer bytes.Buffer
	fmt.Fprintf(&buffer, "# @%s by //go/src/dropbox/build_tools/gen-build-go/gen-srcs\n\n", "generated")
	fmt.Fprintf(&buffer, "GO_GEN_BUILD_SRCS = [\n")
	for _, label := range labels {
		fmt.Fprintf(&buffer, "    Label(\"%s\"),\n", label)
	}
	fmt.Fprintf(&buffer, "]\n")
	return buffer.Bytes()
}

func main() {
	content := generateSrcs()
	workspaceRoot, _ := wspace.FindWorkspaceRoot("")
	srcsPath := path.Join(workspaceRoot, "build_tools/go/dbx_go_gen_build_srcs.bzl")
	err := os.WriteFile(srcsPath, content, 0644)
	if err != nil {
		log.Fatal(err)
	}
}
