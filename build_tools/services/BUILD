# @generated: This file was generated by bzl. Do not modify!
# Argument overrides and custom targets should be specified in BUILD.in.

package(default_visibility = ["//visibility:public"])

load("//build_tools/sh:sh.bzl", "dbx_sh_test")
load("@bazel_skylib//:bzl_library.bzl", "bzl_library")

dbx_sh_test(
    name = "restart_test",
    srcs = ["restart_test.sh"],
    data = [
        "//go/src/dropbox/build_tools/svcctl/cmd/svcctl",
    ],
    tags = ["manual"],  # not meant to be run on its own. needs services
)

bzl_library(
    name = "services_bzl",
    srcs = [
        "svc.bzl",
    ],
    deps = [
        "//build_tools/bazel:bazel_bzl",
        "//build_tools/py:py_bzl",
    ],
)
