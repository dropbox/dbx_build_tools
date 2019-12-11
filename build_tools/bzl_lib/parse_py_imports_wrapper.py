# This is Python 2 code.

from __future__ import print_function

import json
import subprocess

from typing import Set, Tuple

from dropbox import runfiles


def parse_imports_py3(workspace_dir, src):
    # type: (str, str) -> Tuple[Set[str], Set[str]]
    tool_path = runfiles.data_path("@dbx_build_tools//build_tools/bzl_lib/parse_py_imports_py3")
    args = [tool_path, workspace_dir, src]
    output = subprocess.check_output(args)
    results = json.loads(output)
    import_set = set(results["import_set"])
    from_set = set(results["from_set"])
    return import_set, from_set
