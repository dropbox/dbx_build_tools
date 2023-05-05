package(default_visibility = ["//visibility:public"])

load("//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

licenses(["notice"])  # MIT

dbx_py_pypi_piplib(
    name = "setuptools_scm",
    pip_version = "5.0.1",
    use_pep517 = True,
    deps = [
        "//pip/setuptools",
        "//pip/toml",
    ],
)
