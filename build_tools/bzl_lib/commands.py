# mypy: allow-untyped-defs

import os

import build_tools.bazel_utils as bazel_utils
import build_tools.bzl_lib.exec_wrapper as exec_wrapper

bazel_modes = (
    "analyze-profile",
    "aquery",
    "build",
    "canonicalize-flags",
    "clean",
    "coverage",
    "cquery",
    "dump",
    "fetch",
    "help",
    "info",
    "mobile-install",
    "print_action",
    "query",
    "run",
    "shutdown",
    "test",
    "version",
)


def cmd_bazel(args, bazel_args, mode_args):
    exec_wrapper.execv(
        args.bazel_path, [args.bazel_path] + bazel_args + [args.mode] + mode_args
    )


def register_cmd_bazel(sp):
    for mode in bazel_modes:
        sap = sp.add_parser(mode, add_help=False)
        sap.set_defaults(func=cmd_bazel)
        sap.bzl_allow_unknown_args = True


def cmd_gen_as_tool(args, bazel_args, mode_args):
    workspace_dir = bazel_utils.find_workspace()
    bzl_gen = bazel_utils.build_tool(args.bazel_path, "@dbx_build_tools//build_tools:bzl-gen")
    bzl_gen_path = os.path.join(workspace_dir, bzl_gen)
    argv = [os.path.basename(bzl_gen_path)] + mode_args
    exec_wrapper.execv(bzl_gen_path, argv)


def register_cmd_gen(sp):
    sap = sp.add_parser(
        "gen",
        add_help=False,
        help="Generate a BUILD file or proto files for a list of targets.",
    )
    sap.bzl_allow_unknown_args = True
    sap.set_defaults(func=cmd_gen_as_tool, missing_build_file_ok=True)
