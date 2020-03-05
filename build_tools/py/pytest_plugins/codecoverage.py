# mypy: allow-untyped-defs

"Stripped-down version of pytest-cov."

import os

from os.path import expandvars

import coverage  # type: ignore[import]
import coverage.collector  # type: ignore[import]
import coverage.control  # type: ignore[import]
import coverage.files  # type: ignore[import]

# Coverage likes to realpath filenmaess but we need paths relative to the exec
# root. So we patch it a bit get it inline.


# copy paste from coverage.files.abs_file
def abs_file(filename):
    """Return the absolute normalized form of `filename`."""
    path = expandvars(os.path.expanduser(filename))
    # try:
    #    path = os.path.realpath(path)
    # except UnicodeError:
    #    pass
    path = os.path.abspath(path)
    path = coverage.files.actual_path(path)
    path = coverage.files.unicode_filename(path)
    return path


coverage.collector.abs_file = abs_file
coverage.files.abs_file = abs_file
coverage.control.abs_file = abs_file


def pytest_configure(config):
    if not os.getenv("COVERAGE_OUTPUT_FILE", None) or not os.getenv(
        "COVERAGE_MANIFEST", None
    ):
        # These variables are expected to be set by `bazel test` if coverage is enabled
        return

    # Read list of files to be covered from $COVERAGE_MANIFEST
    coverage_source = open(os.getenv("COVERAGE_MANIFEST")).read().split()  # type: ignore[arg-type]
    coverage_output = os.getenv("COVERAGE_OUTPUT_FILE")

    if coverage_source:
        plugin = CovPlugin(coverage_source, coverage_output)
        config.pluginmanager.register(plugin)


class CovPlugin(object):
    def __init__(self, coverage_source, coverage_output):
        self.cov = coverage.Coverage(
            source=[s.replace("/", ".")[:-3] for s in coverage_source]
        )
        self.cov.start()
        self.coverage_output = coverage_output

    def pytest_sessionfinish(self, session, exitstatus):
        self.cov.stop()
        self.cov.xml_report(outfile=self.coverage_output, ignore_errors=False)
