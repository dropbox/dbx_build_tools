package genbuildgolib

import (
	"fmt"
	"go/build"
	"io/ioutil"
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

func IsWhitelistedForBuildTags(goPkgPath string) bool {
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

// ReadAssignmentsFromBuildIN Parse the BUILD.in file in a workspace
// path and return top-level variable assignments as a table of
// identifier name to string or list of strings.
func ReadAssignmentsFromBuildIN(workspacePkgPath string) (map[string]interface{}, error) {
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
