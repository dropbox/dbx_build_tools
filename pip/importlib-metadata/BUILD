package(default_visibility = ["//visibility:public"])

load("//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

dbx_py_pypi_piplib(
    name = "importlib-metadata",
    pip_version = "6.8.0",
    provides = ["importlib_metadata"],
    setup_requires = ["//pip/setuptools_scm"],
    use_pep517 = True,
    deps = [
        "//pip/configparser",
        "//pip/contextlib2",
        "//pip/pathlib2",
        "//pip/zipp",
    ],
)
