from __future__ import print_function

import sys

PIPLIB_SEPARATOR = "=" * 10
curr_piplib = None

conflicts = {}  # type: ignore[var-annotated]
for item in sys.argv[2:]:
    if item.startswith(PIPLIB_SEPARATOR) and item.endswith(PIPLIB_SEPARATOR):
        curr_piplib = item.split(PIPLIB_SEPARATOR)[1]
        continue
    assert curr_piplib, "No idea where this item comes from"
    if item in conflicts:
        print(
            "%s provided by %s and %s" % (item, conflicts[item], curr_piplib),
            file=sys.stderr,
        )
        sys.exit(1)
    conflicts[item] = curr_piplib

with open(sys.argv[1], "w") as f:
    f.write("No conflicts in merged piplib!")
