load("//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

licenses(["notice"])  # MIT

dbx_py_pypi_piplib(
    name = "setuptools",
    pip_version = "44.0.0",  # Last version to support py2.
    provides = [
        "pkg_resources",
        "setuptools",
    ],
    python2_compatible = True,
    visibility = ["//visibility:public"],
)
