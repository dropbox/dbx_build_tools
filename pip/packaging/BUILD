package(default_visibility = ["//visibility:public"])

load("//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

dbx_py_pypi_piplib(
    name = "packaging",
    pip_version = "22.0",
    setup_requires = [
        "//pip/flit-core",
    ],
    use_pep517 = True,
    deps = [
        "//pip/pyparsing",
        "//pip/six",
    ],
)
