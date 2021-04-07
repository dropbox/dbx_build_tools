// Generate a Bazel BUILD file from a list of packages.
// Invoke this exactly as "go build"
package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"go/build"
	"io/ioutil"
	"log"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	bazelbuild "github.com/bazelbuild/buildtools/build"
)

const (
	workspaceFile = "WORKSPACE"

	buildHeaderTmpl = `load('@dbx_build_tools//build_tools/go:go.bzl', 'dbx_go_binary', 'dbx_go_library', 'dbx_go_test')

`
)

var linkerMp = map[string]struct {
	Deps     []string
	LibFlags []string
}{
	"boost_1_54_algorithm": {
		Deps: []string{"@org_boost//:algorithm"},
	},
	"boost_1_54_filesystem": {
		Deps: []string{"@org_boost//:filesystem"},
	},
	"boost_1_54_lexical_cast": {
		Deps: []string{"@org_boost//:lexical_cast"},
	},
	"boost_1_54_regex": {
		Deps: []string{"@org_boost//:regex"},
	},
	"boost_1_54_system": {
		Deps: []string{"@org_boost//:system"},
	},
	"boost_1_54_thread": {
		Deps: []string{"@org_boost//:thread"},
	},
	"bpf": {
		Deps: []string{"@libbpf//:bpf"},
	},
	"brotli_ffi": {
		Deps: []string{"//rust/vendor/brotli-ffi-1.1.1:go_brotli_dep_lib"},
	},
	"bz2": {
		Deps: []string{"@org_bzip_bzip2//:bz2"},
	},
	"crypto": {
		Deps: []string{"@org_openssl//:ssl"},
	},
	"flatbuffers": {
		Deps: []string{"@com_github_google_flatbuffers//:flatbuffers"},
	},
	"jemalloc": {
		Deps: []string{"@jemalloc//:jemalloc"},
	},
	"leveldb": {
		Deps: []string{"@leveldb//:leveldb", "@snappy//:snappy"},
	},
	"lxc": {
		Deps: []string{"@org_linuxcontainers_lxc//:lxc"},
	},
	"lz4": {
		Deps: []string{"@lz4//:lz4"},
	},
	"mysqlclient_r": {
		Deps: []string{"//thirdparty/percona-server-5.6:perconaserverclient"},
	},
	"protobuf": {
		Deps: []string{"//thirdparty/protobuf:protobuf"},
	},
	"rdkafka": {
		Deps: []string{"@rdkafka//:rdkafka"},
	},
	"rocksdb": {
		Deps: []string{"@rocksdb//:rocksdb_with_jemalloc"},
	},
	"rust_ffi_acl_lib_static": {
		Deps: []string{"//rust/filesystem/ffi_acl:acl_lib_static"},
	},
	"rust_ffi_dbxpath_c": {
		Deps: []string{"//rust/filesystem/dbxpath:dbxpath_c"},
	},
	"rust_ffi_fast_rsync_lib": {
		Deps: []string{"//rust/dropbox/fast_rsync_ffi:fast_rsync_ffi_lib"},
	},
	"rust_ffi_go_dep": {
		Deps: []string{"//rust/examples/go_dep:go_dep_lib"},
	},
	"rust_ffi_namespace_view_lib": {
		Deps: []string{"//rust/dropbox/namespace_view_ffi:namespace_view_ffi_lib"},
	},
	"rust_ffi_osd2_disk_tracker": {
		Deps: []string{"//rust/mp/osd2/osd2_ffi:osd2_ffi_cc_lib"},
	},
	"snappy": {
		Deps: []string{"@snappy//:snappy"},
	},
	"zookeeper_mt_3_4_6": {
		Deps: []string{"@zookeeper//:zookeeper_mt"},
	},
	"zstd": {
		Deps: []string{"@zstd//:zstd"},
	},
}

var whitelistedLinkerModules = []string{"m", "rt", "util", "dl"}

// Paths within //go/src/... which permit build_tags in BUILD.in.
var whitelistForBuildTags = []string{
	"gonum.org/",
	"github.com/opencontainers/runc",
}

func isWhitelistedForBuildTags(goPkgPath string) bool {
	for _, whitelistPrefix := range whitelistForBuildTags {
		if strings.HasPrefix(goPkgPath, whitelistPrefix) {
			return true
		}
	}
	return false
}

type targetList []string

func (s targetList) Len() int {
	return len(s)
}

func (s targetList) Swap(i int, j int) {
	s[i], s[j] = s[j], s[i]
}

func (s targetList) Less(i int, j int) bool {
	p1 := s.priority(s[i])
	p2 := s.priority(s[j])

	if p1 < p2 {
		return true
	}
	if p2 < p1 {
		return false
	}

	return s[i] < s[j]
}

func (s targetList) priority(target string) int {
	if strings.HasPrefix(target, "//") {
		return 3
	}
	if strings.HasPrefix(target, ":") {
		return 2
	}
	return 1
}

func uniqSort(items []string) []string {
	keys := make(map[string]struct{})
	deduped := make(targetList, 0, len(items))

	for _, item := range items {
		if _, ok := keys[item]; ok {
			continue
		}

		keys[item] = struct{}{}
		deduped = append(deduped, item)
	}

	sort.Sort(deduped)

	return []string(deduped)
}

type ConfigGenerator struct {
	dryRun  bool
	verbose bool

	onlyGenPkgs map[string]struct{}

	workspace string
	goSrc     string

	golangPkgs    map[string]struct{}
	processedPkgs map[string]struct{}

	visitStack []string // for detecting cycles
}

func init() {
	build.Default.ReleaseTags = []string{"go1.1", "go1.2", "go1.3", "go1.4", "go1.5", "go1.6", "go1.7", "go1.8", "go1.9", "go1.10", "go1.11", "go1.12"}
}

func (g *ConfigGenerator) isBuiltinPkg(pkgName string) bool {
	if pkgName == "C" { // c binding
		return true
	}

	if g.isDbxPkg(pkgName) {
		return false
	}

	// Check for a "testdata" component.
	for _, component := range strings.Split(pkgName, "/") {
		if component == "testdata" {
			return true
		}
	}

	// A "." in the name implies a url and thus clearly not builtin.
	if strings.Contains(strings.Split(pkgName, "/")[0], ".") {
		return false
	}

	if _, ok := g.golangPkgs[pkgName]; ok {
		return ok
	}

	_, err := build.Default.ImportDir(
		filepath.Join(build.Default.GOROOT, "src", pkgName),
		build.ImportComment&build.IgnoreVendor)

	if err != nil {
		if g.verbose {
			fmt.Printf("Can't find builtin pkg: %s %s\n", pkgName, filepath.Join(build.Default.GOROOT, "src", pkgName))
		}
		return false
	}

	g.golangPkgs[pkgName] = struct{}{}
	return true
}

func (g *ConfigGenerator) isDbxPkg(pkgName string) bool {
	return strings.HasPrefix(pkgName, "dropbox/") || strings.HasPrefix(pkgName, "godropbox/") || strings.HasPrefix(pkgName, "github.com/dropbox")
}

func (g *ConfigGenerator) createDeps(
	pkg *build.Package,
	pkgs []string) []string {
	deps := []string{}

	for _, dep := range pkgs {
		if g.isBuiltinPkg(dep) {
			continue
		}
		// Can include self in tests if the tests uses _test as package suffix.
		if dep == pkg.ImportPath {
			continue
		}

		deps = append(deps, "//"+g.goSrc+"/"+dep)
	}

	return deps
}

// Parse the BUILD.in file in a workspace path and return top-level variable
// assignments as a table of identifier name to string or list of strings.
func (g *ConfigGenerator) readAssignmentsFromBuildIN(workspacePkgPath string) (map[string]interface{}, error) {
	config := make(map[string]interface{})

	buildConfigPath := filepath.Join(workspacePkgPath, "BUILD.in")
	buildContent, err := ioutil.ReadFile(buildConfigPath)
	if err != nil {
		return config, err
	}

	file, err := bazelbuild.ParseBuild(buildConfigPath, buildContent)
	if err != nil {
		return config, err
	}

	for _, stmt := range file.Stmt {
		if assignExpr, ok := stmt.(*bazelbuild.AssignExpr); ok {
			if assignExpr.Op == "=" {
				if lhs, ok := assignExpr.LHS.(*bazelbuild.Ident); ok {
					config[lhs.Name] = nil
					switch rhs := assignExpr.RHS.(type) {
					case *bazelbuild.StringExpr:
						config[lhs.Name] = rhs.Value
					case *bazelbuild.ListExpr:
						config[lhs.Name] = bazelbuild.Strings(rhs)
					}
				}
			}
		}
	}
	return config, nil
}

func (g *ConfigGenerator) generateConfig(pkg *build.Package) error {
	if g.verbose {
		fmt.Println("Generating config for", pkg.Dir)
	}

	buffer := &bytes.Buffer{}
	_, _ = buffer.WriteString(buildHeaderTmpl)

	writeTarget := func(
		rule string,
		name string,
		pkgPath string,
		srcs []string,
		deps []string,
		cgoSrcs []string,
		cgoIncludeFlags []string,
		cgoLinkerFlags []string,
		cgoCXXFlags []string) {

		if len(srcs) == 0 &&
			len(deps) == 0 &&
			len(cgoSrcs) == 0 {

			// bazel freaks out when the go build rule doesn't have any input
			return
		}

		_, _ = buffer.WriteString(rule + "(\n")
		_, _ = buffer.WriteString("  name = '" + name + "',\n")

		_, _ = buffer.WriteString("  srcs = [\n")
		for _, src := range srcs {
			_, _ = buffer.WriteString("    '" + src + "',\n")
		}
		_, _ = buffer.WriteString("  ],\n")

		if len(cgoSrcs) > 0 {
			_, _ = buffer.WriteString("  cgo_srcs = [\n")
			for _, src := range cgoSrcs {
				_, _ = buffer.WriteString("    '" + src + "',\n")
			}
			_, _ = buffer.WriteString("  ],\n")
		}

		if len(cgoLinkerFlags) > 0 {
			_, _ = buffer.WriteString("  cgo_linkerflags = [\n")
			for _, linkerFlag := range cgoLinkerFlags {
				_, _ = buffer.WriteString("    '" + linkerFlag + "',\n")
			}
			_, _ = buffer.WriteString("  ],\n")
		}

		if len(cgoCXXFlags) > 0 {
			_, _ = buffer.WriteString("  cgo_cxxflags = [\n")
			for _, cXXFlag := range cgoCXXFlags {
				_, _ = buffer.WriteString("    '" + cXXFlag + "',\n")
			}
			_, _ = buffer.WriteString("  ],\n")
		}

		if len(cgoIncludeFlags) > 0 {
			_, _ = buffer.WriteString("  cgo_includeflags = [\n")
			for _, includeFlag := range cgoIncludeFlags {
				_, _ = buffer.WriteString("    '" + includeFlag + "',\n")
			}
			_, _ = buffer.WriteString("  ],\n")
		}

		_, _ = buffer.WriteString("  deps = [\n")
		for _, dep := range deps {
			_, _ = buffer.WriteString("    '" + dep + "',\n")
		}
		_, _ = buffer.WriteString("  ],\n")

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
					"    '//go/src/dropbox:__subpackages__',\n")

				if pkgPath == "dropbox/proto/mysql" {
					// The internal dropbox/proto/mysql definitions is a
					// superset of the open sourced definitions.
					_, _ = buffer.WriteString(
						"    '//go/src/godropbox/database/binlog:__subpackages__',\n")
				}

				_, _ = buffer.WriteString("  ],\n")
			} else {
				// 3rd party packages are public to go code.
				_, _ = buffer.WriteString("  visibility=[\n")
				_, _ = buffer.WriteString("    '//go/src:__subpackages__',\n")
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

	// write lib/bin target

	srcs := []string{}
	srcs = append(srcs, pkg.GoFiles...)

	cgoSrcs := []string{}
	cgoSrcs = append(cgoSrcs, pkg.CgoFiles...)

	if g.isDbxPkg(pkg.ImportPath) && len(pkg.XTestGoFiles) > 0 {
		fmt.Printf("WARNING: Ignoring following test files which are not in source package '%s': %v\n", pkg.ImportPath, pkg.XTestGoFiles)
	}

	cgoSrcs = append(cgoSrcs, pkg.CFiles...)
	cgoSrcs = append(cgoSrcs, pkg.CXXFiles...)
	// srcs = append(srcs, pkg.MFiles...)
	cgoSrcs = append(cgoSrcs, pkg.HFiles...)
	cgoSrcs = append(cgoSrcs, pkg.SFiles...)
	// srcs = append(srcs, pkg.SwigFiles...)
	// srcs = append(srcs, pkg.SwigCXXFiles...)
	srcs = append(srcs, pkg.SysoFiles...)

	cgoIncludeFlags := []string{}
	cgoLinkerFlags := []string{}
	cgoCXXFlags := []string{}
	deps := g.createDeps(pkg, pkg.Imports)

	if len(pkg.CgoFiles) != 0 {
		for _, cflag := range pkg.CgoCFLAGS {
			if !strings.HasPrefix(cflag, "-I") {
				cgoIncludeFlags = append(cgoIncludeFlags, cflag)
			}
		}

		for _, cxx_flag := range pkg.CgoCXXFLAGS {
			cgoCXXFlags = append(cgoCXXFlags, cxx_flag)
		}

		// Prevent duplicate expansions - generally order matters and you can't dedup LDFLAGS.
		uniqueSpecialLd := make(map[string]struct{})
		for _, ldflag := range pkg.CgoLDFLAGS {
			if strings.HasPrefix(ldflag, "-l") {
				ldflag = strings.TrimPrefix(ldflag, "-l")
				// Check if we know what to do with the module
				if str, ok := linkerMp[ldflag]; ok {
					if _, ok := uniqueSpecialLd[ldflag]; ok {
						continue
					} else {
						uniqueSpecialLd[ldflag] = struct{}{}
					}
					cgoLinkerFlags = append(cgoLinkerFlags, str.LibFlags...)
					deps = append(deps, str.Deps...)
					continue
				}

				// Check against whitelist of modules
				found := false
				for _, whitelistedModule := range whitelistedLinkerModules {
					if ldflag == whitelistedModule {
						found = true
					}
				}
				if found {
					// Add to list of linkerflags
					cgoLinkerFlags = append(cgoLinkerFlags, fmt.Sprintf("-l%s", ldflag))
				} else {
					return fmt.Errorf(
						"Attempting to link against non-whitelisted module: %s", ldflag)
				}
			} else if strings.HasPrefix(ldflag, "-L") {
				// Ignore any -L flags
			} else if strings.HasPrefix(ldflag, "-W") {
				cgoLinkerFlags = append(cgoLinkerFlags, ldflag)
			} else {
				return fmt.Errorf(
					"LDFlag does not begin with one of the following: '-l', '-L', '-W': %s", ldflag)
			}
		}
	}

	srcs = uniqSort(srcs)
	cgoSrcs = uniqSort(cgoSrcs)

	deps = uniqSort(deps)

	name := filepath.Base(pkg.Dir)

	rule := "dbx_go_library"
	if pkg.Name == "main" {
		rule = "dbx_go_binary"
	}
	writeTarget(
		rule,
		name,
		pkg.ImportPath,
		srcs,
		deps,
		cgoSrcs,
		cgoIncludeFlags,
		cgoLinkerFlags,
		cgoCXXFlags)

	// write test target
	if len(pkg.TestGoFiles) > 0 && g.isDbxPkg(pkg.ImportPath) {
		// NOTE: pkg.XTestGoFiles / pkg.XTestImports are not included.  X stands
		// for "external".  Including these will cause dependency cycles.
		srcs = append(srcs, pkg.TestGoFiles...)
		srcs = uniqSort(srcs)

		deps = append(deps, g.createDeps(pkg, pkg.TestImports)...)
		deps = uniqSort(deps)

		_, _ = buffer.WriteString("\n")
		writeTarget(
			"dbx_go_test",
			name+"_test",
			pkg.ImportPath,
			srcs,
			deps,
			cgoSrcs,
			cgoIncludeFlags,
			cgoLinkerFlags,
			cgoCXXFlags)
	}

	buildConfigPath := filepath.Join(pkg.Dir, *buildFilename)
	if g.dryRun {
		fmt.Println("(dry run) Writing", buildConfigPath)
		fmt.Println(buffer.String())
	} else {
		fmt.Println("Writing", buildConfigPath)

		file, err := os.OpenFile(
			buildConfigPath,
			os.O_CREATE|os.O_WRONLY|os.O_TRUNC,
			0644)
		if err != nil {
			return errors.New("Cannot write " + buildConfigPath + ": " + err.Error())
		}
		defer func() { _ = file.Close() }()

		_, _ = file.WriteString(buffer.String())
	}

	return nil
}

func (g *ConfigGenerator) Process(goPkgPath string) error {
	err := g.process(goPkgPath)
	if err != nil {
		return errors.New("Failed to process " + goPkgPath + ": " + err.Error())
	}

	return nil
}

func (g *ConfigGenerator) process(goPkgPath string) error {
	if g.verbose {
		fmt.Println("Process pkg \"" + goPkgPath + "\"")
	}
	if g.isBuiltinPkg(goPkgPath) {
		if g.verbose {
			fmt.Println("Skipping builtin pkg \"" + goPkgPath + "\"")
		}
		return nil
	}

	if _, ok := g.processedPkgs[goPkgPath]; ok {
		if g.verbose {
			fmt.Printf("Skipping previously processed pkg: %s\n", goPkgPath)
		}
		return nil
	}

	for i, path := range g.visitStack {
		if path == goPkgPath {
			if g.verbose {
				cycle := ""
				for _, path := range g.visitStack[i:] {
					cycle += path + " -> "
				}

				cycle += goPkgPath

				fmt.Println("Cycle detected:", cycle)
			}

			// NOTE: A directory may have multiple bazel targets.  The
			// directory's dependency set is the union of all of its bazel
			// targets' dependencies.  When we consider the targets
			// individually, there may not be any cycle in the dependency
			// graph.  However, when we treat mutliple targets as a single
			// unit, unintentional cycle may form.
			//
			// Return nil here to ensure we process each directory at most once.
			return nil
		}
	}

	g.visitStack = append(g.visitStack, goPkgPath)
	defer func() { g.visitStack = g.visitStack[:len(g.visitStack)-1] }()

	workspacePkgPath := filepath.Join(g.workspace, g.goSrc, goPkgPath)
	config, err := g.readAssignmentsFromBuildIN(workspacePkgPath)
	if err != nil && !os.IsNotExist(err) {
		return err
	}

	buildContext := build.Default
	if config["build_tags"] != nil {
		if !isWhitelistedForBuildTags(goPkgPath) {
			return fmt.Errorf("You must add %s to whitelistForBuildTags in gen-build-go.go to enable build_tags.", goPkgPath)
		}
		buildContext.BuildTags = config["build_tags"].([]string)
	}

	pkg, err := buildContext.ImportDir(
		workspacePkgPath,
		build.ImportComment&build.IgnoreVendor)

	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		if _, ok := err.(*build.NoGoError); ok {
			// Directory exists, but does not include go sources.
			return nil
		}
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

	genErr := g.generateConfig(pkg)
	if genErr != nil {
		return genErr
	}

	g.processedPkgs[goPkgPath] = struct{}{}
	return nil
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

var buildFilename = flag.String(
	"build-filename",
	"BUILD",
	"The name of the build file to write.")

func main() {
	flag.Usage = usage
	dryRun := flag.Bool("dry-run", false, "dry run - just echo BUILD files")
	verbose := flag.Bool("verbose", false, "show more detail during analysis")
	skipDepsGeneration := flag.Bool(
		"skip-deps-generation",
		false,
		"When true, only generate BUILD files for the specified packages")
	flag.Parse()
	log.SetFlags(0)

	cwd, err := os.Getwd()
	if err != nil {
		log.Fatal("Unable to get cwd:", err)
	}
	workspace, err := findWorkspace(cwd)
	if err != nil {
		log.Fatal("Unable to find workspace:", err)
	}

	// Force GOPATH to be defined by the workspace.
	build.Default.GOPATH = path.Join(workspace, "go")

	packages := flag.Args()
	if len(packages) == 0 {
		log.Fatal("No package specified")
	}

	var onlyGenPkgs map[string]struct{} = nil
	if *skipDepsGeneration {
		onlyGenPkgs = make(map[string]struct{})
		for _, pkg := range packages {
			onlyGenPkgs[pkg] = struct{}{}
		}
	}

	generator := &ConfigGenerator{
		dryRun:        *dryRun,
		verbose:       *verbose,
		onlyGenPkgs:   onlyGenPkgs,
		workspace:     workspace,
		goSrc:         "go/src",
		golangPkgs:    make(map[string]struct{}),
		processedPkgs: make(map[string]struct{}),
	}

	var lastErr error
	for _, pkg := range packages {
		if err := generator.Process(pkg); err != nil {
			lastErr = err
		}
	}

	if lastErr != nil {
		log.Fatal("Failed to create all configs:", lastErr)
	}
}
