package(default_visibility = ["//visibility:public"])

load("//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

dbx_py_pypi_piplib(
    name = "configparser",
    namespace_pkgs = ["backports"],
    pip_version = "4.0.2",
    provides = ["backports.configparser"],
    setup_requires = ["//pip/setuptools_scm"],
    use_pep517 = True,
)
