GLOBAL_PYTEST_PLUGINS = [
    "@dbx_build_tools//build_tools/py/pytest_plugins:preserve_symlinks",
]
GLOBAL_PYTEST_ARGS = [
    "-p",
    "build_tools.py.pytest_plugins.preserve_symlinks",
]
NON_THIRDPARTY_PACKAGE_PREFIXES = []
PYPI_MIRROR_URL = "https://pypi.org/simple/"
