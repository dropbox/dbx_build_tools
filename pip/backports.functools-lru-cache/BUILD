package(default_visibility = ["//visibility:public"])

load("//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

licenses(["notice"])  # MIT

dbx_py_pypi_piplib(
    name = "backports.functools-lru-cache",
    namespace_pkgs = ["backports"],
    pip_version = "1.6.1",
    provides = ["backports.functools_lru_cache"],
    setup_requires = ["//pip/setuptools_scm"],
    use_pep517 = True,
)
