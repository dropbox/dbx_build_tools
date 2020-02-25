from __future__ import print_function

import sys

from build_tools.py import dbx_importer

if __name__ == "__main__":
    allow_failures = sys.argv[1] == "--allow-failures"
    items = sys.argv[2:]
    assert len(items) % 3 == 0
    n = len(items) // 3
    worked = False
    for src_path, short_path, dest_path in zip(
        items[:n], items[n : 2 * n], items[2 * n :]
    ):
        if dbx_importer.dbx_compile(src_path, dest_path, short_path, allow_failures):
            worked = True
    if not worked:
        print("all files failed to compile")
        sys.exit(1)
