# mypy: allow-untyped-defs

import argparse
import multiprocessing
import os
import pipes
import subprocess
import sys

from build_tools import bazel_utils
from build_tools.bzl_lib import exec_wrapper, metrics
from build_tools.bzl_lib.itest import bash_history

from dropbox import runfiles

HOST_DATA_DIR_PREFIX = os.path.expanduser("~/bzl/itest/per-container")
HOST_HOME_DIR = os.path.expanduser("~/bzl/itest/root")
IN_CONTAINER_DATA_DIR = "/bzl/itest/per-container"
IN_CONTAINER_HOME_DIR = "/bzl/itest/root"
RUN_TEST_BIN_NAME = "run-test"
SVCCTL_RESTART_OUTPUT_FILE = "svcctl-restart-output"

CONTAINER_NAME_PREFIX = "bzl-itest_"
POSSIBLE_CONTAINER_NAME_PREFIXES = ("bzl-develop_", CONTAINER_NAME_PREFIX)
SVCCTL_TARGET = "@dbx_build_tools//go/src/dropbox/build_tools/svcctl/cmd/svcctl"

DEFAULT_IMAGE = "ubuntu:19.10"
# NOTE: Must be kept up-to-date with the path in rSERVER/dropbox/provost/socket_util.py
DEFAULT_SOCKET_DIRECTORY_PATH = "/run/dropbox/sock-drawer/"


class ITestTarget(object):
    """
    A target that is the object of `bzl itest`. This must be either a test target
    or a service target.
    """

    def __init__(self, name, has_services):
        self.name = name
        self.has_services = has_services

        self.executable_path = os.path.join(
            bazel_utils.find_workspace(), bazel_utils.executable_for_label(self.name)
        )

        if self.has_services:
            self.service_launch_cmd = [self.executable_path]
            self.test_cmd = self.service_launch_cmd + [" --svc.test-only"]
        else:
            self.service_launch_cmd = ["/bin/true"]
            self.test_cmd = [self.executable_path]


def _get_itest_target_body_by_bazel_query(bazel_path, target):
    targets = bazel_utils.targets_of_kinds_for_labels_xml(
        bazel_path,
        kinds=["service_internal", "service_group_internal", "services_internal_test"],
        labels=[
            target,
            "labels(tests, {})".format(target),  # to handle testsuite used in Go
        ],
    ).getElementsByTagName("rule")

    if len(targets) == 1:
        name = targets[0].getAttribute("name")
        return ITestTarget(name=name, has_services=True)
    elif len(targets) == 0:
        names = [t.getAttribute("name") for t in targets]
        # maybe we were given a test target that does not have a service dependency
        maybe_test_targets = bazel_utils.test_targets_for_labels(
            bazel_path, labels=[target]
        )
        if len(maybe_test_targets) == 1:
            return ITestTarget(name=maybe_test_targets[0], has_services=False)
        else:
            raise bazel_utils.BazelError(
                "Please specify exactly one service target or one test target. Specified label expanded to service targets {!r} and test targets {!r}".format(
                    names, maybe_test_targets
                )
            )
    else:
        names = [t.getAttribute("name") for t in targets]
        raise bazel_utils.BazelError(
            "Please specify exactly one service target or one test target. Specified label expanded to service targets {!r}".format(
                names
            )
        )


def _get_itest_target_body(bazel_path, target, use_implicit_output):
    if not use_implicit_output:
        return _get_itest_target_body_by_bazel_query(bazel_path, target)
    workspace = bazel_utils.find_workspace()

    rel_target_path = bazel_utils.executable_for_label(target)
    potential_target_path = os.path.join(workspace, rel_target_path)
    if not os.path.exists(potential_target_path):
        # if the expected binary does not exist, this may be a glob or an alias.
        # use bazel query to be sure.
        return _get_itest_target_body_by_bazel_query(bazel_path, target)

    # check if this target has services
    service_defs = os.path.join(
        potential_target_path + ".runfiles/__main__",
        os.path.relpath(rel_target_path, "bazel-bin") + ".service_defs",
    )
    if not os.path.exists(service_defs):
        # most likely doesn't have services. but just to be safe and very correct,
        # use bazel query
        # TODO(naphat) the only thing this bazel query protects against is some internal runfiles
        # structure in svc.bzl changing without this code being updated. do we need it?
        return _get_itest_target_body_by_bazel_query(bazel_path, target)
    # now that we know the given target is of a specific format (no aliases),
    # we can safely normalize the target name
    target = bazel_utils.BazelTarget(target).label
    return ITestTarget(name=target, has_services=True)


def _get_itest_target(bazel_path, target, use_implicit_output=False):
    """
    Turn a target pattern into a ITestTarget object.

    If `bazel build` was called on the target before this function, then pass use_implicit_output=True
    to turn on some heuristics to avoid using `bazel query`.
    """
    with metrics.create_and_register_timer("bazel_query_ms"):
        itest_target = _get_itest_target_body(
            bazel_path, target, use_implicit_output=use_implicit_output
        )
    metrics.set_extra_attributes("target", itest_target.name)
    if itest_target.has_services:
        metrics.set_extra_attributes("has_services", "true")
    else:
        metrics.set_extra_attributes("has_services", "false")
    return itest_target


def _build_target(args, bazel_args, mode_args, target):
    with metrics.create_and_register_timer("bazel_build_ms"):
        cmd = (
            [args.bazel_path]
            + bazel_args
            + ["build"]
            + mode_args
            + ["@dbx_build_tools//build_tools:bzl", SVCCTL_TARGET, target]
        )
        if os.environ.get("BZL_BOOTSTRAP_BUILD") == " ".join(cmd[1:]):
            # If an exact match normalized command was executed as part of bootstrap we can skip
            # this no-op build.  This is fragile, so don't do anything foolhardy like reordering
            # or tweaking any cmd args above without investigating the self-build code in bzl.py.
            return
        if os.environ.get("BZL_DEBUG"):
            print >> sys.stderr, "exec:", " ".join(cmd)
        subprocess.check_call(cmd)


def register_cmd_itest(subparsers):
    for command_name in ["itest-run", "itest-start"]:
        if command_name == "itest-run":
            help_text = "Launch Bazel services in a container. Drop into the container services start."
        else:
            help_text = "Launch Bazel services in a container. Do NOT drop into the container services start."
        sap = subparsers.add_parser(command_name, help=help_text)
        sap.add_argument("target", help="A service or test target")
        sap.add_argument("-v", "--verbose", action="store_true")
        # don't document --allow-multiple-containers, there is almost ~no valid use case for it
        sap.add_argument(
            "-m",
            "--allow-multiple-containers",
            action="store_true",
            help=argparse.SUPPRESS,
        )
        sap.add_argument(
            "--privileged",
            action="store_true",
            help="Run a privileged docker container. Useful for mounting sqfs, etc.",
        )
        sap.add_argument(
            "--persist-tmpdir",
            action="store_true",
            help="Do not wipe TEST_TMPDIR on service start. This will use a different location on the host machine to store TEST_TMPDIR than the default mode.",
        )
        if command_name == "itest-run":
            sap.set_defaults(detach=False)
        else:
            sap.set_defaults(detach=True)
        sap.add_argument(
            "--test_arg",
            action="append",
            default=[],
            help="If called on a test target, pass extra arguments to the test runner.",
        )
        sap.bzl_allow_unknown_args = True
        sap.set_defaults(func=cmd_itest_run)

    sap = subparsers.add_parser(
        "itest-clean", help="Remove data directory associated with this target."
    )
    sap.add_argument("target", help="A service or test target")
    sap.add_argument(
        "--expunge",
        action="store_true",
        help="Delete persistent_test_tmpdir contents -- may cause *permanent* data loss.",
    )
    sap.add_argument(
        "-f",
        "--force",
        action="store_true",
        help="Remove data directory without prompting.",
    )
    sap.set_defaults(func=cmd_itest_clean)

    sap = subparsers.add_parser(
        "itest-clean-all", help="Remove storage for all stopped `bzl itest` containers."
    )
    sap.add_argument(
        "--expunge",
        action="store_true",
        help="Delete persistent_test_tmpdir contents -- may cause *permanent* data loss.",
    )
    sap.add_argument(
        "-f",
        "--force",
        action="store_true",
        help="Remove data directories without prompting.",
    )
    sap.set_defaults(func=cmd_itest_clean_all)

    sap = subparsers.add_parser(
        "itest-exec", help="Execute an arbitrary command inside the docker container."
    )
    sap.add_argument("target", help="A service or test target")
    sap.add_argument("cmd", nargs="+", help="The command to run in the container.")
    sap.set_defaults(func=cmd_itest_exec)

    sap = subparsers.add_parser(
        "itest-reload",
        help="Rebuild and reload any services. Also rerun the test if this is a test target.",
    )
    sap.add_argument("target", help="A service or test target")
    sap.add_argument("-v", "--verbose", action="store_true")
    sap.add_argument(
        "--test_arg",
        action="append",
        default=[],
        help="If called on a test target, pass extra arguments to the test runner.",
    )
    sap.bzl_allow_unknown_args = True
    sap.set_defaults(func=cmd_itest_reload)

    sap = subparsers.add_parser(
        "itest-reload-current",
        help="Rebuild, reload and rerun any services/tests for the currently running itest container.",
    )
    sap.add_argument("-v", "--verbose", action="store_true")
    sap.add_argument(
        "--test_arg",
        action="append",
        default=[],
        help="If called on a test target, pass extra arguments to the test runner.",
    )
    sap.bzl_allow_unknown_args = True
    sap.set_defaults(func=cmd_itest_reload_current)

    sap = subparsers.add_parser(
        "itest-stop", help="Stop and remove the docker container for this target."
    )
    sap.add_argument("target", help="A service or test target")
    sap.set_defaults(func=cmd_itest_stop)

    sap = subparsers.add_parser(
        "itest-stop-all", help="Stop and remove all `bzl itest` containers."
    )
    sap.add_argument(
        "-f",
        "--force",
        action="store_true",
        dest="force",
        help="Stop containers without prompting.",
    )
    sap.set_defaults(func=cmd_itest_stop_all)


def _get_container_name_for_target(target):
    return CONTAINER_NAME_PREFIX + target.strip("/").replace("/", "-").replace(":", "-")


def _get_all_containers(docker_path):
    return [x[0] for x in _get_all_containers_targets(docker_path)]


def _get_all_containers_targets(docker_path):
    """
    Retrieve (container_name, target) tuples.
    """
    containers_targets = []
    args = [
        docker_path,
        "ps",
        "--all",
        "--format",
        '{{.Names}} {{.Label "itest-target"}}',
    ]
    for line in subprocess.check_output(args).strip().split("\n"):
        if line.startswith(POSSIBLE_CONTAINER_NAME_PREFIXES):
            fields = line.split()
            if len(fields) == 2:
                containers_targets.append(tuple(fields))
    return containers_targets


def _raise_on_glob_target(target):
    if target.endswith(("...", ":all", ":*", ":all-targets")):
        raise bazel_utils.BazelError(
            "Globs are not supported. Please specify explicit target path."
        )


def _verify_args(args, itest_target, container_should_be_running):
    """
    Verify that the command the user requested is valid before continuing.
    This checks that valid combination of flags are passed, and that
    a `bzl itest` container already exists (or doesn't), based on
    the mode requested.
    """
    with metrics.create_and_register_timer("verify_args_ms"):
        container_name = _get_container_name_for_target(itest_target.name)

        # Load all containers because you want neither port nor container name conflicts.
        # note: this shells out to docker so it's potentially slow
        existing_containers = _get_all_containers(args.docker_path)
        container_running = container_name in existing_containers
        error_info = dict(name=container_name, target=itest_target.name)
        if existing_containers and not container_should_be_running:
            if not args.allow_multiple_containers:
                # if the only container running is the container for this target, then we are ok
                # here and handle the error better below.
                if not container_running or len(existing_containers) > 1:
                    message = """There are existing docker containers. Please run:

Stop all `bzl itest` containers:
bzl itest-stop-all"""
                    sys.exit(message)
        if container_running and not container_should_be_running:
            message = """Container {name} already exists. Try one of the following:

Rebuild and restart any changed services:
bzl itest-reload {target}

Get a shell into the container:
bzl itest-exec {target} /bin/bash

Stop and remove this container:
bzl itest-stop {target}""".format(
                **error_info
            )
            sys.exit(message)
        elif not container_running and container_should_be_running:
            if existing_containers:
                message = """A `bzl itest` container must already be running for target {target}. Additionally, there are existing `bzl itest` containers.
Try running the following to remove all containers and start a new container for {target}:

bzl itest-stop-all && bzl itest-run {target}""".format(
                    target=itest_target.name
                )
                sys.exit(message)
            else:
                message = """A `bzl itest` container must already be running for target {target}.
Try running `bzl itest-run {target}` instead.""".format(
                    target=itest_target.name
                )
                sys.exit(message)

        if os.path.exists("/etc/devbox-release"):
            # on devbox
            if multiprocessing.cpu_count() < 4 and itest_target.name.startswith(
                ("//services/metaserver", "//paper/services")
            ):
                sys.exit(
                    """This Devbox is an infra-sized instance not meant for metaserver or Paper development.

Please see https://app.dropboxer.net/docs/devbox/devbox_self-serve#recreate_instance-upgrade_instance for upgrade instructions."""
                )


def _guess_mem_limit_kb():
    min_limit_kb = 8e6
    # Try to guess a reasonable limit based on the machine.
    with open("/proc/meminfo") as f:
        # MemTotal:       16424356 kB
        for line in f:
            fields = line.strip().split()
            if fields[0] == "MemTotal:":
                mem_total_kb = int(fields[1])
                # Reserve 6GB for OS + Bazel + Cache
                mem_limit_kb = mem_total_kb - 6e6
                if mem_total_kb < min_limit_kb:
                    mem_limit_kb = min_limit_kb
                return mem_limit_kb
    return min_limit_kb


def cmd_itest_run(args, bazel_args, mode_args):
    _raise_on_glob_target(args.target)
    _build_target(args, bazel_args, mode_args, args.target)
    itest_target = _get_itest_target(
        args.bazel_path, args.target, use_implicit_output=True
    )
    container_name = _get_container_name_for_target(itest_target.name)
    _verify_args(args, itest_target, container_should_be_running=False)

    tmpdir_name = "test_tmpdir"
    if args.persist_tmpdir:
        tmpdir_name = "persistent_test_tmpdir"
    host_data_dir = os.path.join(HOST_DATA_DIR_PREFIX, container_name)
    host_tmpdir = os.path.join(host_data_dir, tmpdir_name)
    for dirname in [host_tmpdir, HOST_HOME_DIR]:
        if not os.path.exists(dirname):
            os.makedirs(dirname)
    container_tmpdir = os.path.join(IN_CONTAINER_DATA_DIR, tmpdir_name)

    workspace = bazel_utils.find_workspace()
    cwd = workspace

    # order matters here. The last command shows up as the last thing the user ran, i.e.
    # the first command they see when they hit "up"
    history_cmds = []  # type: ignore[var-annotated]
    if itest_target.has_services:
        history_cmds = [
            "svcctl --help",
            "svcctl status",
            'svcctl status -format "{{.CPUTime}} {{.Name}}" | sort -rgb | head',
        ]
    test_bin = os.path.join(host_data_dir, RUN_TEST_BIN_NAME)
    with open(test_bin, "w") as f:
        f.write(
            """#!/bin/bash -eu
cd {cwd}
exec {test} "$@"
""".format(
                cwd=itest_target.executable_path + ".runfiles/__main__",
                test=" ".join(itest_target.test_cmd),
            )
        )
    os.chmod(test_bin, 0755)
    test_cmd_str = " ".join(
        pipes.quote(x)
        for x in [os.path.join(IN_CONTAINER_DATA_DIR, RUN_TEST_BIN_NAME)]
        + args.test_arg
    )
    history_cmds.append(test_cmd_str)

    launch_cmd = itest_target.service_launch_cmd
    if args.verbose:
        launch_cmd += ["--svc.verbose"]

    default_paths = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin".split(
        ":"
    )
    itest_paths = [
        os.path.join(
            workspace, os.path.dirname(bazel_utils.executable_for_label(SVCCTL_TARGET))
        ),
        os.path.join(workspace, "build_tools/itest"),
    ]
    env = {
        "DROPBOX_SERVER_TEST": "1",
        "PATH": ":".join(itest_paths + default_paths),
        "TEST_TMPDIR": container_tmpdir,
        "HOST_TEST_TMPDIR": host_tmpdir,
        "HOME": IN_CONTAINER_HOME_DIR,  # override HOME since we can't readily edit /etc/passwd
        "LAUNCH_CMD": " ".join(launch_cmd),
        "TEST_CMD": test_cmd_str,
        # Set how much directory to clean up on startup. Pass this into the container so it gets
        # cleaned up as root.
        "CLEANDIR": os.path.join(container_tmpdir, "logs")
        if args.persist_tmpdir
        else container_tmpdir,
    }

    history_file = os.path.join(HOST_HOME_DIR, ".bash_history")
    bash_history.merge_history([history_file], history_cmds, history_file)
    bashrc_file_src = runfiles.data_path("@dbx_build_tools//build_tools/bzl_lib/itest/bashrc")

    if args.build_image:
        docker_image = args.build_image
    else:
        docker_image = os.path.join(args.docker_registry, DEFAULT_IMAGE)

    init_cmd_args = [runfiles.data_path("@dbx_build_tools//build_tools/bzl_lib/itest/bzl-itest-init")]

    # Set a fail-safe limit for an itest container to keep it from detonating the whole
    # machine.  RSS limits are a funny thing in docker. Most likely the oom-killer will
    # start killing things inside the container rendering it unstable.
    # FIXME(msolo) It would be nice to teardown the container on out-of-memory and leave
    # some sort of note.
    mem_limit_kb = _guess_mem_limit_kb()
    docker_run_args = [
        args.docker_path,
        "run",
        "--net=host",
        "--name",
        container_name,
        "--workdir",
        cwd,
        "--detach",
        "--memory",
        "%dK" % mem_limit_kb,
        # Swap is disabled anyway, so squelch a spurious warning.
        "--memory-swap",
        "-1",
        # Store target name in config, to be able to reload it later.
        "--label",
        "itest-target=%s" % args.target,
    ]

    if args.privileged:
        docker_run_args += ["--privileged"]

    # set env variables. This will also set it for subsequent `docker exec` commands
    for k, v in env.iteritems():
        docker_run_args += ["-e", "{}={}".format(k, v)]

    with metrics.create_and_register_timer("bazel_info_ms"):
        with open(os.devnull, "w") as dev_null:
            output_base = subprocess.check_output(
                [args.bazel_path, "info", "output_base"], stderr=dev_null
            ).strip()
            install_base = subprocess.check_output(
                [args.bazel_path, "info", "install_base"], stderr=dev_null
            ).strip()

    mounts = [
        (workspace, "ro"),
        ("/sqpkg", "ro"),
        (output_base, "ro"),
        (install_base, "ro"),
        ("/etc/ssl", "ro"),
        ("/usr/share/ca-certificates", "ro"),
        # We bind mount /run/dropbox/sock-drawer/ as read-write so that services outside
        # itest (ie ULXC jails) can publish sockets here that can be used from the inside
        # (bind mount), and so that services inside itest (ie RivieraFS) can publish
        # sockets here (read-write) that can be used from the outside
        (DEFAULT_SOCKET_DIRECTORY_PATH, "rw"),
    ]

    for path, perms in mounts:
        # Docker will happily create a mount source that is nonexistent, but it may not have the
        # right permissions.  Better to just mount nothing.
        if not os.path.exists(path):
            print >> sys.stderr, "missing mount point:", path
            continue
        src = os.path.realpath(path)
        docker_run_args += ["-v", "{}:{}:{}".format(src, path, perms)]
    # Allow bzl itest containers to observe external changes to the mount table.
    if os.path.exists("/mnt/sqpkg"):
        docker_run_args += ["-v", "/mnt/sqpkg:/mnt/sqpkg:rslave"]
    if sys.stdin.isatty():
        # otherwise text wrapping on subsequent shells is messed up
        docker_run_args += ["--tty"]

    docker_run_args += ["-v", "{}:{}:rw".format(host_data_dir, IN_CONTAINER_DATA_DIR)]
    docker_run_args += ["-v", "{}:{}:rw".format(HOST_HOME_DIR, IN_CONTAINER_HOME_DIR)]
    docker_run_args += ["-v", "{}:{}:ro".format(bashrc_file_src, "/etc/bash.bashrc")]

    docker_run_args += [docker_image]
    docker_run_args += init_cmd_args

    with metrics.create_and_register_timer("services_start_ms"):
        with open(os.devnull, "w") as f:
            subprocess.check_call(docker_run_args, stdout=f)

        docker_exec_args = [args.docker_path, "exec"]
        if sys.stdin.isatty():
            docker_exec_args += ["--interactive", "--tty"]
        docker_exec_args += [container_name]
        exit_code = subprocess.call(
            docker_exec_args
            + [runfiles.data_path("@dbx_build_tools//build_tools/bzl_lib/itest/bzl-itest-wait")]
        )

    if exit_code == 0:
        # run the test command
        with metrics.create_and_register_timer("test_ms"):
            # NOT check_call. Even if this script doesn't exit with 0 (e.g. test fails),
            # we want to keep going
            subprocess.call(docker_exec_args + ["/bin/bash", "-c", test_cmd_str])

    if itest_target.has_services:
        services_started = (
            subprocess.check_output(
                [
                    args.docker_path,
                    "exec",
                    container_name,
                    "svcctl",
                    "status",
                    "--all",
                    "--format={{.Name}}",
                ]
            )
            .strip()
            .split("\n")
        )
        metrics.set_extra_attributes("services_started", ",".join(services_started))
        metrics.set_gauge("services_started_count", len(services_started))

    # report metrics now, instead of after the interactive session since
    # we don't want to measure that
    metrics.report_metrics()

    if args.detach:
        # display message of the day then exit
        exec_wrapper.execv(args.docker_path, docker_exec_args + ["cat", "/etc/motd"])
    else:
        exit_code = subprocess.call(docker_exec_args + ["/bin/bash"])
        with open(os.devnull, "w") as devnull:
            subprocess.check_call(
                [args.docker_path, "rm", "-f", container_name],
                stdout=devnull,
                stderr=devnull,
            )
        sys.exit(exit_code)


def _confirm_directory_delete(dirname):
    reply = raw_input(
        "Deleting data directory at {}\n  This will cause PERMANENT data loss. Continue? [y/N] ".format(
            dirname
        )
    )
    return reply.strip().lower() in ("y", "yes")


def _should_remove_container_dir(args, container_dirpath):
    persistent_dir = os.path.join(container_dirpath, "persistent_test_tmpdir")
    if os.path.exists(persistent_dir):
        # If there is persistent data ignore the whole directory unless expunge is requested.
        # If we are expunging, assume the worst and ask for confirmation.
        return bool(
            args.expunge
            and (args.force or _confirm_directory_delete(container_dirpath))
        )
    return True


def cmd_itest_clean(args, bazel_args, mode_args):
    _raise_on_glob_target(args.target)
    itest_target = _get_itest_target(args.bazel_path, args.target)
    container_name = _get_container_name_for_target(itest_target.name)
    containers = _get_all_containers(args.docker_path)
    if container_name in containers:
        message = """Refusing to remove data directory because container {name} is still running. Try:

Stop and remove this container:
bzl itest-stop {target}""".format(
            name=container_name, target=itest_target.name
        )
        sys.exit(message)
    host_data_dir = os.path.join(HOST_DATA_DIR_PREFIX, container_name)
    if not os.path.exists(host_data_dir):
        sys.exit("Data directory {} does not exist".format(host_data_dir))
    if _should_remove_container_dir(args, host_data_dir):
        exec_wrapper.execv(
            "/usr/bin/sudo", ["/usr/bin/sudo", "rm", "-rf", host_data_dir]
        )
    else:
        print >> sys.stderr, "WARN: Skipping containers with persistent data", host_data_dir
        print >> sys.stderr, "  bzl itest-clean --expunge %s - remove persistent data" % args.target


def cmd_itest_clean_all(args, bazel_args, mode_args):
    # By default, clean all transient container storage.
    # If there are persistent_test_tmpdir subdirectories, show a warning.
    disk_container_names = frozenset(os.listdir(HOST_DATA_DIR_PREFIX))
    running_container_names = frozenset(_get_all_containers(args.docker_path))
    idle_container_names = disk_container_names - running_container_names

    if running_container_names:
        print >> sys.stderr, "WARN: Skipping running containers", ", ".join(
            sorted(running_container_names)
        )
        print >> sys.stderr, "  Run bzl itest-stop-all to stop all of them."

    delete_dir_list = []
    skipped_persistent_dirs = []
    for name in idle_container_names:
        host_data_dir = os.path.join(HOST_DATA_DIR_PREFIX, name)
        if _should_remove_container_dir(args, host_data_dir):
            delete_dir_list.append(host_data_dir)
        else:
            skipped_persistent_dirs.append(host_data_dir)

    if skipped_persistent_dirs:
        print >> sys.stderr, "WARN: Skipping containers with persistent data", ", ".join(
            sorted(skipped_persistent_dirs)
        )
        print >> sys.stderr, "  bzl itest-clean-all --expunge will remove persistent data."

    if delete_dir_list:
        delete_dir_list.sort()
        exec_wrapper.execv(
            "/usr/bin/sudo", ["/usr/bin/sudo", "rm", "-rf"] + delete_dir_list
        )


def cmd_itest_exec(args, bazel_args, mode_args):
    _raise_on_glob_target(args.target)
    itest_target = _get_itest_target(args.bazel_path, args.target)
    container_name = _get_container_name_for_target(itest_target.name)
    _verify_args(args, itest_target, container_should_be_running=True)

    docker_exec_args = [args.docker_path, "exec"]
    if sys.stdin.isatty():
        docker_exec_args += ["--interactive", "--tty"]
    docker_exec_args += [container_name]
    exec_wrapper.execv(args.docker_path, docker_exec_args + args.cmd)


def cmd_itest_reload_current(args, bazel_args, mode_args):
    targets = [x[1] for x in _get_all_containers_targets(args.docker_path)]
    if len(targets) > 1:
        sys.exit(
            """Found multiple running `bzl itest`.

Run `bzl itest-reload` with a specific target instead."""
        )
    elif not targets:
        sys.exit(
            """A `bzl itest` container must already be running.

Run `bzl itest-run` instead."""
        )
    args.target = targets[0]
    _cmd_itest_reload(args, bazel_args, mode_args)


def cmd_itest_reload(args, bazel_args, mode_args):
    _cmd_itest_reload(args, bazel_args, mode_args)


def _cmd_itest_reload(args, bazel_args, mode_args):
    _raise_on_glob_target(args.target)
    _build_target(args, bazel_args, mode_args, args.target)
    itest_target = _get_itest_target(
        args.bazel_path, args.target, use_implicit_output=True
    )
    container_name = _get_container_name_for_target(itest_target.name)
    _verify_args(args, itest_target, container_should_be_running=True)

    host_data_dir = os.path.join(HOST_DATA_DIR_PREFIX, container_name)
    on_host_test_binary = os.path.join(host_data_dir, RUN_TEST_BIN_NAME)
    in_container_test_binary = os.path.join(IN_CONTAINER_DATA_DIR, RUN_TEST_BIN_NAME)
    if not os.path.exists(on_host_test_binary):
        # this means that the container was started from before `bzl itest` started creating
        # a run-test script
        # TODO(naphat) remove this after 09/30
        message = """The run-test wrapper does not exist for this target, most likely because the container was creating using an old version of `bzl itest`. Please run the following to recreate the container:

bzl itest-stop {target} && bzl itest-run {target}""".format(
            target=itest_target.name
        )
        sys.exit(message)
    test_cmd_str = " ".join(
        pipes.quote(x) for x in [in_container_test_binary] + args.test_arg
    )
    service_restart_cmd_str = "/bin/true"
    if itest_target.has_services:
        service_restart_cmd_str = "svcctl auto-restart | tee {}".format(
            os.path.join(IN_CONTAINER_DATA_DIR, SVCCTL_RESTART_OUTPUT_FILE)
        )
    service_version_check_cmd_str = "/bin/true"
    if itest_target.has_services:
        service_version_check_cmd_str = "svcctl version-check"

    docker_exec_args = [args.docker_path, "exec"]
    if sys.stdin.isatty():
        docker_exec_args += ["--interactive", "--tty"]
    docker_exec_args += [container_name]
    workspace = bazel_utils.find_workspace()
    script = """
set -eu
set -o pipefail
if [[ ! -d {workspace} ]]; then
    echo 'Your current workspace ({workspace}) is not mounted into the existing `bzl itest` container. If you have multiple checkouts, are you running from the correct checkout?
If you want to terminate the current container and start a new one, try running:

bzl itest-stop {target} && bzl itest-run {target}' >&2
    exit 1
fi
if ! {service_version_check_cmd_str} >/dev/null 2>&1; then
    echo 'ERROR: Service definitions are stale or the service controller has changed. Please run the following to terminate and recreate your container:' >&2
    echo '' >&2
    echo 'bzl itest-stop {target} && bzl itest-run {target}' >&2
    exit 1
fi
{service_restart_cmd_str}
{test_cmd_str}
""".format(
        workspace=workspace,
        service_restart_cmd_str=service_restart_cmd_str,
        service_version_check_cmd_str=service_version_check_cmd_str,
        target=itest_target.name,
        test_cmd_str=test_cmd_str,
    )
    with metrics.create_and_register_timer("service_restart_ms"):
        return_code = subprocess.call(docker_exec_args + ["/bin/bash", "-c", script])
    if return_code == 0:
        if itest_target.has_services:
            services_restarted = []
            with open(
                os.path.join(host_data_dir, SVCCTL_RESTART_OUTPUT_FILE), "r"
            ) as f:
                for line in f:
                    if line.startswith("restart successful:"):
                        services_restarted.append(line.split()[-1])
            services_restarted.sort()
            metrics.set_extra_attributes(
                "services_restarted", ",".join(services_restarted)
            )
            metrics.set_gauge("services_restarted_count", len(services_restarted))
    sys.exit(return_code)


def cmd_itest_stop(args, bazel_args, mode_args):
    _raise_on_glob_target(args.target)
    itest_target = _get_itest_target(args.bazel_path, args.target)
    container_name = _get_container_name_for_target(itest_target.name)
    _verify_args(args, itest_target, container_should_be_running=True)

    exec_wrapper.execv(args.docker_path, [args.docker_path, "rm", "-f", container_name])


def cmd_itest_stop_all(args, bazel_args, mode_args):
    containers = _get_all_containers(args.docker_path)
    if containers:
        if not args.force:
            print """Will stop the following containers:

{}
""".format(
                "\n".join(containers)
            )
            reply = raw_input("Continue? [y/N] ")
            if reply.strip().lower() not in ("y", "yes"):
                sys.exit("Aborted.")
        exec_wrapper.execv(
            args.docker_path, [args.docker_path, "rm", "-f"] + containers
        )
    else:
        print "No containers to stop"
