from __future__ import print_function

import argparse
import os
import sys

from typing import Dict, List

PIPLIB_SEPARATOR = "=" * 10


def check_piplib_conflicts(output_file, namespace_pkgs, files):
    # type: (str, List[str], List[str]) -> None
    curr_piplib = None

    conflicts = {}  # type: Dict[str, str]
    for item in files:
        if item.startswith(PIPLIB_SEPARATOR) and item.endswith(PIPLIB_SEPARATOR):
            curr_piplib = item.split(PIPLIB_SEPARATOR)[1]
            continue
        assert curr_piplib, "No idea where this item comes from"
        if item in conflicts:
            # __init__.py files in namespace packages may conflict.
            dirname, basename = os.path.split(item)
            if os.path.basename(dirname) == "__pycache__":
                dirname = os.path.dirname(dirname)
            if (
                basename == "__init__.py"
                or (
                    basename.startswith("__init__.")
                    and basename.endswith((".pydbxc", ".pyc"))
                )
            ) and dirname.replace("/", ".") in namespace_pkgs:
                continue
            print(
                "%s provided by %s and %s" % (item, conflicts[item], curr_piplib),
                file=sys.stderr,
            )
            sys.exit(1)
        conflicts[item] = curr_piplib

    with open(output_file, "w") as f:
        f.write("No conflicts in merged piplib!")


def main():
    # type: () -> None
    parser = argparse.ArgumentParser(fromfile_prefix_chars="@")
    parser.add_argument("-o", "--output-file", help="Name of file to write output to")
    parser.add_argument(
        "--namespace_pkg",
        default=[],
        action="append",
        help="namespace package the binary participates in",
    )
    parser.add_argument("files", nargs="*")
    args = parser.parse_args()

    check_piplib_conflicts(args.output_file, args.namespace_pkg, args.files)


if __name__ == "__main__":
    main()
