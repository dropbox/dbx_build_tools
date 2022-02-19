load("@dbx_build_tools//build_tools/py:toolchain.bzl", "cpython_39")

GLOBAL_PYTEST_PLUGINS = [
    "@dbx_build_tools//build_tools/py/pytest_plugins:preserve_symlinks",
    "@dbx_build_tools//pip/pytest-asyncio",
] + select({
    "@dbx_build_tools//build_tools:coverage-enabled": ["@dbx_build_tools//build_tools/py/pytest_plugins:codecoverage"],
    "//conditions:default": [],
})

GLOBAL_PYTEST_ARGS = [
    "--asyncio-mode=auto",
    "-p",
    "build_tools.py.pytest_plugins.preserve_symlinks",
] + select({
    "@dbx_build_tools//build_tools:coverage-enabled": ["-p", "build_tools.py.pytest_plugins.codecoverage"],
    "//conditions:default": [],
})

NON_THIRDPARTY_PACKAGE_PREFIXES = []

PYPI_MIRROR_URL = "https://pypi.org/simple/"

ALL_ABIS = [
    cpython_39,
]

PY2_TEST_ABI = None
PY3_TEST_ABI = cpython_39
PY3_ALTERNATIVE_TEST_ABIS = []

PY3_DEFAULT_BINARY_ABI = cpython_39
