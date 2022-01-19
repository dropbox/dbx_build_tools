// Generate a Bazel BUILD file from a list of packages.
// Invoke this exactly as "go build"
package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"go/build"
	"io"
	"io/ioutil"
	"log"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/mod/modfile"
	"golang.org/x/mod/module"

	buildlib "dropbox/build_tools/genbuildgolib"
)

const (
	buildHeaderTmpl = `load('@rServer//build_tools/go:go.bzl', 'dbx_go_binary', 'dbx_go_library', 'dbx_go_test')

`
)

func depGenParseDepPathsFromGoModFile(pkg string) []string {
	dependencies, err := depGenFindGoModDeps(pkg)
	if err != nil {
		return nil
	}
	depPaths := make([]string, len(dependencies))
	for i, dependency := range dependencies {
		depPaths[i] = dependency.Path
	}
	return depPaths
}

func depGenFindGoModDeps(rootPath string) ([]module.Version, error) {
	mfPath := filepath.Join(rootPath, "go.mod")
	modData, err := ioutil.ReadFile(mfPath)
	if err != nil {
		return nil, err
	}
	mf, err := modfile.Parse(mfPath, modData, nil)
	if err != nil {
		return nil, err
	}
	reqs := make([]module.Version, 0, len(mf.Require))
	for _, r := range mf.Require {
		reqs = append(reqs, r.Mod)
	}
	return reqs, nil
}

type DepConfigGenerator struct {
	dryRun  bool
	verbose bool

	onlyGenPkgs map[string]struct{}

	workspace  string
	goSrc      string
	moduleName string
	repoRoot   string

	golangPkgs    map[string]struct{}
	processedPkgs map[string]struct{}

	visitStack []string // for detecting cycles
}

func (g *DepConfigGenerator) isBuiltinPkg(pkgName string) bool {
	result, hasResult := buildlib.IsBuiltinPkg(pkgName, g.golangPkgs, g.verbose)
	if hasResult {
		return result
	}

	g.golangPkgs[pkgName] = struct{}{}
	return true
}

func (g *DepConfigGenerator) createDeps(
	pkg *build.Package,
	pkgs []string,
	gomodDepPaths []string) []string {
	deps := []string{}
	for _, dep := range pkgs {
		if g.isBuiltinPkg(dep) {
			continue
		}

		depIsInGoMod := false
		if gomodDepPaths != nil {
			for _, importPath := range gomodDepPaths {
				if strings.HasPrefix(dep, importPath) {
					if dep == importPath {
						depName := pathToExtRepoName(importPath)
						deps = append(deps, "@"+depName+"//:"+depName)
						depIsInGoMod = true
					} else {
						relativePath, err := filepath.Rel(importPath, dep)
						if err != nil {
							break
						}
						repoName := pathToExtRepoName(importPath)
						depName := pathToExtRepoName(dep)
						deps = append(deps, "@"+repoName+"//"+relativePath+":"+depName)
						depIsInGoMod = true
					}
					break
				}
			}
			if depIsInGoMod == true {
				continue
			}
		}
		depName := pathToExtRepoName(dep)
		deps = append(deps, "@"+depName+"//:"+depName)
	}
	return deps
}

func (g *DepConfigGenerator) generateConfig(pkg *build.Package) error {
	if g.verbose {
		fmt.Println("Generating config for", pkg.Dir)
	}

	buffer := &bytes.Buffer{}
	_, _ = buffer.WriteString(buildHeaderTmpl)

	srcs, cgoSrcs := buildlib.InitializeSrcsAndCGOSrcs(pkg)

	cgoIncludeFlags := []string{}
	cgoLinkerFlags := []string{}
	cgoCXXFlags := []string{}

	gomodDepPaths := []string{}
	if rootRelPath, err := filepath.Rel(g.moduleName, g.repoRoot); err == nil {
		gomodDepPaths = depGenParseDepPathsFromGoModFile(rootRelPath)
	}
	gomodDepPaths = append(gomodDepPaths, g.repoRoot)
	deps := g.createDeps(pkg, pkg.Imports, gomodDepPaths)

	cgoIncludeFlags,
		cgoCXXFlags,
		cgoLinkerFlags,
		deps,
		srcs,
		cgoSrcs, err := buildlib.PopulateSrcsAndDeps(pkg, cgoIncludeFlags,
		cgoCXXFlags,
		cgoLinkerFlags,
		deps,
		srcs,
		cgoSrcs)
	if err != nil {
		return err
	}

	name := pathToExtRepoName(g.moduleName)

	var targetBuildPath string
	targetBuildPath = ""
	rule := "dbx_go_library"
	if pkg.Name == "main" {
		rule = "dbx_go_binary"
	}
	depGenWriteTarget(
		buffer,
		rule,
		name,
		pkg.ImportPath,
		srcs,
		deps,
		cgoSrcs,
		cgoIncludeFlags,
		cgoLinkerFlags,
		cgoCXXFlags,
		targetBuildPath,
		g.moduleName,
	)

	return buildlib.WriteToBuildConfigFile(g.dryRun, pkg, *depBuildFileName, buffer)
}

func (g *DepConfigGenerator) Process(goPkgPath string) error {
	err := g.process(goPkgPath)
	if err != nil {
		return errors.New("Failed to process " + goPkgPath + ": " + err.Error())
	}

	return nil
}

func (g *DepConfigGenerator) process(goPkgPath string) error {
	pkg, err := buildlib.PopulatePackageInfo(
		goPkgPath,
		g.workspace,
		g.goSrc,
		g.verbose,
		g.isBuiltinPkg(goPkgPath),
		g.processedPkgs,
		g.visitStack)
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

	genErr := g.generateConfig(pkg)
	if genErr != nil {
		return genErr
	}

	g.processedPkgs[goPkgPath] = struct{}{}
	return nil
}

func depGenWriteTarget(
	buffer io.StringWriter,
	rule string,
	name string,
	pkgPath string,
	srcs []string,
	deps []string,
	cgoSrcs []string,
	cgoIncludeFlags []string,
	cgoLinkerFlags []string,
	cgoCXXFlags []string,
	targetBuildPath string,
	moduleName string,
) {
	if len(srcs) == 0 &&
		len(deps) == 0 &&
		len(cgoSrcs) == 0 {

		// bazel freaks out when the go build rule doesn't have any input
		return
	}

	buildlib.WriteCommonBuildAttrToTarget(
		buffer,
		rule,
		name,
		srcs,
		deps,
		cgoSrcs,
		cgoIncludeFlags,
		cgoLinkerFlags,
		cgoCXXFlags,
		moduleName)

	// NOTE: external dep need to be public
	_, _ = buffer.WriteString("  visibility=[\n")
	_, _ = buffer.WriteString("    '//visibility:public',\n")
	_, _ = buffer.WriteString("  ]\n")
	_, _ = buffer.WriteString(")\n")
}

// pathToExtRepoName converts the url of the 3rd party repo
// to an underscore connected name, we use it to name the
// the downloaded repo in our bazel cache
// eg: "github.com/mattn/rune-width" -> "com_github_mattn_rune_width"
func pathToExtRepoName(repoPath string) string {
	urlSegments := strings.Split(repoPath, "/")
	siteString := strings.Split(urlSegments[0], ".")
	result := ""
	for i := len(siteString) - 1; i >= 0; i-- {
		result += siteString[i] + "_"
	}
	for i := 1; i < len(urlSegments); i++ {
		result += urlSegments[i] + "_"
	}
	result = strings.TrimSuffix(result, "_")
	result = strings.ReplaceAll(result, ".", "_")
	result = strings.ReplaceAll(result, " ", "_")
	result = strings.ReplaceAll(result, "-", "_")
	return result
}

func depGenUsage() {
	fmt.Fprintf(os.Stderr, "Usage of %s:\n", os.Args[0])
	flag.PrintDefaults()
	fmt.Fprintf(os.Stderr, `
Examples:

Generate a BUILD file in current external go dependency directory:

  gen-build-go


`)
}

var depBuildFileName = flag.String(
	"build-filename",
	"BUILD",
	"The name of the build file to write.")

var moduleName = flag.String(
	"module-name",
	"",
	"the name or import path of the module",
)

var repoRoot = flag.String(
	"repo-root",
	"",
	"root of the repo, it's either the same as module name or a prefix of it",
)

func main() {
	flag.Usage = depGenUsage
	dryRun := flag.Bool("dry-run", false, "dry run - just echo BUILD files")
	verbose := flag.Bool("verbose", false, "show more detail during analysis")
	skipDepsGeneration := flag.Bool(
		"skip-deps-generation",
		false,
		"When true, only generate BUILD files for the specified packages")
	flag.Parse()
	log.SetFlags(0)
	if *repoRoot == "" {
		repoRoot = moduleName
	}

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

	generator := &DepConfigGenerator{
		dryRun:        *dryRun,
		verbose:       *verbose,
		onlyGenPkgs:   onlyGenPkgs,
		goSrc:         "",
		golangPkgs:    make(map[string]struct{}),
		processedPkgs: make(map[string]struct{}),
		moduleName:    *moduleName,
		repoRoot:      *repoRoot,
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