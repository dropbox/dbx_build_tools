from __future__ import annotations
from __future__ import print_function

import itertools
import subprocess
import sys

from typing import Iterable, Sequence, Tuple, TypeVar

from dropbox import runfiles

MAXIMUM_BATCH_SIZE = 1000

_T = TypeVar("_T")


def _chunk(iterable: Iterable[_T], chunk_size: int) -> Iterable[Sequence[_T]]:
    grouped = itertools.groupby(enumerate(iterable), lambda v: v[0] // chunk_size)
    return ([elem for ix, elem in group] for i, group in grouped)


def merge_build_files(new_build_filename: str, annotation_build_filename: str, output_filename: str) -> None:
    batch_merge_build_files(
        [(new_build_filename, annotation_build_filename, output_filename)]
    )


def batch_merge_build_files(file_list: Sequence[Tuple[str, str, str]]) -> None:
    tool_path = runfiles.data_path(
        "@dbx_build_tools//go/src/dropbox/build_tools/build-merge/build-merge"
    )

    for file_batch in _chunk(file_list, MAXIMUM_BATCH_SIZE):
        args = [tool_path]
        for op in file_batch:
            args.extend(op)

        try:
            output = subprocess.check_output(args)
        except subprocess.CalledProcessError as e:
            print("Command failed:", args, file=sys.stderr)
            print(e.output, file=sys.stderr)
            sys.exit(1)

        output = output.strip()
        if output:
            print(output)
