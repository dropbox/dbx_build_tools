# mypy: allow-untyped-defs

# This plugin hacks various parts of pytest that resolve symlinks. Resolving symlinks in Bazel tests
# is bad because it usually escapes the sandbox.  If
# https://github.com/pytest-dev/pytest/issues/5266 is ever fixed, we can probably get rid of this.

import pathlib

import attr


class _SymlinkPhilicPath(pathlib.PosixPath):
    def realpath(self):
        # type: () -> _SymlinkPhilicPath
        return self


def pytest_load_initial_conftests(early_config):
    pm = early_config.pluginmanager
    gctm = pm._getconftestmodules

    def _getconftestmodules(anchor, importmode, rootpath):
        return gctm(_SymlinkPhilicPath(anchor), importmode, rootpath)

    pm._getconftestmodules = _getconftestmodules
    early_config.invocation_params = attr.evolve(
        early_config.invocation_params,
        dir=_SymlinkPhilicPath(early_config.invocation_params.dir),
    )
