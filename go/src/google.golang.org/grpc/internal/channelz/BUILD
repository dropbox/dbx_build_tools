# @generated: This file was generated by bzl. Do not modify!
# Argument overrides and custom targets should be specified in BUILD.in.

load("//build_tools/go:go.bzl", "dbx_go_library")

dbx_go_library(
    name = "channelz",
    srcs = [
        "funcs.go",
        "logging.go",
        "types.go",
        "types_linux.go",
        "util_linux.go",
    ],
    visibility = [
        "//go/src/google.golang.org/grpc:__subpackages__",
    ],
    deps = [
        "//go/src/golang.org/x/sys/unix",
        "//go/src/google.golang.org/grpc/connectivity",
        "//go/src/google.golang.org/grpc/credentials",
        "//go/src/google.golang.org/grpc/grpclog",
    ],
)
