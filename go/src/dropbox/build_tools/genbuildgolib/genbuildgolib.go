package genbuildgolib

import (
	"bytes"
	"errors"
	"fmt"
	"go/build"
	"io"
	"io/ioutil"
	"os"
	"path"
	"path/filepath"
	"strings"

	bazelbuild "github.com/bazelbuild/buildtools/build"
	"golang.org/x/mod/modfile"
	"golang.org/x/mod/module"
)

const (
	suffixGoTest = "_test"
)

type GenBuildConfig struct {
	// Linker configuration, primarily for cgo.
	LinkerInfo map[string]struct {
		Deps     []string `json:"deps"`
		LibFlags []string `json:"lib_flags"`
	} `json:"linkerInfo"`
	// Modules allowed for linking.
	AllowedLinkerModules []string `json:"allowed_linker_modules"`
	// Paths within //go/src/... which permit build_tags in BUILD.in.
	AllowedForBuildTags []string `json:"allowed_for_build_tags"`
	// List of Go release tags, like 1.19.
	ReleaseTags []string `json:"release_tags"`
}

func isWhitelistedForBuildTags(goPkgPath string, config *GenBuildConfig) bool {
	for _, whitelistPrefix := range config.AllowedForBuildTags {
		if strings.HasPrefix(goPkgPath, whitelistPrefix) {
			return true
		}
	}
	return false
}

// readAssignmentsFromBuildIN Parse the BUILD.in file in a workspace
// path and return top-level variable assignments as a table of
// identifier name to string or list of strings.
func readAssignmentsFromBuildIN(workspacePkgPath string) (map[string]interface{}, error) {
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

func getBinaryRuleName(pkg *build.Package, moduleName string) (string, error) {
	if moduleName == "" {
		moduleName = pkg.Dir
	}
	modFilePath := path.Join(pkg.Dir, "go.mod")
	modFileContent, err := ioutil.ReadFile(modFilePath)
	if err != nil {
		if os.IsNotExist(err) {
			return filepath.Base(moduleName), nil
		}
		return "", err
	}

	mod, err := modfile.ParseLax(modFilePath, modFileContent, nil)
	if err != nil {
		return "", err
	}

	modulePath := mod.Module.Mod.Path
	prefix, _, ok := module.SplitPathVersion(modulePath)
	if !ok {
		return filepath.Base(modulePath), nil
	}

	return filepath.Base(prefix), nil
}

func getRuleName(pkg *build.Package, moduleName string) (string, error) {
	if pkg.Name != "main" {
		return filepath.Base(pkg.Dir), nil
	}

	name, err := getBinaryRuleName(pkg, moduleName)
	if err != nil {
		return "", err
	}

	if _, err = os.Stat(path.Join(pkg.Dir, name)); err != nil {
		if os.IsNotExist(err) {
			return name, nil
		}
		return "", err
	}

	return name + "-bin", nil
}

// PopulateBuildAttributes Populates BUILD file attributes
// like srcs, cgoSrcs, cgoDeps, and some flags
func PopulateBuildAttributes(
	pkg *build.Package,
	moduleName string,
	config *GenBuildConfig,
) ([]string, []string, []string, []string, []string, []string, string, error) {
	// write lib/bin target
	srcs := []string{}
	srcs = append(srcs, pkg.GoFiles...)

	cgoDeps := []string{}

	cgoSrcs := []string{}
	cgoSrcs = append(cgoSrcs, pkg.CgoFiles...)

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
				if str, ok := config.LinkerInfo[ldflag]; ok {
					if _, ok := uniqueSpecialLd[ldflag]; ok {
						continue
					} else {
						uniqueSpecialLd[ldflag] = struct{}{}
					}
					cgoLinkerFlags = append(cgoLinkerFlags, str.LibFlags...)
					cgoDeps = append(cgoDeps, str.Deps...)
					continue
				}

				// Check against whitelist of modules
				found := false
				for _, whitelistedModule := range config.AllowedLinkerModules {
					if ldflag == whitelistedModule {
						found = true
					}
				}
				if found {
					// Add to list of linkerflags
					cgoLinkerFlags = append(cgoLinkerFlags, fmt.Sprintf("-l%s", ldflag))
				} else {
					return nil, nil, nil, nil, nil, nil, "", fmt.Errorf(
						"Attempting to link against non-whitelisted module: %s", ldflag)
				}
			} else if strings.HasPrefix(ldflag, "-L") {
				// Ignore any -L flags
			} else if strings.HasPrefix(ldflag, "-W") {
				cgoLinkerFlags = append(cgoLinkerFlags, ldflag)
			} else {
				return nil, nil, nil, nil, nil, nil, "", fmt.Errorf(
					"LDFlag does not begin with one of the following: '-l', '-L', '-W': %s", ldflag)
			}
		}
	}

	srcs = UniqSort(srcs)
	cgoSrcs = UniqSort(cgoSrcs)
	cgoDeps = UniqSort(cgoDeps)
	name, err := getRuleName(pkg, moduleName)
	if err != nil {
		return nil, nil, nil, nil, nil, nil, "", err
	}

	return cgoIncludeFlags,
		cgoCXXFlags,
		cgoLinkerFlags,
		cgoDeps,
		srcs,
		cgoSrcs,
		name,
		nil
}

func WriteToBuildConfigFile(isDryRun bool, pkg *build.Package, buildFilename string, buffer *bytes.Buffer) error {
	buildConfigPath := filepath.Join(pkg.Dir, buildFilename)
	if isDryRun {
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

// WriteCommonBuildAttrToTarget writes some of the common BUILD file
// attributes to the buffer. Including name, srcs, deps, module_name,
// etc.
// TODO: Refactor this to make it easier to extend with new parameters
func WriteCommonBuildAttrToTarget(
	buffer io.StringWriter,
	rule string,
	name string,
	srcs []string,
	deps []string,
	cgoSrcs []string,
	cgoDeps []string,
	cgoIncludeFlags []string,
	cgoLinkerFlags []string,
	cgoCXXFlags []string,
	moduleName string,
	tm TagMap,
	ecw EmbedConfigWrapper,
) {
	_, _ = buffer.WriteString(rule + "(\n")
	_, _ = buffer.WriteString("  name = '" + name + "',\n")

	WriteListToBuild("srcs", srcs, buffer, true)
	// Optional attributes, will not be written if slices are empty
	WriteListToBuild("cdeps", cgoDeps, buffer, false)
	WriteListToBuild("cgo_srcs", cgoSrcs, buffer, false)
	WriteListToBuild("cgo_linkerflags", cgoLinkerFlags, buffer, false)
	WriteListToBuild("cgo_cxxflags", cgoCXXFlags, buffer, false)
	WriteListToBuild("cgo_includeflags", cgoIncludeFlags, buffer, false)

	if moduleName != "" {
		_, _ = buffer.WriteString("  module_name = '" + moduleName + "',\n")
	}

	WriteListToBuild("deps", deps, buffer, true)

	// Tagmaps for go build tags: https://pkg.go.dev/cmd/go#hdr-Build_constraints
	if len(tm) > 0 {
		keepEntries(tm, srcs) // Drop any tags for files that aren't in "srcs"

		WriteTagMap(tm, buffer)
	}

	// For go:embed directives: https://pkg.go.dev/embed
	ecw.WriteToBUILD(name, buffer)
}

// IsBuiltinPkg checks if the package is a built in go package,
// which doesn't need to be listed as a dependency. It returns
// two booleans, the first one indicates whether this function
// has a definitive answer to "is builtin package", the second
// is the answer.
func IsBuiltinPkg(pkgName string, golangPkgs *map[string]struct{}, isVerbose bool) bool {
	if pkgName == "C" { // c binding
		return true
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

	if _, ok := (*golangPkgs)[pkgName]; ok {
		return ok
	}

	_, err := build.Default.ImportDir(
		filepath.Join(build.Default.GOROOT, "src", pkgName),
		build.ImportComment&build.IgnoreVendor)

	if err != nil {
		if isVerbose {
			fmt.Printf("Can't find builtin pkg: %s %s\n", pkgName, filepath.Join(build.Default.GOROOT, "src", pkgName))
		}
		return false
	}

	(*golangPkgs)[pkgName] = struct{}{}
	return true
}

func ValidateGoPkgPath(
	isVerbose,
	isBuiltinPkg bool,
	goPkgPath, workspace, goSrc string,
	processedPkgs map[string]struct{},
	visitStack *[]string,
) bool {
	if isVerbose {
		fmt.Println("Process pkg \"" + goPkgPath + "\"")
	}

	if isBuiltinPkg {
		if isVerbose {
			fmt.Println("Skipping builtin pkg \"" + goPkgPath + "\"")
		}
		return false
	}

	if _, ok := processedPkgs[goPkgPath]; ok {
		if isVerbose {
			fmt.Printf("Skipping previously processed pkg: %s\n", goPkgPath)
		}
		return false
	}

	workspacePkgPath := filepath.Join(workspace, goSrc, goPkgPath)
	if _, err := os.Stat(workspacePkgPath); err != nil {
		fmt.Println(workspacePkgPath, " does not exist, skipping.")
		return false
	}

	for i, path := range *visitStack {
		if path == goPkgPath {
			if isVerbose {
				cycle := ""
				for _, path := range (*visitStack)[i:] {
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
			return false
		}
	}

	return true
}

func PopulatePackageInfo(workspace, goSrc, goPkgPath string, buildConfig *GenBuildConfig) (*build.Package, error) {
	workspacePkgPath := filepath.Join(workspace, goSrc, goPkgPath)
	config, err := readAssignmentsFromBuildIN(workspacePkgPath)
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}

	buildContext := build.Default
	if config["build_tags"] != nil {
		if !isWhitelistedForBuildTags(goPkgPath, buildConfig) {
			return nil, fmt.Errorf("You must add %s to whitelistForBuildTags in genbuildgolib.go to enable build_tags.", goPkgPath)
		}
		buildContext.BuildTags = config["build_tags"].([]string)
	}

	goFiles := []string{}
	importDirHelper := func(bc build.Context) (*build.Package, error) {
		pkg, importErr := bc.ImportDir(workspacePkgPath, build.ImportComment&build.IgnoreVendor)
		if importErr != nil {
			if os.IsNotExist(importErr) {
				return nil, nil
			}
			if _, ok := importErr.(*build.NoGoError); ok {
				// Directory exists, but does not include go sources.
				return nil, nil
			}
			return nil, importErr
		}
		goFiles = append(goFiles, pkg.GoFiles...)
		return pkg, nil
	}

	var (
		pkg       *build.Package
		importErr error
	)

	originalReleaseTags := buildContext.ReleaseTags
	// TODO: Do we only care about the last 2 releases? 1.18 and 1.19?
	// Basically our stable language version and the one we want to migrate to? What's a nice way of coding that?
	for i := 1; i >= 0; i-- {
		buildContext.ReleaseTags = originalReleaseTags[:len(originalReleaseTags)-i]
		pkg, importErr = importDirHelper(buildContext)
		if importErr != nil {
			return nil, importErr
		}
		if pkg == nil {
			return nil, nil
		}
	}
	// Replace the final "pkg.GoFiles" with all the GoFiles we found using different release tags
	pkg.GoFiles = UniqSort(goFiles)
	return pkg, nil
}

// PathToExtRepoName converts the url of the 3rd party repo
// to an underscore connected name, we use it to name the
// the downloaded repo in our bazel cache
// eg: "github.com/mattn/rune-width" -> "com_github_mattn_rune_width"
func PathToExtRepoName(repoPath string, majorVersion string) string {
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
	result = strings.ReplaceAll(result, "~", "_")

	if majorVersion != "" {
		result += "_" + majorVersion
	}
	return result
}
