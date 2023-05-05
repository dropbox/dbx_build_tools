load("//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

licenses(["notice"])  # MIT

# NOTE: //build_tools/py/vpip.py encodes the version of setuptools.
dbx_py_pypi_piplib(
    name = "setuptools",
    pip_version = "67.3.2",
    provides = [
        "pkg_resources",
        "setuptools",
    ],
    use_pep517 = True,
    visibility = ["//visibility:public"],
)
