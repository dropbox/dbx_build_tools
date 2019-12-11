# mypy: allow-untyped-defs

# This plugin hacks various parts of pytest that resolve symlinks. Resolving symlinks in Bazel tests
# is bad because it usually escapes the sandbox.  If
# https://github.com/pytest-dev/pytest/issues/5266 is ever fixed, we can probably get rid of this.

import py


class _SymlinkPhilicPath(py.path.local):
    def realpath(self):
        return self


def pytest_load_initial_conftests(early_config):
    pm = early_config.pluginmanager
    gctm = pm._getconftestmodules

    def _getconftestmodules(p):
        return gctm(_SymlinkPhilicPath(p))

    pm._getconftestmodules = _getconftestmodules
    early_config.invocation_dir = _SymlinkPhilicPath(early_config.invocation_dir)
