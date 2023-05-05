workspace(name="dbx_build_tools")

# This combined with the "build_tools/copybara/patches/use_local_gen_build_go.patch" allows us to use a local gen-build-go for "dbx_go_dependency"
new_local_repository(
    name = "dbx_go_repository_build_gen",
    path = "/tmp/gen-build-go-pkg",
    build_file_content = 'exports_files(":gen-build-go_bin", visibility=["//visibility:public"])',
)

# Add external dependencies in //build_tools/bazel:external_workspace.bzl.
load("//build_tools/bazel:external_workspace.bzl", "drte_deps")

drte_deps()

register_toolchains(
    "//thirdparty/cpython:drte-off-39-toolchain",
)
