package(default_visibility = ["//visibility:public"])

load("//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

dbx_py_pypi_piplib(
    name = "zipp",
    pip_version = "1.1.1",
    setup_requires = ["//pip/setuptools_scm"],
    use_pep517 = True,
    deps = ["//pip/contextlib2"],
)
