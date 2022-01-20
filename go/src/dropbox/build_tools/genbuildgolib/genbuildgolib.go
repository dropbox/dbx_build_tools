package genbuildgolib

import (
	"sort"
	"strings"
)

var LinkerMp = map[string]struct {
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

var WhitelistedLinkerModules = []string{"m", "rt", "util", "dl", "tensorflow", "tensorflow_framework"}

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
