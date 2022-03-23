# mypy: allow-untyped-defs

"""bzl-gen is a small wrapper for adding Dropbox-specific functionality on top of Bazel.

Setting the environment variable BZL_DEBUG=1 yields additional debug info.
"""

from __future__ import absolute_import, annotations, print_function

import argparse
import functools
import os
import subprocess
import sys
import traceback

from typing import Callable, List, Sequence

from build_tools import bazel_utils
from build_tools.bzl_lib import gazel, gen_build_go, gen_build_py, metrics
from build_tools.bzl_lib.gen_commands import register_cmd_gen
from build_tools.bzl_lib.generator import Generator
def get_generators() -> Sequence[Callable[..., Generator]]:
    generators: List[Callable[..., Generator]] = [
        gen_build_go.GoBuildGenerator,
        gen_build_py.PyBuildGenerator,
        gazel.CopyGenerator,
    ]
    return generators


def main() -> None:
    ap = argparse.ArgumentParser(
        "bzl-gen", epilog=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    register_cmd_gen(None, get_generators(), sap=ap)

    args = ap.parse_args()

    workspace = bazel_utils.find_workspace()
    if not workspace:
        sys.exit("Run from a Bazel WORKSPACE.")
    try:
        if hasattr(args, "targets"):
            targets = args.targets
            require_build_file = not getattr(args, "missing_build_file_ok", False)

            targets = bazel_utils.expand_bazel_targets(
                workspace,
                targets,
                require_build_file=require_build_file,
                allow_nonexistent_npm_folders=True,
            )

            if not targets:
                sys.exit("No targets specified.")
            args.targets = targets

        args.func(args, (), ())
    except bazel_utils.BazelError as e:
        if os.environ.get("BZL_DEBUG"):
            raise
        sys.exit("ERROR: " + str(e))
    except subprocess.CalledProcessError as e:
        traceback.print_exc(file=sys.stderr)
        if e.output:
            print(e.output.decode("utf-8"), file=sys.stderr)
        if os.environ.get("BZL_DEBUG"):
            raise
        sys.exit(e.returncode)
    except KeyboardInterrupt:
        sys.exit("ERROR: interrupted")


if __name__ == "__main__":
    metrics.set_mode("bzl-gen")
    with metrics.main_metrics_scope():
        main()
