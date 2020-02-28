load("@dbx_build_tools//build_tools/py:toolchain.bzl", "cpython_27", "cpython_37", "cpython_38")

GLOBAL_PYTEST_PLUGINS = [
    "@dbx_build_tools//build_tools/py/pytest_plugins:preserve_symlinks",
] + select({
    "@dbx_build_tools//build_tools:coverage-enabled": ["@dbx_build_tools//build_tools/py/pytest_plugins:codecoverage"],
    "//conditions:default": [],
})

GLOBAL_PYTEST_ARGS = [
    "-p",
    "build_tools.py.pytest_plugins.preserve_symlinks",
] + select({
    "@dbx_build_tools//build_tools:coverage-enabled": ["-p", "build_tools.py.pytest_plugins.codecoverage"],
    "//conditions:default": [],
})

NON_THIRDPARTY_PACKAGE_PREFIXES = []

PYPI_MIRROR_URL = "https://pypi.org/simple/"

ALL_ABIS = [
    cpython_27,
    cpython_37,
    cpython_38,
]

PY2_TEST_ABI = cpython_27
PY3_TEST_ABI = cpython_38
PY3_ALTERNATIVE_TEST_ABIS = []

PY3_DEFAULT_BINARY_ABI = cpython_38
