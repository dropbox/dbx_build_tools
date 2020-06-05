# mypy: allow-untyped-defs

from __future__ import print_function

import argparse
import os
import subprocess
import sys

from argparse import _SubParsersAction, ArgumentParser
from typing import Tuple

from build_tools import bazel_utils
from build_tools.bazel_utils import build_tool, find_workspace
from build_tools.bzl_lib import exec_wrapper, metrics
from build_tools.bzl_lib.commands import bazel_modes
from build_tools.bzl_lib.itest import itest

DEFAULT_DOCKER_REGISTRY = "docker.io"
def create_parser():
    # type: () -> Tuple[ArgumentParser, _SubParsersAction]
    metrics.set_mode("_bzl_parse_args")
    ap = argparse.ArgumentParser(
        "bzl", epilog=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--bazel-path", default="bazel")
    ap.add_argument("--docker-path", default="/usr/bin/docker")
    ap.add_argument("--fpm-path", default="fpm")
    ap.add_argument("--git-path", default="git")
    ap.add_argument(
        "--build-image",
        default="",
        help="specify a docker image to use for all commands: "
        "build_tools/docker/drbe-v1 build_tools/docker/isotester-base",
    )
    ap.add_argument(
        "--docker-registry",
        default=DEFAULT_DOCKER_REGISTRY,
        help="A default docker registry to be prepended to unqualified image names",
    )
    ap.add_argument(
        "--skip-version-check",
        action="store_true",
        help="When true, skip checking bzl package versions",
    )
    sp = ap.add_subparsers(dest="mode", metavar="")

    return ap, sp


global_bazel_flags = (
    "--host_jvm_debug",
    "--nohost_jvm_debug",
    "--master_blazerc",
    "--nomaster_blazerc",
    "--master_bazelrc",
    "--nomaster_bazelrc",
    "--batch",
    "--batch_cpu_scheduling",
    "--block_for_lock",
    "--deep_execroot",
    "--nobatch",
    "--nobatch_cpu_scheduling",
    "--noblock_for_lock",
    "--nodeep_execroot",
)


global_bazel_args = (
    "--host_jvm_args",
    "--host_jvm_profile",
    "--blazerc",
    "--bazelrc",
    "--io_nice_level",
    "--max_idle_secs",
    "--output_base",
    "--output_user_root",
)


# Extract the mode from argv. This is a best-guess and there may be
# some edge cases if something very complex is passed in.
# Return (global args, mode args)
def parse_bazel_args(argv):
    global_args = []
    mode_args = []

    argiter = iter(argv)
    for x in argiter:
        if x in global_bazel_flags:
            global_args.append(x)
        elif x.startswith(global_bazel_args):
            global_args.append(x)
            if "=" not in x:
                global_args.append(next(argiter))
        else:
            mode_args.append(x)
    return (global_args, mode_args)


# A macro to rebuild and run an internal tool.  If the rebuild fails,
# just continue running the current version of the tool you have.
def run_build_tool(bazel_path, target, targets, squelch_output=False):
    workspace = find_workspace()
    if not workspace:
        return
    try:
        # If we can bootstrap a new version, do it once.
        with metrics.create_and_register_timer("bzl_bootstrap_ms") as t:
            bzl_script = build_tool(
                bazel_path, target, targets, squelch_output=squelch_output
            )
        bzl_script_path = os.path.join(workspace, bzl_script)
        argv = [bzl_script_path] + list(sys.argv[1:])
        os.environ["BZL_SKIP_BOOTSTRAP"] = "1"
        os.environ["BZL_BOOTSTRAP_MS"] = str(t.get_interval_ms())
        os.environ["BZL_RUNNING_REBUILT_BZL"] = "1"
        exec_wrapper.execv(bzl_script_path, argv)
    except subprocess.CalledProcessError:
        print(
            "WARN: Failed to build %s, continuing without self-update." % target,
            file=sys.stderr,
        )
        # If something goes wrong during rebuild, just run this version.
        pass
def main(ap, self_target):
    try:
        workspace = bazel_utils.find_workspace()
    except bazel_utils.BazelError as e:
        sys.exit("Bazel Error: {}".format(e))

    test_args = None
    try:
        # Hedge that we might not need to rebuild and exec. If for any
        # reason this fails, fall back to correct behavior.
        stdout, stderr = sys.stdout, sys.stderr
        with open("/dev/null", "w") as devnull:
            sys.stdout, sys.stderr = devnull, devnull
            test_args, unknown_args = ap.parse_known_args()
        # No built-in Bazel mode requires bzl to be up-to-date.
        rebuild_and_exec = test_args.mode not in bazel_modes
    except (SystemExit, AttributeError):
        rebuild_and_exec = True
    finally:
        sys.stdout, sys.stderr = stdout, stderr

    if os.environ.get("BZL_SKIP_BOOTSTRAP"):
        rebuild_and_exec = False
        # Propagate stats forward so we can sort of track the full metrics of itest.
        bootstrap_ms = int(os.environ.get("BZL_BOOTSTRAP_MS", 0))
        metrics.create_and_register_timer("bzl_bootstrap_ms", interval_ms=bootstrap_ms)
    if rebuild_and_exec:
        metrics.set_mode("_bzl_bootstrap")
        # If the tool requires an update, build it and re-exec.  Do this before we parse args in
        # case we have defined a newer mode.
        targets = []
        # Pass in targets that we are going to build. On average this minimizes target flapping
        # within bazel and saves time on small incremental updates without sacrificing correct
        # behavior.
        # do this for some itest modes and if there are no unknown args (as those can be
        # bazel flags that causes worse build flapping)
        if (
            test_args
            and test_args.mode in ("itest-run", "itest-start", "itest-reload")
            and not unknown_args
        ):
            targets.append(itest.SVCCTL_TARGET)
            targets.append(test_args.target)
        # also do this for tool modes, so we can avoid an extra bazel build
        if test_args and test_args.mode in ("tool", "fmt"):
            targets.append(test_args.target)
        squelch_output = test_args and test_args.mode in ("tool", "go", "go-env")
        run_build_tool(
            os.environ.get("BAZEL_PATH_FOR_BZL_REBUILD", "bazel"),
            self_target,
            targets,
            squelch_output=squelch_output,
        )

    args, remaining_args = ap.parse_known_args()
    metrics.set_mode(args.mode)
    subparser_map = ap._subparsers._group_actions[0].choices
    if remaining_args and (
        args.mode is None
        or not getattr(subparser_map[args.mode], "bzl_allow_unknown_args", False)
    ):
        print(
            f"ERROR: unknown args for mode {args.mode}: {remaining_args}",
            file=sys.stderr,
        )
        sys.exit(2)

    bazel_args, mode_args = parse_bazel_args(remaining_args)
    if args.mode in (None, "help"):
        if not mode_args:
            ap.print_help()
            print()
        elif len(mode_args) == 1 and mode_args[0] not in bazel_modes:
            help_mode_parser = subparser_map[mode_args[0]]
            help_mode_parser.print_help()
        sys.stdout.flush()
        sys.exit(1 if args.mode is None else 0)

    if args.build_image and not args.build_image.startswith(args.docker_registry):
        args.build_image = os.path.join(args.docker_registry, args.build_image)

    try:
        if hasattr(args, "targets"):
            targets = args.targets
            require_build_file = not getattr(args, "missing_build_file_ok", False)

            targets = bazel_utils.expand_bazel_targets(
                workspace, targets, require_build_file=require_build_file
            )

            if not targets:
                sys.exit("No targets specified.")
            args.targets = targets

        args.func(args, bazel_args, mode_args)
    except bazel_utils.BazelError as e:
        if os.environ.get("BZL_DEBUG"):
            raise
        sys.exit("ERROR: " + str(e))
    except subprocess.CalledProcessError as e:
        print(e, file=sys.stderr)
        if e.output:
            print(e.output, file=sys.stderr)
        if os.environ.get("BZL_DEBUG"):
            raise
        sys.exit(e.returncode)
    except KeyboardInterrupt:
        sys.exit("ERROR: interrupted")
