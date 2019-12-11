# mypy: allow-untyped-defs

# This is Python 3 code.

import json
import sys

from build_tools.bzl_lib.parse_py_imports import parse_imports


def main():
    workspace_dir, src = sys.argv[1:]
    import_set, from_set = parse_imports(workspace_dir, src)
    json_dict = {"import_set": list(import_set), "from_set": list(from_set)}
    print(json.dumps(json_dict))


if __name__ == "__main__":
    main()
