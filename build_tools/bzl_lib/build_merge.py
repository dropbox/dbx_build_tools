from __future__ import print_function

import subprocess
import sys

from dropbox import runfiles


def merge_build_files(new_build_filename, annotation_build_filename, output_filename):
    # type: (str, str, str) -> None

    tool_path = runfiles.data_path(
        "@dbx_build_tools//go/src/dropbox/build_tools/build-merge/build-merge"
    )

    args = [tool_path, new_build_filename, annotation_build_filename, output_filename]

    try:
        output = subprocess.check_output(args)
    except subprocess.CalledProcessError as e:
        print("Command failed:", args, file=sys.stderr)
        print(e.output, file=sys.stderr)
        sys.exit(1)

    output = output.strip()
    if output:
        print(output)
