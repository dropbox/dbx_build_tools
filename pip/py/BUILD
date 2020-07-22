package(default_visibility = ["//visibility:public"])

load("//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

dbx_py_pypi_piplib(
    name = "py",
    pip_version = "1.8.0",
    python2_compatible = True,
    python3_compatible = True,
    setup_requires = ["//pip/setuptools_scm"],
)
