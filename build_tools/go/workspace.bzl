load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("//build_tools/go:godep.bzl", "define_go_deps")

def load_go_build_gen():
    http_archive(
        name = "dbx_go_repository_build_gen",
        urls = ["https://dbx-artifactory-primary.awsvip.dbxnw.net/artifactory/archives-local/gen-build-go/gen-build-go-pkg-20230323T0017-ccdbf428f68.tar.gz"],
        sha256 = "c3dfec9137a794b8d1246fd0c8ddf0fc4e15a6a684af99700d7e05d69a7d9a10",
        build_file_content = 'exports_files(":gen-build-go_bin", visibility=["//visibility:public"])',
    )

def load_thirdparty_go_deps():
    define_go_deps()
