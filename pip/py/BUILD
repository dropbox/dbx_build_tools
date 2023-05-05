package(default_visibility = ["//visibility:public"])

load("//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

dbx_py_pypi_piplib(
    name = "py",
    pip_version = "1.11.0",
    setup_requires = ["//pip/setuptools_scm"],
    use_pep517 = True,
)
