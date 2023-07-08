load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("//build_tools/go:godep.bzl", "define_go_deps")

def load_go_build_gen():
    http_archive(
        name = "dbx_go_repository_build_gen",
        urls = ["https://dbx-artifactory-primary.awsvip.dbxnw.net/artifactory/archives-local/gen-build-go/gen-build-go-pkg-20230707T2248-fb93a94d3ae75.tar.gz"],
        sha256 = "4ce413d15d9cfd6a7d9cd0f58572f2848146ad071014b2d28db2791614186466",
        build_file_content = 'exports_files(":gen-build-go_bin", visibility=["//visibility:public"])',
    )

def load_thirdparty_go_deps():
    define_go_deps()
