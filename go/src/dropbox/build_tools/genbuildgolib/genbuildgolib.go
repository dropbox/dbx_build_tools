package genbuildgolib

import (
	"bytes"
	"errors"
	"fmt"
	"go/build"
	"io"
	"io/ioutil"
	"os"
	"path/filepath"
	"sort"
	"strings"

	bazelbuild "github.com/bazelbuild/buildtools/build"
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

var whitelistedLinkerModules = []string{"m", "rt", "util", "dl", "tensorflow", "tensorflow_framework"}

// whitelistForBuildTags Paths within //go/src/... which permit build_tags in BUILD.in.
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

type TargetList []string

func (s TargetList) Len() int {
	return len(s)
}

func (s TargetList) Swap(i int, j int) {
	s[i], s[j] = s[j], s[i]
}

func (s TargetList) Less(i int, j int) bool {
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

func (s TargetList) priority(target string) int {
	if strings.HasPrefix(target, "//") {
		return 3
	}
	if strings.HasPrefix(target, ":") {
		return 2
	}
	return 1
}

func UniqSort(items []string) []string {
	keys := make(map[string]struct{})
	deduped := make(TargetList, 0, len(items))

	for _, item := range items {
		if _, ok := keys[item]; ok {
			continue
		}

		keys[item] = struct{}{}
		deduped = append(deduped, item)
	}

	sort.Sort(deduped)

	return deduped
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

// PopulateBuildAttributes Populates BUILD file attributes
// like srcs, cgoSrcs, deps, and some flags
func PopulateBuildAttributes(
	pkg *build.Package,
	deps []string,
) ([]string, []string, []string, []string, []string, []string, string, error) {
	// write lib/bin target
	srcs := []string{}
	srcs = append(srcs, pkg.GoFiles...)

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
	deps = UniqSort(deps)
	name := filepath.Base(pkg.Dir)

	return cgoIncludeFlags,
		cgoCXXFlags,
		cgoLinkerFlags,
		deps,
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
func WriteCommonBuildAttrToTarget(
	buffer io.StringWriter,
	rule string,
	name string,
	srcs []string,
	deps []string,
	cgoSrcs []string,
	cgoIncludeFlags []string,
	cgoLinkerFlags []string,
	cgoCXXFlags []string,
	moduleName string,
) {
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

	if moduleName != "" {
		_, _ = buffer.WriteString("  module_name = '" + moduleName + "',\n")
	}

	_, _ = buffer.WriteString("  deps = [\n")
	for _, dep := range deps {
		_, _ = buffer.WriteString("    '" + dep + "',\n")
	}
	_, _ = buffer.WriteString("  ],\n")
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
	goPkgPath string,
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

func PopulatePackageInfo(workspace, goSrc, goPkgPath string) (*build.Package, error) {
	workspacePkgPath := filepath.Join(workspace, goSrc, goPkgPath)
	config, err := readAssignmentsFromBuildIN(workspacePkgPath)
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}

	buildContext := build.Default
	if config["build_tags"] != nil {
		if !isWhitelistedForBuildTags(goPkgPath) {
			return nil, fmt.Errorf("You must add %s to whitelistForBuildTags in genbuildgolib.go to enable build_tags.", goPkgPath)
		}
		buildContext.BuildTags = config["build_tags"].([]string)
	}

	pkg, err := buildContext.ImportDir(
		workspacePkgPath,
		build.ImportComment&build.IgnoreVendor)

	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		if _, ok := err.(*build.NoGoError); ok {
			// Directory exists, but does not include go sources.
			return nil, nil
		}
		return nil, err
	}
	return pkg, nil
}
