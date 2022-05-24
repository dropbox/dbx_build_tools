__doc__ = """bzl is a small wrapper for adding Dropbox-specific functionality on top of Bazel.

Setting the environment variable BZL_DEBUG=1 yields additional debug info.
"""

import os

from build_tools.bzl_lib import commands, core, metrics
from build_tools.bzl_lib.itest import itest


def main() -> None:
    ap, sp = core.create_parser()

    commands.register_cmd_bazel(sp)
    commands.register_cmd_gen(sp)
    itest.register_cmd_itest(sp)
    core.main(ap, "@dbx_build_tools//build_tools:bzl")


if __name__ == "__main__":
    with metrics.main_metrics_scope():
        main()
