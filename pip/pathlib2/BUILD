package(default_visibility = ["//visibility:public"])

load("//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

dbx_py_pypi_piplib(
    name = "pathlib2",
    pip_version = "2.3.5",
    python3_compatible = True,
    deps = [
        "//pip/scandir",
        "//pip/six",
    ],
)
