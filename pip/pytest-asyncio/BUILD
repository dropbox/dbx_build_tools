package(default_visibility = ["//visibility:public"])

load("//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

dbx_py_pypi_piplib(
    name = "pytest-asyncio",
    testonly = True,
    pip_version = "0.18.0",
    provides = ["pytest_asyncio"],
    setup_requires = ["//pip/pytest"],
    use_pep517 = True,
    deps = ["//pip/pytest"],
)
