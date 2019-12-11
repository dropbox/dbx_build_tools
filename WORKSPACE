workspace(name = "dbx_build_tools")

# Add external dependencies in //build_tools/bazel:external_workspace.bzl.
load('//build_tools/bazel:external_workspace.bzl', 'drte_deps')

drte_deps()

register_toolchains(
    "//thirdparty/cpython:drte-off-27-toolchain",
    "//thirdparty/cpython:drte-off-37-toolchain",
)
