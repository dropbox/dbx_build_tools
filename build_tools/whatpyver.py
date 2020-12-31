"""Tool to print the Python version for one or more files.

The information is taken from the BUILD files, specifically the
python2_compatible or python3_compatible flags in the dbx_py_library
targets (and a few other targets).  Each relevant BUILD file is parsed
at most once.

Output format:

<file1>:py2:py3:
<file2>:py2:
<file3>::py3:
<file4>:::

If an argument is a directory, we produce output for all .py files in
that directory and recursively in all its subdirectories.
"""

from __future__ import print_function

import argparse
import os
import stat
import sys
import time

from typing import Dict, Iterable, List, Optional, Set, Tuple

from build_tools import build_parser

# Rules that have pythonN_compatible flags.
# See build_tools/py/py.bzl; also see other lists of rules in
# build_tools/bzl_lib/gen_build_py.py.
RULE_TYPES = [
    "dbx_py_binary",
    "dbx_py_library",
    "dbx_py_pytest_test",
    "dbx_py_test",
    "dbx_py_compiled_pytest_test",
    "py_library",
    "py_binary",
    "nagios_py_plugin",
    "dbx_slow_metaserver_test",
    "dbx_metaserver_test",
    "dbx_internal_bootstrap_py_binary",
    "dbx_py_selenium_test",
    # Atlas targets
    "dbx_atlas_http_test",
    "dbx_atlas_metaserver_http_test",
    "dbx_slow_atlas_metaserver_http_test",
    "dbx_atlas_slow_and_expensive_testutil_library",
    "dbx_atlas_servicers_py_library",
    # Tensorflow targets
    "dbx_py_tf_binary",
    "dbx_py_tf_pytest_test",
]

RULE_TYPES_THAT_DEFAULT_PY3_ONLY = [
    "dbx_py_binary",
    "dbx_py_test",
    "py_library",
    "py_binary",
]


class PythonVersionCache(object):
    def __init__(self, verbose=False):
        # type: (bool) -> None
        self._verbose = verbose
        self.clear()

    def clear(self):
        # type: () -> None
        self._files_to_build_files = {}  # type: Dict[str, str]
        self._build_file_mtimes = {}  # type: Dict[str, Optional[float]]
        self._build_file_parsers = {}  # type: Dict[str, build_parser.BuildParser]
        self._py2_files = set()  # type: Set[str]
        self._py3_files = set()  # type: Set[str]

    def _get_build_file_and_mtime(self, dir):
        # type: (str) -> Tuple[str, Optional[float]]
        # On macOS, os.stat('BUILD') will return a result if 'build'
        # exists.  In most cases, only BUILD exists and is a file, and
        # that's what we want.  In a few rare cases, 'build' is a
        # folder and BUILD.bazel is the file we want.  Finally, in
        # plenty of cases, neither exists, and we have to crawl up.
        # We hope to do only one stat() call per directory, as
        # follows:
        #
        # - If either BUILD or BUILD.bazel is cached, use that.
        # - Otherwise, stat() BUILD first, and use that if it exists
        #   and is a plain file.
        # - Otherwise, also stat() BUILD.bazel, and use that if it
        #   exists and is a plain file.
        # - Otherwise, create a negative cache entry for BUILD.
        #
        # So in the common case ('BUILD' exists and is a plain file)
        # we end up doing only a single stat().

        build_plain = os.path.join(dir, "BUILD")
        build_bazel = os.path.join(dir, "BUILD.bazel")
        possibilities = [build_plain, build_bazel]

        for build_file in possibilities:
            if build_file in self._build_file_mtimes:
                mtime = self._build_file_mtimes[build_file]  # type: Optional[float]
                if self._verbose > 1:
                    print("%s: cached mtime %s" % (build_file, mtime), file=sys.stderr)
                return build_file, mtime

        for build_file in possibilities:
            mtime = None
            try:
                st = os.stat(build_file)
            except os.error:
                pass
            else:
                if stat.S_ISREG(st.st_mode):
                    mtime = st.st_mtime
                    break

        if mtime is None:
            build_file = build_plain

        if self._verbose > 1:
            print("%s: original mtime %s" % (build_file, mtime), file=sys.stderr)
        self._build_file_mtimes[build_file] = mtime
        return build_file, mtime

    def find_build_files(self, file):
        # type: (str) -> Optional[List[Tuple[str, Optional[float]]]]
        dir = os.path.dirname(file)
        trail = []
        while dir:
            build_file, mtime = self._get_build_file_and_mtime(dir)
            trail.append((build_file, mtime))
            if mtime:
                if self._verbose > 1:
                    print("%s: found %s" % (file, build_file), file=sys.stderr)
                return trail  # trail[-1][0] is the hit
            else:
                if self._verbose > 2:
                    print("%s: nothing at %s" % (file, build_file), file=sys.stderr)
            parent = os.path.dirname(dir)
            if not parent or parent == dir:
                break
            dir = parent
        if self._verbose > 1:
            print("%s: no BUILD file" % file, file=sys.stderr)
        return None

    def add_file(self, file):
        # type: (str) -> Optional[str]
        if file in self._files_to_build_files:
            return self._files_to_build_files[file]
        build_file_trail = self.find_build_files(file)
        if not build_file_trail:
            return None
        build_file = build_file_trail[-1][0]
        self._files_to_build_files[file] = build_file
        return build_file

    def parse_build_files(self):
        # type: () -> None
        for build_file in set(self._files_to_build_files.values()):
            if build_file in self._build_file_parsers:
                continue
            self.parse_build_file(build_file)

    def parse_build_file(self, build_file):
        # type: (str) -> None
        if not os.path.isfile(build_file):
            return
        if self._verbose:
            print(
                "Parsing %s (%d bytes)" % (build_file, os.path.getsize(build_file)),
                file=sys.stderr,
            )
        dir = os.path.dirname(build_file)
        bp = build_parser.BuildParser()
        if self._verbose:
            t0 = time.time()
        try:
            bp.parse_file(build_file)
        except SyntaxError as err:
            sys.stderr.write("whatpyver: Syntax error ignored in build file\n")
            sys.stderr.write(
                "%s:%s:%s\n"
                % (
                    os.path.relpath(build_file),
                    err.lineno,
                    err.text.rstrip() if err.text is not None else "",
                )
            )
            return
        finally:
            if self._verbose:
                t1 = time.time()
                print("Parsing took %.1f msec" % ((t1 - t0) * 1000))
        self._build_file_parsers[build_file] = bp
        for rule in bp.get_rules_by_types(RULE_TYPES):
            # NOTE: These defaults may change when build_tools/py/py.bzl changes.
            # python2_compatible is used by dbx_py_binary
            # python_version is used by py_binary
            # srcs_version is used by py_library
            py2 = (
                rule.attr_map.get(
                    "python2_compatible",
                    rule.rule_type not in RULE_TYPES_THAT_DEFAULT_PY3_ONLY,
                )
                or rule.attr_map.get("python_version", "PY3") == "PY2"
                or rule.attr_map.get("srcs_version", "PY3")
                in ("PY2", "PY2ONLY", "PY2AND3")
            )

            py3 = (
                rule.attr_map.get("python3_compatible", True)
                and rule.attr_map.get("python_version", "PY3") != "PY2"
                and rule.attr_map.get("srcs_version", "PY3") != "PY2ONLY"
            )
            for src in build_parser.maybe_expand_attribute(
                rule.attr_map.get("srcs", [])
            ):
                src = os.path.join(dir, src)
                if py2:
                    self._py2_files.add(src)
                if py3:
                    self._py3_files.add(src)

    def get_flags(self, file):
        # type: (str) -> Tuple[bool, bool]
        if file not in self._files_to_build_files:
            build_file = self.add_file(file)
            if build_file and build_file not in self._build_file_parsers:
                self.parse_build_file(build_file)
        return (file in self._py2_files, file in self._py3_files)


def find_python_files(dir):
    # type: (str) -> Iterable[str]
    for root, dirs, files in os.walk(dir):
        for file in files:
            if file.endswith(".py"):
                yield os.path.join(root, file)


def main():
    # type: () -> int
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "-v",
        "--verbose",
        action="count",
        default=0,
        help="more verbose output (may be repeated)",
    )
    ap.add_argument("files", nargs="+", help="file names (must be Python files)")

    args = ap.parse_args(sys.argv[1:])

    pvc = PythonVersionCache(args.verbose)

    errors = False
    all_files = []
    for file in args.files:
        if os.path.isdir(file):
            files = list(find_python_files(file))
        else:
            files = [file]
        all_files.extend(files)
        for file in files:
            if not file.endswith(".py"):
                print("%s: not a Python file" % file, file=sys.stderr)
                errors = True
            elif not os.path.exists(file):
                print("%s: Python file does not exist" % file, file=sys.stderr)
                errors = True
            elif not pvc.add_file(file):
                print(
                    "%s: Python file does not have a corresponding BUILD file" % file,
                    file=sys.stderr,
                )
                errors = True
    if errors:
        return 2

    pvc.parse_build_files()

    for file in all_files:
        py2, py3 = pvc.get_flags(file)
        print("%s:%s:%s:" % (file, "py2" if py2 else "", "py3" if py3 else ""))

    return 0


if __name__ == "__main__":
    code = main()
    if code:
        sys.exit(code)
