// Generate a Bazel BUILD file from a list of packages.
// Invoke this exactly as "go build"
package main

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"flag"
	"fmt"
	"go/build"
	"io"
	"io/fs"
	"io/ioutil"
	"log"
	"os"
	"path"
	"path/filepath"
	"strings"

	genlib "dropbox/build_tools/genbuildgolib"
	"dropbox/devtools/dbxvendor/godep"
	"godropbox/errors"
)

const (
	workspaceFile    = "WORKSPACE"
	goSrcDefaultPath = "go/src"
	// NOTE: That the unused imports are removed by automatic formatting
	buildHeaderTmpl = `load('%s//build_tools/go:go.bzl', 'dbx_go_binary', 'dbx_go_library', 'dbx_go_test')

`
)

func parseGoRepositoryPaths(filePath string) (map[string]string, error) {
	dbxGoDependencies, err := godep.LoadGoDepDefJson(filePath)
	if os.IsNotExist(err) {
		// Tolerate missing deps file for now.
		return nil, nil
	} else if err != nil {
		return nil, err
	}
	repoByImportPath := make(map[string]string, len(dbxGoDependencies))
	for _, gorepo := range dbxGoDependencies {
		repoByImportPath[gorepo.Importpath] = gorepo.Name
	}
	return repoByImportPath, nil
}

type ConfigGenerator struct {
	dryRun                    bool
	verbose                   bool
	embedUseAbsoluteFilepaths bool
	buildConfig               *genlib.GenBuildConfig

	onlyGenPkgs map[string]struct{}

	workspace  string
	goSrc      string
	moduleName string

	golangPkgs    map[string]struct{}
	processedPkgs map[string]struct{}

	repoByImportPath map[string]string

	visitStack []string // for detecting cycles

	repoFilesystem fs.StatFS
}

func (g *ConfigGenerator) isBuiltinPkg(pkgName string) bool {
	if g.isDbxPkg(pkgName) {
		return false
	}

	return genlib.IsBuiltinPkg(pkgName, &g.golangPkgs, g.verbose)
}

func (g *ConfigGenerator) isDbxInRepoPkg(pkgName string) bool {
	return strings.HasPrefix(pkgName, "dropbox/") ||
		strings.HasPrefix(pkgName, "godropbox/") ||
		strings.HasPrefix(pkgName, "atlas/")
}

func (g *ConfigGenerator) isDbxPkg(pkgName string) bool {
	return g.isDbxInRepoPkg(pkgName) ||
		strings.HasPrefix(pkgName, "github.com/dropbox")
}

func (g *ConfigGenerator) pathForInRepoGoPackage(pkg string) string {
	if g.goSrc == "" {
		return goSrcDefaultPath + "/" + pkg
	} else {
		return g.goSrc + "/" + pkg
	}
}

func (g *ConfigGenerator) bazelTargetForInRepoGoPackage(pkg string) string {
	if g.goSrc == "" {
		return "@dbx_build_tools//" + goSrcDefaultPath + "/" + pkg
	} else {
		return "//" + g.goSrc + "/" + pkg
	}
}

func (g *ConfigGenerator) getDepBazelTarget(pkg string) string {

	// Fast path:
	// First, check if the code is in one of non-external directories
	// If so, we just import directly, omitting the external
	// module search slowpath ( that stat for .dbxvendor.json files )
	if g.isDbxInRepoPkg(pkg) {
		return g.bazelTargetForInRepoGoPackage(pkg)
	}

	// Algorithm to resolve external dependencies is as follows:
	// Take the import path, and check for existence of an external repo
	// or vendored module that exports it.
	// If found, add it to bazel imports and finish
	// Otherwise, take the parent of the import path and repeat
	dir := pkg
	for dir != "." {
		// We check if we have a registered repo at the import path
		if repo, ok := g.repoByImportPath[dir]; ok {
			relativePkg := ":" + repo
			if pkg != dir {
				relativePkg = pkg[len(dir)+1:]
			}
			return fmt.Sprintf("@%s//%s", repo, relativePkg)
		}

		// If we don't have an external repo, we could still have a vendored-in module
		// since those are not in the .json file. Check .dbxvendor.json existence for that.
		dbxvendorJsonPath := g.pathForInRepoGoPackage(dir) + "/.dbxvendor.json"
		if _, err := g.repoFilesystem.Stat(dbxvendorJsonPath); err == nil {
			return g.bazelTargetForInRepoGoPackage(pkg)
		}

		dir = path.Dir(dir)
	}

	// Fall back to "in-repo" path
	// This is compatible with pre-refactoring logic, but doesn't make much sense.
	// TODO: We should verify if anything reaches this package, fix it if necessary and change this line to panic()
	return g.bazelTargetForInRepoGoPackage(pkg)
}

func (g *ConfigGenerator) createDeps(pkg *build.Package, pkgs []string) []string {
	deps := make([]string, 0, len(pkgs))
	for _, pkg := range pkgs {
		if g.isBuiltinPkg(pkg) {
			continue
		}

		dep := g.getDepBazelTarget(pkg)
		deps = append(deps, dep)
	}
	return genlib.UniqSort(deps)
}

func (g *ConfigGenerator) generateConfig(pkg *build.Package) (*bytes.Buffer, error) {
	if g.verbose {
		fmt.Println("Generating config for", pkg.Dir)
	}

	deps := g.createDeps(pkg, pkg.Imports)

	cgoIncludeFlags,
		cgoCXXFlags,
		cgoLinkerFlags,
		cgoDeps,
		srcs,
		cgoSrcs,
		name,
		err := genlib.PopulateBuildAttributes(pkg, g.moduleName, g.buildConfig)
	if err != nil {
		return nil, err
	}

	buffer := &bytes.Buffer{}
	if g.moduleName == "" {
		_, _ = buffer.WriteString(fmt.Sprintf(buildHeaderTmpl, "@dbx_build_tools"))
	} else {
		_, _ = buffer.WriteString(fmt.Sprintf(buildHeaderTmpl, "@"))
		if pkg.Dir == "." && pkg.Name != "main" {
			name = genlib.PathToExtRepoName(g.moduleName, "")
		}
	}

	// In the majority of cases a go package doesn't have any build constraints but if it does
	// We construct a tag map
	tm := genlib.TagMap{}
	if len(pkg.AllTags) > 0 {
		tm, err = genlib.BuildTagmapForPkg(pkg.Dir)
		if err != nil {
			return nil, errors.Wrap(err, "Could not build tag map")
		}
	}

	// Similar to TagMaps in the majority of cases there aren't any
	ecw, err := genlib.BuildEmbedConfigForPkg(pkg, g.workspace, g.embedUseAbsoluteFilepaths)
	if err != nil {
		return nil, err
	}

	rule := "dbx_go_library"
	moduleName := g.moduleName
	if pkg.Name == "main" {
		rule = "dbx_go_binary"
		moduleName = ""
	}
	writeTarget(
		buffer,
		rule,
		name,
		pkg.ImportPath,
		srcs,
		deps,
		cgoSrcs,
		cgoDeps,
		cgoIncludeFlags,
		cgoLinkerFlags,
		cgoCXXFlags,
		moduleName,
		tm,
		ecw,
	)

	// write test target
	if g.isDbxPkg(pkg.ImportPath) {
		if len(pkg.TestGoFiles) > 0 {
			var testSrcs []string
			testSrcs = append(testSrcs, srcs...)
			testSrcs = append(testSrcs, pkg.TestGoFiles...)
			testSrcs = genlib.UniqSort(testSrcs)

			var testDeps []string
			testDeps = append(testDeps, deps...)
			testDeps = append(testDeps, g.createDeps(pkg, pkg.TestImports)...)
			testDeps = genlib.UniqSort(testDeps)

			_, _ = buffer.WriteString("\n")
			writeTarget(
				buffer,
				"dbx_go_test",
				name+"_test",
				pkg.ImportPath,
				testSrcs,
				testDeps,
				cgoSrcs,
				cgoDeps,
				cgoIncludeFlags,
				cgoLinkerFlags,
				cgoCXXFlags,
				g.moduleName,
				tm,
				ecw,
			)
		}

		if len(pkg.XTestGoFiles) > 0 {
			xTestSrcs := genlib.UniqSort(pkg.XTestGoFiles)
			xTestDeps := genlib.UniqSort(g.createDeps(pkg, pkg.XTestImports))

			_, _ = buffer.WriteString("\n")
			writeTarget(
				buffer,
				"dbx_go_test",
				name+"_ext_test",
				pkg.ImportPath,
				xTestSrcs,
				xTestDeps,
				nil,
				nil,
				nil,
				nil,
				nil,
				pkg.ImportPath+"_test",
				tm,
				ecw,
			)
		}
	}

	return buffer, nil
}

func (g *ConfigGenerator) Process(goPkgPath string) error {
	err := g.process(goPkgPath)
	if err != nil {
		return errors.New("Failed to process " + goPkgPath + ": " + err.Error())
	}

	return nil
}

func (g *ConfigGenerator) process(goPkgPath string) error {
	isBuiltinPkg := g.isBuiltinPkg(path.Join(g.moduleName, goPkgPath))
	isValid := genlib.ValidateGoPkgPath(
		g.verbose, isBuiltinPkg, goPkgPath, g.workspace, g.goSrc, g.processedPkgs, &g.visitStack)
	if !isValid {
		return nil
	}

	g.visitStack = append(g.visitStack, goPkgPath)
	defer func() { g.visitStack = (g.visitStack)[:len(g.visitStack)-1] }()

	pkg, err := genlib.PopulatePackageInfo(g.workspace, g.goSrc, goPkgPath, g.buildConfig)
	if pkg == nil {
		return err
	}

	// Generate config files for dependencies first.
	visit := func(toVisit []string) error {
		for _, dep := range toVisit {
			if dep == goPkgPath { // can include self in tests
				continue
			}

			shouldGenerate := true
			if g.onlyGenPkgs != nil {
				_, shouldGenerate = g.onlyGenPkgs[dep]
			}

			if shouldGenerate {
				err = g.Process(dep)
				if err != nil {
					return err
				}
			}
		}
		return nil
	}

	// NOTE: pkg.XTestImports is not visited.
	err = visit(pkg.Imports)
	if err != nil {
		return err
	}
	if g.isDbxPkg(goPkgPath) {
		err = visit(pkg.TestImports)
		if err != nil {
			return err
		}
	}

	buffer, err := g.generateConfig(pkg)
	if err != nil {
		return err
	}
	err = genlib.WriteToBuildConfigFile(g.dryRun, pkg, *buildFilename, buffer)
	if err != nil {
		return err
	}

	g.processedPkgs[goPkgPath] = struct{}{}
	return nil
}

// TODO: Use a struct to avoid having to pass in a million parameters
func writeTarget(
	buffer io.StringWriter,
	rule string,
	name string,
	pkgPath string,
	srcs []string,
	deps []string,
	cgoSrcs []string,
	cgoDeps []string,
	cgoIncludeFlags []string,
	cgoLinkerFlags []string,
	cgoCXXFlags []string,
	moduleName string,
	tm genlib.TagMap,
	ecw genlib.EmbedConfigWrapper,
) {

	if len(srcs) == 0 &&
		len(deps) == 0 &&
		len(cgoSrcs) == 0 &&
		len(cgoDeps) == 0 {

		// bazel freaks out when the go build rule doesn't have any input
		return
	}

	genlib.WriteCommonBuildAttrToTarget(
		buffer, rule, name, srcs, deps,
		cgoSrcs, cgoDeps, cgoIncludeFlags, cgoLinkerFlags, cgoCXXFlags,
		moduleName, tm, ecw)
	if rule == "dbx_go_library" {
		internalParentPath := pkgPath
		component := ""
		hasInternal := false
		for internalParentPath != "." {
			internalParentPath, component = path.Split(internalParentPath)
			internalParentPath = filepath.Clean(internalParentPath)

			if component == "internal" {
				hasInternal = true
				break
			}
		}

		if hasInternal && !strings.HasPrefix(pkgPath, "dropbox/proto/") {
			_, _ = buffer.WriteString("  visibility=[\n")
			_, _ = buffer.WriteString("    '//go/src/")
			_, _ = buffer.WriteString(internalParentPath)
			_, _ = buffer.WriteString(":__subpackages__',\n")
			_, _ = buffer.WriteString("  ],\n")
		} else if strings.HasPrefix(pkgPath, "dropbox/") {
			// In general, 3rd party packages (including godropbox)
			// should not import from dropbox/...

			_, _ = buffer.WriteString("  visibility=[\n")
			_, _ = buffer.WriteString(
				"    '//go/src/atlas:__subpackages__',\n")
			_, _ = buffer.WriteString(
				"    '//go/src/dropbox:__subpackages__',\n")

			if pkgPath == "dropbox/proto/mysql" {
				// The internal dropbox/proto/mysql definitions is a
				// superset of the open sourced definitions.
				_, _ = buffer.WriteString(
					"    '//go/src/godropbox/database/binlog:__subpackages__',\n")
			}

			_, _ = buffer.WriteString("  ],\n")
		} else if strings.HasPrefix(pkgPath, "atlas/") {
			// In general, only the same service should import from atlas/<service>/...
			_, _ = buffer.WriteString("  visibility=[\n")
			service := strings.Split(pkgPath, "/")[1]
			_, _ = buffer.WriteString(
				fmt.Sprintf("    '//go/src/atlas/%s:__subpackages__',\n", service))
			_, _ = buffer.WriteString("  ],\n")
		} else {
			// 3rd party packages are public.
			_, _ = buffer.WriteString("  visibility=[\n")
			_, _ = buffer.WriteString("    '//visibility:public',\n")
			_, _ = buffer.WriteString("  ],\n")
		}
	} else if rule == "dbx_go_binary" {
		// NOTE: for now go binaries default to public.
		_, _ = buffer.WriteString("  visibility=[\n")
		_, _ = buffer.WriteString("    '//visibility:public',\n")
		_, _ = buffer.WriteString("  ]\n")
	}

	_, _ = buffer.WriteString(")\n")
}

func findWorkspace(startingDir string) (string, error) {
	checkDir := startingDir
	for {
		if checkDir == "/" {
			return "", fmt.Errorf("directory not in a Bazel workspace: %v", startingDir)
		}
		if _, err := os.Stat(path.Join(checkDir, workspaceFile)); err == nil {
			return checkDir, nil
		}
		checkDir = path.Dir(checkDir)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, "Usage of %s:\n", os.Args[0])
	flag.PrintDefaults()
	fmt.Fprintf(os.Stderr, `
Examples:

Generate a BUILD file in current directory:

  gen-build-go

Generate a BUILD file for a package in the WORKSPACE-implied GOPATH:
  NOTE: This tool ignores the GOPATH environment variable.

  gen-build-go dropbox/dbxinit/dbxinitctl

`)
}

var buildConfigPath = flag.String(
	"build-config",
	"",
	"Path to the build config.")

var buildFilename = flag.String(
	"build-filename",
	"BUILD",
	"The name of the build file to write.")

var moduleName = flag.String(
	"module-name",
	"",
	"the name or import path of the module",
)

var dependenciesFilePath = flag.String(
	"dependencies-path",
	godep.GoDepDefJsonPath,
	"The path to dbx_go_dependencies.json, relative to the workspace",
)

func main() {
	flag.Usage = usage
	dryRun := flag.Bool("dry-run", false, "dry run - just echo BUILD files")
	verbose := flag.Bool("verbose", false, "show more detail during analysis")
	embedUseAbsoluteFilepaths := flag.Bool("embed-use-absolute-filepaths", false, "use absolute filepaths in embed config")
	skipDepsGeneration := flag.Bool(
		"skip-deps-generation",
		false,
		"When true, only generate BUILD files for the specified packages")
	flag.Parse()
	log.SetFlags(0)

	packages := flag.Args()
	if len(packages) == 0 {
		log.Fatal("No package specified")
	}

	var workspace string
	var goSrc string

	if *moduleName == "" {
		cwd, err := os.Getwd()
		if err != nil {
			log.Fatal("Unable to get cwd:", err)
		}
		workspace, err = findWorkspace(cwd)
		if err != nil {
			log.Fatal("Unable to find workspace:", err)
		}
		goSrc = "go/src"

		// Force GOPATH to be defined by the workspace.
		build.Default.GOPATH = path.Join(workspace, "go")
	} else {
		if len(packages) != 1 {
			log.Fatalf("Exactly one package (root of the module) must be specified if --module-name is set")
		}
	}

	if *buildConfigPath == "" {
		log.Fatalf("--build-config is required")
	}

	buildConfig := &genlib.GenBuildConfig{}
	buildConfigData, err := ioutil.ReadFile(*buildConfigPath)
	if err != nil {
		log.Fatalf("failed to read build config, err: %v", err)
	}
	if err = json.Unmarshal(buildConfigData, buildConfig); err != nil {
		log.Fatalf("failed to parse build config, err: %v", err)
	}

	build.Default.ReleaseTags = buildConfig.ReleaseTags

	var onlyGenPkgs map[string]struct{} = nil
	if *skipDepsGeneration {
		onlyGenPkgs = make(map[string]struct{})
		for _, pkg := range packages {
			onlyGenPkgs[pkg] = struct{}{}
		}
	}

	repoByImportPath, err := parseGoRepositoryPaths(path.Join(workspace, *dependenciesFilePath))
	if err != nil {
		log.Fatalf("failed to read dbx_go_dependencies.json, err: %v", err)
	}

	generator := &ConfigGenerator{
		dryRun:                    *dryRun,
		verbose:                   *verbose,
		embedUseAbsoluteFilepaths: *embedUseAbsoluteFilepaths,
		buildConfig:               buildConfig,
		onlyGenPkgs:               onlyGenPkgs,
		workspace:                 workspace,
		goSrc:                     goSrc,
		golangPkgs:                make(map[string]struct{}),
		processedPkgs:             make(map[string]struct{}),
		repoByImportPath:          repoByImportPath,
		repoFilesystem:            os.DirFS("./").(fs.StatFS),
	}

	var lastErr error
	for _, pkg := range packages {
		var err error
		if *moduleName == "" {
			err = generator.Process(pkg)
		} else {
			err = filepath.Walk(pkg,
				func(path string, f os.FileInfo, err error) error {
					if !f.IsDir() {
						if strings.HasSuffix(path, "/BUILD.bazel") {
							if err := os.Remove(path); err != nil {
								fmt.Println("Could not remove existing BUILD.bazel file at: " + path)
							}
						}
						return nil
					}
					generator.moduleName = filepath.Join(*moduleName, path)
					if err := generator.Process(filepath.Join(pkg, path)); err != nil {
						lastErr = err
					}
					return err
				},
			)
		}
		if err != nil {
			lastErr = err
		}
	}

	if lastErr != nil {
		log.Fatal("Failed to create all configs:", lastErr)
	}
}
