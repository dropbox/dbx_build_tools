# @generated: This file was generated by bzl. Do not modify!
# Argument overrides and custom targets should be specified in BUILD.in.

load("//build_tools/go:go.bzl", "dbx_go_library", "dbx_go_test")

dbx_go_library(
    name = "lib",
    srcs = [
        "embed.go",
        "genbuildgolib.go",
        "godep.go",
        "tagmap.go",
        "targetlist.go",
        "utils.go",
    ],
    visibility = [
        "//go/src/atlas:__subpackages__",
        "//go/src/dropbox:__subpackages__",
    ],
    deps = [
        "@com_github_bazelbuild_buildtools//build",
        "@org_golang_x_mod//modfile",
        "@org_golang_x_mod//module",
    ],
)

dbx_go_test(
    name = "lib_test",
    srcs = [
        "embed.go",
        "embed_test.go",
        "genbuildgolib.go",
        "genbuildgolib_test.go",
        "godep.go",
        "tagmap.go",
        "tagmap_test.go",
        "targetlist.go",
        "utils.go",
    ],
    deps = [
        "@com_github_bazelbuild_buildtools//build",
        "@com_github_stretchr_testify//require",
        "@org_golang_x_mod//modfile",
        "@org_golang_x_mod//module",
    ],
)

filegroup(
    name = "srcs",
    data = glob(
        ["*.go"],
        exclude = ["*_test.go"],
    ),
    visibility = ["//go/src/dropbox/build_tools/gen-build-go:__pkg__"],
)
