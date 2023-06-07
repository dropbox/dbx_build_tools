load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive", "http_file")
load("@dbx_build_tools//build_tools/go:workspace.bzl", "load_go_build_gen")
load("@dbx_build_tools//build_tools/go:dbx_go_repository.bzl", "dbx_go_dependency")

# Retrieve a filename from given label. This is useful when the target is used in other repos, in
# which case the relative path for filename cannot be found but the label conversion works.
def filename_from_label(label):
    return str(Label(label))

# Please keep sorted.
DEFAULT_EXTERNAL_GO_URLS = {
    "com_github_bazelbuild_buildtools": "https://github.com/bazelbuild/buildtools/archive/e6efbf6df90b.tar.gz",
    "com_github_c9s_goprocinfo": "https://github.com/c9s/goprocinfo/archive/19cb9f127a9c.tar.gz",
    "com_github_chzyer_readline": "https://github.com/chzyer/readline/archive/2972be24d48e.tar.gz",
    "com_github_cncf_xds_go": "https://github.com/cncf/xds/archive/cb28da3451f1.tar.gz",
    "com_github_creack_pty": "https://github.com/creack/pty/archive/refs/tags/v1.1.18.tar.gz",
    "com_github_davecgh_go_spew": "https://github.com/davecgh/go-spew/archive/refs/tags/v1.1.1.tar.gz",
    "com_github_envoyproxy_go_control_plane": "https://github.com/envoyproxy/go-control-plane/archive/49ff273808a1.tar.gz",
    "com_github_golang_protobuf": "https://github.com/golang/protobuf/archive/refs/tags/v1.5.2.tar.gz",
    "com_github_google_go_cmp": "https://github.com/google/go-cmp/archive/b1c9c4891a65.tar.gz",
    "com_github_grpc_ecosystem_grpc_gateway": "https://github.com/grpc-ecosystem/grpc-gateway/archive/v1.16.0.tar.gz",
    "com_github_iancoleman_strcase": "https://github.com/iancoleman/strcase/archive/3605ed457bf7.tar.gz",
    "com_github_kr_pretty": "https://github.com/kr/pretty/archive/refs/tags/v0.3.1.tar.gz",
    "com_github_kr_text": "https://github.com/kr/text/archive/refs/tags/v0.2.0.tar.gz",
    "com_github_pmezard_go_difflib": "https://github.com/pmezard/go-difflib/archive/v1.0.0.tar.gz",
    "com_github_rogpeppe_go_internal": "https://github.com/rogpeppe/go-internal/archive/refs/tags/v1.9.0.tar.gz",
    "com_github_spf13_afero": "https://github.com/spf13/afero/archive/v1.1.2.tar.gz",
    "com_github_stretchr_objx": "https://github.com/stretchr/objx/archive/v0.1.1.tar.gz",
    "com_github_stretchr_testify": "https://github.com/stretchr/testify/archive/refs/tags/v1.8.0.tar.gz",
    "com_github_yuin_goldmark": "https://github.com/yuin/goldmark/archive/v1.4.1.tar.gz",
    "in_gopkg_check_v1": "https://github.com/go-check/check/archive/10cb98267c6cb43ea9cd6793f29ff4089c306974.tar.gz",
    "in_gopkg_yaml_v3": "https://github.com/go-yaml/yaml/archive/v3.0.1.tar.gz",
    "io_opentelemetry_go_proto_otlp": "https://github.com/open-telemetry/opentelemetry-proto-go/archive/refs/tags/v0.19.0.tar.gz",
    "net_starlark_go": "https://github.com/google/starlark-go/archive/1cdb82c9e17a.tar.gz",
    "org_golang_google_genproto": "https://github.com/googleapis/go-genproto/archive/669157292da3.tar.gz",
    "org_golang_google_grpc": "https://github.com/grpc/grpc-go/archive/refs/tags/v1.47.0.tar.gz",
    "org_golang_google_protobuf": "https://github.com/protocolbuffers/protobuf-go/archive/28b807b56e3c.tar.gz",
    "org_golang_x_crypto": "https://github.com/golang/crypto/archive/630584e8d5aa.tar.gz",
    "org_golang_x_mod": "https://github.com/golang/mod/archive/9b9b3d81d5e3.tar.gz",
    "org_golang_x_net": "https://github.com/golang/net/archive/6772e930b67b.tar.gz",
    "org_golang_x_sync": "https://github.com/golang/sync/archive/7fc1605a5dde.tar.gz",
    "org_golang_x_sys": "https://github.com/golang/sys/archive/fbc7d0a398ab.tar.gz",
    "org_golang_x_term": "https://github.com/golang/term/archive/7de9c90e9dd1.tar.gz",
    "org_golang_x_text": "https://github.com/golang/text/archive/48e4a4a95742.tar.gz",
    "org_golang_x_time": "https://github.com/golang/time/archive/8be79e1e0910.tar.gz",
    "org_golang_x_tools": "https://github.com/golang/tools/archive/v0.1.12.tar.gz",
    "org_golang_x_xerrors": "https://github.com/golang/xerrors/archive/5ec99f83aff1.tar.gz",
}

# Please keep sorted.
DEFAULT_EXTERNAL_URLS = {
    "abseil_py": ["https://github.com/abseil/abseil-py/archive/pypi-v0.7.1.tar.gz"],
    "bazel_skylib": ["https://github.com/bazelbuild/bazel-skylib/releases/download/1.4.1/bazel-skylib-1.4.1.tar.gz"],
    "com_github_plougher_squashfs_tools": ["https://github.com/plougher/squashfs-tools/archive/4.5.1.tar.gz"],
    "cpython_310": ["https://www.python.org/ftp/python/3.10.5/Python-3.10.5.tar.xz"],
    "cpython_39": ["https://www.python.org/ftp/python/3.9.14/Python-3.9.14.tar.xz"],
    "ducible": ["https://github.com/jasonwhite/ducible/releases/download/v1.2.2/ducible-windows-Win32-Release.zip"],
    "go_1_18_linux_amd64_tar_gz": ["https://dl.google.com/go/go1.18.10.linux-amd64.tar.gz"],
    "go_1_19_linux_amd64_tar_gz": ["https://dl.google.com/go/go1.19.9.linux-amd64.tar.gz"],
    "io_pypa_pip_whl": ["https://files.pythonhosted.org/packages/ab/43/508c403c38eeaa5fc86516eb13bb470ce77601b6d2bbcdb16e26328d0a15/pip-23.0-py3-none-any.whl"],
    "io_pypa_setuptools_whl": ["https://files.pythonhosted.org/packages/86/7b/f35d72b7a6acbc27732e88d7ceb7f224b3e0683bf645e1c9e2ac2cd96c0d/setuptools-67.3.2-py3-none-any.whl"],
    "io_pypa_wheel_whl": ["https://files.pythonhosted.org/packages/bd/7c/d38a0b30ce22fc26ed7dbc087c6d00851fb3395e9d0dac40bec1f905030c/wheel-0.38.4-py3-none-any.whl"],
    "lz4": ["https://github.com/lz4/lz4/archive/v1.9.3.tar.gz"],
    "mypy": ["https://github.com/python/mypy/archive/3bf9fdc347ff1d27baead7660442d645a77cb2c6.tar.gz"],
    "net_zlib": ["http://zlib.net/zlib-1.2.13.tar.gz"],
    "org_bzip_bzip2": ["https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz"],
    "org_gnu_ncurses": ["https://invisible-mirror.net/archives/ncurses/ncurses-6.2.tar.gz"],
    "org_gnu_readline": ["https://ftp.gnu.org/gnu/readline/readline-8.1.tar.gz"],
    "org_openssl": ["https://www.openssl.org/source/openssl-1.1.1q.tar.gz"],
    "org_sourceware_libffi": ["https://github.com/libffi/libffi/releases/download/v3.3/libffi-3.3.tar.gz"],
    "org_sqlite": ["https://www.sqlite.org/2022/sqlite-amalgamation-3380100.zip"],
    "org_tukaani": ["https://downloads.sourceforge.net/project/lzmautils/xz-5.2.5.tar.xz"],
    "rules_license": ["https://github.com/bazelbuild/rules_license/releases/download/0.0.3/rules_license-0.0.3.tar.gz"],
    "rules_pkg": ["https://github.com/bazelbuild/rules_pkg/releases/download/0.7.1/rules_pkg-0.7.1.tar.gz"],
    "rules_python": ["https://github.com/bazelbuild/rules_python/archive/54d1cb35cd54.tar.gz"],
    "six_archive": ["https://pypi.python.org/packages/b3/b2/238e2590826bfdd113244a40d9d3eb26918bd798fc187e2360a8367068db/six-1.10.0.tar.gz"],
    "zstd": ["https://github.com/facebook/zstd/releases/download/v1.4.9/zstd-1.4.9.tar.gz"],
}

def drte_deps(urls = DEFAULT_EXTERNAL_URLS, go_urls = DEFAULT_EXTERNAL_GO_URLS):
    http_archive(
        name = "go_1_18_linux_amd64_tar_gz",
        urls = urls["go_1_18_linux_amd64_tar_gz"],
        sha256 = "5e05400e4c79ef5394424c0eff5b9141cb782da25f64f79d54c98af0a37f8d49",
        build_file = filename_from_label("//build_tools/go:BUILD.go-dist"),
    )

    http_archive(
        name = "go_1_19_linux_amd64_tar_gz",
        urls = urls["go_1_19_linux_amd64_tar_gz"],
        sha256 = "e858173b489ec1ddbe2374894f52f53e748feed09dde61be5b4b4ba2d73ef34b",
        build_file = filename_from_label("//build_tools/go:BUILD.go-dist"),
    )

    http_archive(
        name = "org_sourceware_libffi",
        urls = urls["org_sourceware_libffi"],
        sha256 = "72fba7922703ddfa7a028d513ac15a85c8d54c8d67f55fa5a4802885dc652056",
        build_file = filename_from_label("@dbx_build_tools//thirdparty/libffi:BUILD.libffi"),
        strip_prefix = "libffi-3.3",
    )

    http_archive(
        name = "org_python_cpython_39",
        urls = urls["cpython_39"],
        sha256 = "651304d216c8203fe0adf1a80af472d8e92c3b0e0a7892222ae4d9f3ae4debcf",
        build_file = filename_from_label("@dbx_build_tools//thirdparty/cpython:BUILD.python39"),
        strip_prefix = "Python-3.9.14",
    )

    http_archive(
        name = "org_python_cpython_310",
        urls = urls["cpython_310"],
        sha256 = "66767a35309d724f370df9e503c172b4ee444f49d62b98bc4eca725123e26c49",
        build_file = filename_from_label("@dbx_build_tools//thirdparty/cpython:BUILD.python310"),
        strip_prefix = "Python-3.10.5",
    )

    http_archive(
        name = "com_github_plougher_squashfs_tools",
        urls = urls["com_github_plougher_squashfs_tools"],
        sha256 = "277b6e7f75a4a57f72191295ae62766a10d627a4f5e5f19eadfbc861378deea7",
        build_file = filename_from_label("@dbx_build_tools//thirdparty/squashfs-tools:BUILD.squashfs-tools"),
        strip_prefix = "squashfs-tools-4.5.1",
    )

    http_archive(
        name = "bazel_skylib",
        urls = urls["bazel_skylib"],
        sha256 = "b8a1527901774180afc798aeb28c4634bdccf19c4d98e7bdd1ce79d1fe9aaad7",
    )

    pypi_core_deps(urls)

    cpython_deps(urls)

    go_core_deps(go_urls)

def cpython_deps(urls = DEFAULT_EXTERNAL_URLS):
    http_archive(
        name = "rules_license",
        urls = urls["rules_license"],
        sha256 = "00ccc0df21312c127ac4b12880ab0f9a26c1cff99442dc6c5a331750360de3c3",
    )

    http_archive(
        name = "rules_pkg",
        urls = urls["rules_pkg"],
        sha256 = "451e08a4d78988c06fa3f9306ec813b836b1d076d0f055595444ba4ff22b867f",
    )

    http_archive(
        name = "rules_python",
        urls = urls["rules_python"],
        sha256 = "30ac7f6fdcc20dd69e7d745fe39ac27f506d005c12a37809ed3ef6f6eab54c5f",
    )

    http_archive(
        name = "abseil_py",
        urls = urls["abseil_py"],
        strip_prefix = "abseil-py-pypi-v0.7.1",
        sha256 = "3d0f39e0920379ff1393de04b573bca3484d82a5f8b939e9e83b20b6106c9bbe",
    )

    http_archive(
        name = "org_gnu_readline",
        urls = urls["org_gnu_readline"],
        sha256 = "f8ceb4ee131e3232226a17f51b164afc46cd0b9e6cef344be87c65962cb82b02",
        build_file = filename_from_label("//thirdparty/readline:BUILD.readline"),
        strip_prefix = "readline-8.1",
    )

    http_archive(
        name = "six_archive",
        build_file = filename_from_label("@abseil_py//third_party:six.BUILD"),
        sha256 = "105f8d68616f8248e24bf0e9372ef04d3cc10104f1980f54d57b2ce73a5ad56a",
        strip_prefix = "six-1.10.0",
        urls = urls["six_archive"],
    )

    http_archive(
        name = "org_gnu_ncurses",
        urls = urls["org_gnu_ncurses"],
        sha256 = "30306e0c76e0f9f1f0de987cf1c82a5c21e1ce6568b9227f7da5b71cbea86c9d",
        build_file = filename_from_label("//thirdparty/ncurses:BUILD.ncurses"),
        strip_prefix = "ncurses-6.2",
    )

    http_archive(
        name = "net_zlib",
        urls = urls["net_zlib"],
        sha256 = "b3a24de97a8fdbc835b9833169501030b8977031bcb54b3b3ac13740f846ab30",
        strip_prefix = "zlib-1.2.13",
        build_file = filename_from_label("@dbx_build_tools//thirdparty/zlib:BUILD.zlib"),
    )

    http_archive(
        name = "org_bzip_bzip2",
        urls = urls["org_bzip_bzip2"],
        sha256 = "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269",
        strip_prefix = "bzip2-1.0.8",
        build_file = filename_from_label("//thirdparty/bzip2:BUILD.bzip2"),
    )

    http_archive(
        name = "org_tukaani",
        urls = urls["org_tukaani"],
        strip_prefix = "xz-5.2.5",
        sha256 = "3e1e518ffc912f86608a8cb35e4bd41ad1aec210df2a47aaa1f95e7f5576ef56",
        build_file = filename_from_label("//thirdparty/xz:BUILD.xz"),
    )

    http_archive(
        name = "org_openssl",
        urls = urls["org_openssl"],
        sha256 = "d7939ce614029cdff0b6c20f0e2e5703158a489a72b2507b8bd51bf8c8fd10ca",
        strip_prefix = "openssl-1.1.1q",
        build_file = filename_from_label("//thirdparty/openssl:BUILD.openssl"),
    )

    http_archive(
        name = "org_sqlite",
        urls = urls["org_sqlite"],
        sha256 = "6fb55507d4517b5cbc80bd2db57b0cbe1b45880b28f2e4bd6dca4cfe3716a231",
        strip_prefix = "sqlite-amalgamation-3380100",
        build_file = filename_from_label("//thirdparty/sqlite:BUILD.sqlite"),
    )

    http_archive(
        name = "lz4",
        urls = urls["lz4"],
        sha256 = "030644df4611007ff7dc962d981f390361e6c97a34e5cbc393ddfbe019ffe2c1",
        strip_prefix = "lz4-1.9.3",
        build_file = filename_from_label("//thirdparty/lz4:BUILD.lz4"),
    )

    http_archive(
        name = "zstd",
        urls = urls["zstd"],
        sha256 = "29ac74e19ea28659017361976240c4b5c5c24db3b89338731a6feb97c038d293",
        strip_prefix = "zstd-1.4.9",
        build_file = filename_from_label("//thirdparty/zstd:BUILD.zstd"),
    )

def pypi_core_deps(urls = DEFAULT_EXTERNAL_URLS):
    """Deps needed by python build rules in //build_tools/py."""
    http_file(
        name = "io_pypa_pip_whl",
        urls = urls["io_pypa_pip_whl"],
        downloaded_file_path = "pip-23.0-py3-none-any.whl",
        sha256 = "b5f88adff801f5ef052bcdef3daa31b55eb67b0fccd6d0106c206fa248e0463c",
    )

    http_file(
        name = "io_pypa_setuptools_whl",
        urls = urls["io_pypa_setuptools_whl"],
        downloaded_file_path = "setuptools-67.3.2-py3-none-any.whl",
        sha256 = "bb6d8e508de562768f2027902929f8523932fcd1fb784e6d573d2cafac995a48",
    )

    http_file(
        name = "io_pypa_wheel_whl",
        urls = urls["io_pypa_wheel_whl"],
        downloaded_file_path = "wheel-0.38.4-py3-none-any.whl",
        sha256 = "b60533f3f5d530e971d6737ca6d58681ee434818fab630c83a734bb10c083ce8",
    )

    # Windows client only package that is required because of rule-sharing.
    http_archive(
        name = "ducible",
        urls = urls["ducible"],
        sha256 = "b90d636b6ee08768cd198e00f007a25b91bc1be279d417bdd3d476296060b7da",
        build_file_content = """exports_files(["ducible.exe"])""",
    )

    # Version is also encoded in //thirdparty/mypy:mypy pip_version attribute, keep in sync.
    http_archive(
        name = "mypy",
        urls = urls["mypy"],
        sha256 = "3819374c92ec5670caae206afe791901b4e8d555a020d6a56b5c8a24f556c133",
        strip_prefix = "mypy-3bf9fdc347ff1d27baead7660442d645a77cb2c6",
        build_file = filename_from_label("//thirdparty/mypy:BUILD.mypy"),
        patches = [filename_from_label("//thirdparty/mypy:version.patch")],
    )

def go_core_deps(urls = DEFAULT_EXTERNAL_GO_URLS):
    dbx_go_dependency(
        name = "com_github_stretchr_testify",
        url = urls["com_github_stretchr_testify"],
        sha256 = "c31f0bc88114cc11a3d1f2e837d2c0aa7b4cd28c7b81e1946d47c158ba3e6841",
        importpath = "github.com/stretchr/testify",
        strip_prefix = "testify-1.8.0",
        patches = [
            "//go/src/github.com/stretchr/testify:dbx-patches/bazel.patch",
        ],
    )

    dbx_go_dependency(
        name = "com_github_iancoleman_strcase",
        url = urls["com_github_iancoleman_strcase"],
        sha256 = "99c3730d10ad1ea807a5e14b13c5419943e18f45a54531663b10598ec7cd7bb9",
        importpath = "github.com/iancoleman/strcase",
        strip_prefix = "strcase-3605ed457bf7f8caa1371b4fafadadc026673479",
    )

    dbx_go_dependency(
        name = "com_github_spf13_afero",
        url = urls["com_github_spf13_afero"],
        sha256 = "66554a6b09b0009340ae77c119d5a14e2460bb3aea56e75e138c87e621f3803b",
        importpath = "github.com/spf13/afero",
        strip_prefix = "afero-1.1.2",
    )

    dbx_go_dependency(
        name = "org_golang_x_tools",
        url = urls["org_golang_x_tools"],
        sha256 = "e15c17adbc82cb0660011ec841fe7d192074611761cd337961ffd9bb085ab20f",
        importpath = "golang.org/x/tools",
        strip_prefix = "tools-0.1.12",
    )

    dbx_go_dependency(
        name = "com_github_c9s_goprocinfo",
        url = urls["com_github_c9s_goprocinfo"],
        sha256 = "3a70bc9eb787e3160617dbc276efa17ed3273c500ba5301398063cd9c05db307",
        importpath = "github.com/c9s/goprocinfo",
        strip_prefix = "goprocinfo-19cb9f127a9c8d2034cf59ccb683cdb94b9deb6c",
    )

    dbx_go_dependency(
        name = "com_github_grpc_ecosystem_grpc_gateway",
        url = urls["com_github_grpc_ecosystem_grpc_gateway"],
        sha256 = "20ba8f2aeb4a580109357fffaa42f8400aba1155b95c8845e412287907e64379",
        importpath = "github.com/grpc-ecosystem/grpc-gateway",
        strip_prefix = "grpc-gateway-1.16.0",
    )

    dbx_go_dependency(
        name = "com_github_chzyer_readline",
        url = urls["com_github_chzyer_readline"],
        sha256 = "c33fa783d7e021bad1c502be6ed7bcb250cfda139a7d883f7cf06efe1cc3df72",
        importpath = "github.com/chzyer/readline",
        strip_prefix = "readline-2972be24d48e78746da79ba8e24e8b488c9880de",
    )

    dbx_go_dependency(
        name = "com_github_cncf_xds_go",
        url = urls["com_github_cncf_xds_go"],
        sha256 = "5bc8365613fe2f8ce6cc33959b7667b13b7fe56cb9d16ba740c06e1a7c4242fc",
        importpath = "github.com/cncf/xds/go",
        strip_prefix = "xds-cb28da3451f158a947dfc45090fe92b07b243bc1/go",
    )

    dbx_go_dependency(
        name = "com_github_envoyproxy_go_control_plane",
        url = urls["com_github_envoyproxy_go_control_plane"],
        sha256 = "e5a97f08fe1bfefc2c18e11ff41f2efa2c3f920331b36515e685a8e7dac2314b",
        importpath = "github.com/envoyproxy/go-control-plane",
        strip_prefix = "go-control-plane-49ff273808a140106ffbcc1af157d8da73cb4514",
    )

    dbx_go_dependency(
        name = "net_starlark_go",
        url = urls["net_starlark_go"],
        sha256 = "e50ce79ac490a8cd3d563db23129a669be98d76053c91782fbe74ff0027151ba",
        importpath = "go.starlark.net",
        strip_prefix = "starlark-go-1cdb82c9e17a3e18b5067713955f174b08776f8b",
    )

    dbx_go_dependency(
        name = "org_golang_x_mod",
        url = urls["org_golang_x_mod"],
        sha256 = "8d77cf7a1e956afd212595bc177f78d68fdd165fe7cbd24e788fd20e94eb90f7",
        importpath = "golang.org/x/mod",
        strip_prefix = "mod-9b9b3d81d5e39b22d65814a8daf6723f3035d813",
    )

    dbx_go_dependency(
        name = "org_golang_x_sync",
        url = urls["org_golang_x_sync"],
        sha256 = "76541d41a4e86f45b22c6b4bccdcc1a36dd13a505ad07c8375d77704490c91ae",
        importpath = "golang.org/x/sync",
        strip_prefix = "sync-7fc1605a5dde7535a0fc1770ca44238629ff29ac",
    )

    dbx_go_dependency(
        name = "org_golang_x_sys",
        url = urls["org_golang_x_sys"],
        sha256 = "8270af25ff1c5f7a32d1a5860840d1957198e546332fc8fede5f023c5d20a984",
        importpath = "golang.org/x/sys",
        strip_prefix = "sys-fbc7d0a398ab184f5d1050e8035f3b19a3b9003f",
    )

    dbx_go_dependency(
        name = "org_golang_google_grpc",
        url = urls["org_golang_google_grpc"],
        sha256 = "36d2cd82d20b9c657d0dc6a7a76a37780f49ddb23952e24af7d28e842f37c07d",
        importpath = "google.golang.org/grpc",
        strip_prefix = "grpc-go-1.47.0",
    )

    dbx_go_dependency(
        name = "com_github_golang_protobuf",
        url = urls["com_github_golang_protobuf"],
        sha256 = "088cc0f3ba18fb8f9d00319568ff0af5a06d8925a6e6cb983bb837b4efb703b3",
        importpath = "github.com/golang/protobuf",
        strip_prefix = "protobuf-1.5.2",
    )

    dbx_go_dependency(
        name = "org_golang_google_protobuf",
        url = urls["org_golang_google_protobuf"],
        sha256 = "c445eb13b31f6bfd2b510d255824b102992a5d5f873c6475f8db78bfd1c6f7d3",
        importpath = "google.golang.org/protobuf",
        strip_prefix = "protobuf-go-28b807b56e3c526adc5a101d2b233a5759bf05f5",
    )

    dbx_go_dependency(
        name = "com_github_yuin_goldmark",
        url = urls["com_github_yuin_goldmark"],
        sha256 = "c6c718058e63b32876c597fa709d8e84382cb567eae3b010014400853b48592a",
        importpath = "github.com/yuin/goldmark",
        strip_prefix = "goldmark-1.4.1",
    )

    dbx_go_dependency(
        name = "org_golang_x_crypto",
        url = urls["org_golang_x_crypto"],
        sha256 = "a86a87b78791475b7331f61a81caeac8bcd69d8551c4d4ae964da2b8566daa9b",
        importpath = "golang.org/x/crypto",
        strip_prefix = "crypto-630584e8d5aaa1472863b49679b2d5548d80dcba",
    )

    dbx_go_dependency(
        name = "io_opentelemetry_go_proto_otlp",
        url = urls["io_opentelemetry_go_proto_otlp"],
        sha256 = "6e66a2c1f5c599a09e2432ca8e2a04d1d5c64fb094552b69d04e0203efa28731",
        importpath = "go.opentelemetry.io/proto/otlp",
        strip_prefix = "opentelemetry-proto-go-0.19.0",
    )

    dbx_go_dependency(
        name = "com_github_google_go_cmp",
        url = urls["com_github_google_go_cmp"],
        sha256 = "810f58a3e91a211adbd545aa9af1446602dd9e77199105032f3db0d8f79c4303",
        importpath = "github.com/google/go-cmp",
        strip_prefix = "go-cmp-b1c9c4891a6525d98001fea424c8926c6d77bb56",
    )

    dbx_go_dependency(
        name = "com_github_pmezard_go_difflib",
        url = urls["com_github_pmezard_go_difflib"],
        sha256 = "28f3dc1b5c0efd61203ab07233f774740d3bf08da4d8153fb5310db6cea0ebda",
        importpath = "github.com/pmezard/go-difflib",
        strip_prefix = "go-difflib-1.0.0",
    )

    dbx_go_dependency(
        name = "com_github_stretchr_objx",
        url = urls["com_github_stretchr_objx"],
        sha256 = "3bb0a581651f4c040435a70167ab60b723c5af04a5b0326af3c8b01ccc6fdcf0",
        importpath = "github.com/stretchr/objx",
        strip_prefix = "objx-0.1.1",
    )

    dbx_go_dependency(
        name = "org_golang_x_xerrors",
        url = urls["org_golang_x_xerrors"],
        sha256 = "25b085a914da78b9e922d49316eaab69a042a09285e46485a5cd2c50702a68d8",
        importpath = "golang.org/x/xerrors",
        strip_prefix = "xerrors-5ec99f83aff198f5fbd629d6c8d8eb38a04218ca",
    )

    dbx_go_dependency(
        name = "org_golang_x_time",
        url = urls["org_golang_x_time"],
        sha256 = "06c36fd8fa2aa6eb46498d3be7163346580f70b3e53f4c5911dc4dcdbd1d8736",
        importpath = "golang.org/x/time",
        strip_prefix = "time-8be79e1e0910c292df4e79c241bb7e8f7e725959",
    )

    dbx_go_dependency(
        name = "org_golang_x_term",
        url = urls["org_golang_x_term"],
        sha256 = "4b65559bf59961ba670090656e5cd7472afe4527462e9a3a7b93ca476dfc5852",
        importpath = "golang.org/x/term",
        strip_prefix = "term-7de9c90e9dd184706b838f536a1cbf40a296ddb7",
    )

    dbx_go_dependency(
        name = "org_golang_x_text",
        url = urls["org_golang_x_text"],
        sha256 = "49d854716d42af8ca7c97846f95ed4f3fba19a14e83c363eba8248949091f9b3",
        importpath = "golang.org/x/text",
        strip_prefix = "text-48e4a4a957429d31328a685863b594ca9a06b552",
    )

    dbx_go_dependency(
        name = "org_golang_x_net",
        url = urls["org_golang_x_net"],
        sha256 = "7ef368226edd2189ecd36d6393de6b92ca39c403e1cb09cb4848e2ab07be89c3",
        importpath = "golang.org/x/net",
        strip_prefix = "net-6772e930b67bb09bf22262c7378e7d2f67cf59d1",
    )

    dbx_go_dependency(
        name = "org_golang_google_genproto",
        url = urls["org_golang_google_genproto"],
        sha256 = "21f94c04d7ed968e03c5d2814e29952d67ba301f7653b642957088add494dd8d",
        importpath = "google.golang.org/genproto",
        strip_prefix = "go-genproto-669157292da34ccd2ff7ebc3af406854a79d61ce",
    )

    dbx_go_dependency(
        name = "in_gopkg_yaml_v3",
        url = urls["in_gopkg_yaml_v3"],
        sha256 = "cf05411540d3e6ef8f1fd88434b34f94cedaceb540329031d80e23b74540c4e5",
        importpath = "gopkg.in/yaml.v3",
        strip_prefix = "yaml-3.0.1",
    )

    dbx_go_dependency(
        name = "com_github_bazelbuild_buildtools",
        url = urls["com_github_bazelbuild_buildtools"],
        sha256 = "a21b90e5fc75e7126b051121c4086258a9d9a9932ba3b9ab98ce1c67ee3053fb",
        importpath = "github.com/bazelbuild/buildtools",
        strip_prefix = "buildtools-e6efbf6df90bec363c3cbd564b72be6c8a309f14",
    )

    dbx_go_dependency(
        name = "in_gopkg_check_v1",
        url = urls["in_gopkg_check_v1"],
        sha256 = "a925c029af70ffc6e76769f255f1f0dc52127cae577b6aa67f1f1128deda4328",
        importpath = "gopkg.in/check.v1",
        strip_prefix = "check-10cb98267c6cb43ea9cd6793f29ff4089c306974",
    )

    dbx_go_dependency(
        name = "com_github_davecgh_go_spew",
        url = urls["com_github_davecgh_go_spew"],
        sha256 = "7d82b9bb7291adbe7498fe946920ab3e7fc9e6cbfc3b2294693fad00bf0dd17e",
        importpath = "github.com/davecgh/go-spew",
        strip_prefix = "go-spew-1.1.1",
    )

    dbx_go_dependency(
        name = "com_github_kr_pretty",
        url = urls["com_github_kr_pretty"],
        sha256 = "e6fa7db2708320e66a1645bf6b234e524e73f4163ca0519b8608616e48f5d206",
        importpath = "github.com/kr/pretty",
        strip_prefix = "pretty-0.3.1",
    )

    dbx_go_dependency(
        name = "com_github_kr_text",
        url = urls["com_github_kr_text"],
        sha256 = "59b5e4a7fd4097be87fad0edcaf342fdc971d0c8fdfb4f2d7424561471992e7c",
        importpath = "github.com/kr/text",
        strip_prefix = "text-0.2.0",
    )

    dbx_go_dependency(
        name = "com_github_rogpeppe_go_internal",
        url = urls["com_github_rogpeppe_go_internal"],
        sha256 = "a8223943815523c3e49ac1731c323fd7b949b74ecfc151e8201064ab351a6f42",
        importpath = "github.com/rogpeppe/go-internal",
        strip_prefix = "go-internal-1.9.0",
    )

    dbx_go_dependency(
        name = "com_github_creack_pty",
        url = urls["com_github_creack_pty"],
        sha256 = "7a1d6775e3f99b98e5d87303e9aeacfd73d810abffc17e42a561d0650adc980e",
        importpath = "github.com/creack/pty",
        strip_prefix = "pty-1.1.18",
    )
