# @generated: This file was generated by bzl. Do not modify!
# Argument overrides and custom targets should be specified in BUILD.in.

load("//build_tools/go:go.bzl", "dbx_go_library", "dbx_go_test")

dbx_go_library(
    name = "svclib",
    testonly = True,
    srcs = [
        "constants.go",
        "healthchecks.go",
        "service.go",
    ],
    visibility = [
        "//go/src/atlas:__subpackages__",
        "//go/src/dropbox:__subpackages__",
    ],
    deps = [
        "//go/src/dropbox/proto/build_tools/svclib",
        "//go/src/github.com/gogo/protobuf/proto",
        "@org_golang_google_grpc",
    ],
)

dbx_go_test(
    name = "svclib_test",
    srcs = [
        "constants.go",
        "healthchecks.go",
        "service.go",
        "service_test.go",
    ],
    data = [
        "//dropbox/build_tools/echo_server",
        "//dropbox/build_tools/echo_server:echo_client",
    ],
    force_launch_svcctl = True,
    deps = [
        "//go/src/dropbox/proto/build_tools/svclib",
        "//go/src/dropbox/runfiles",
        "//go/src/github.com/gogo/protobuf/proto",
        "@com_github_stretchr_testify//require",
        "@org_golang_google_grpc",
    ],
)
