package(default_visibility = ["//visibility:public"])

load("//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

licenses(["notice"])  # MIT

dbx_py_pypi_piplib(
    name = "cffi",
    pip_version = "1.14.3",
    deps = [
        "//pip/pycparser",
        "@org_sourceware_libffi//:ffi",
    ],
)
