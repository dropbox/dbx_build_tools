# isort:skip_file
# This file is carefully crafted to import things in the right order
import sys

if sys.argv[1] == "--profile":
    sys.argv.pop(1)
    from dropbox.testutils.plugins import dbxperf

    stop_profiling = dbxperf.start()
else:
    stop_profiling = None

# The only zip in our path is the stdlib, which won't have distributions.
# Neuter importlib_metadata's support for zip files to avoid unzipping stdlib
# repeatedly, saving around 1s on pytest startup time.
#
# Our journey is made more complicated by importlib_metadata's insistence on
# computing it's own __version__ by checking its own distribution at import time.
# Thus we first must no-op `zipp` to make the importlib_metadata import behave,
# then we can properly neuter importlib_metadata and restore `zipp` support.
#
# Once we fully switch to Py3 and use importlib.metadata from stdlib, this can
# be simplifed as the __version__ complications will be moot.
class FakeZipPath(object):
    def __init__(self, *args):  # type: ignore[no-untyped-def]
        self.root = self

    def namelist(self):  # type: ignore[no-untyped-def]
        return []


import zipp  # type: ignore[import]

zippPath = zipp.Path
zipp.Path = FakeZipPath

from importlib_metadata import FastPath  # type: ignore[import]

FastPath.zip_children = lambda _: []
zipp.Path = zippPath

import os
import pytest

__file__ = "py.test"
sys.argv[0] = sys.argv[0].replace("main.py", "py.test")

code = pytest.main()
sys.stdout.flush()
sys.stderr.flush()

if stop_profiling:
    stop_profiling()

os._exit(code)
