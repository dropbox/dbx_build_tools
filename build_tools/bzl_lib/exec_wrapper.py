"""
Helper functions that replace os.exec* functions. This is mostly for debugging
and metrics purposes.
"""
import os
import pipes
import subprocess
import sys

from typing import Any, List, Mapping, Optional

from build_tools.bzl_lib import metrics


def execv(binary, args):
    # type: (str, List[Any]) -> None
    metrics.report_metrics()
    if os.getenv("BZL_DEBUG"):
        print(
            "exec: {} {}".format(binary, " ".join(pipes.quote(s) for s in args[1:])),
            file=sys.stderr,
        )
    os.execv(binary, args)


def execvp(binary, args):
    # type: (str, List[str]) -> None
    metrics.report_metrics()
    if os.getenv("BZL_DEBUG"):
        print(
            "exec: {} {}".format(binary, " ".join(pipes.quote(s) for s in args[1:])),
            file=sys.stderr,
        )
    os.execvp(binary, args)


def execve(binary, args, env):
    # type: (str, List[str], Mapping[str, str]) -> None
    metrics.report_metrics()
    if os.getenv("BZL_DEBUG"):
        print(
            "exec: {env} {args}".format(
                env=" ".join("{}={}".format(k, pipes.quote(v)) for k, v in env.items()),
                args=binary + " " + " ".join(pipes.quote(s) for s in args[1:]),
            ),
            file=sys.stderr,
        )
    os.execve(binary, args, env)


def execvpe(binary, args, env):
    # type: (str, List[str], Mapping[str, str]) -> None
    metrics.report_metrics()
    if os.getenv("BZL_DEBUG"):
        print(
            "exec: {env} {args}".format(
                env=" ".join("{}={}".format(k, pipes.quote(v)) for k, v in env.items()),
                args=binary + " " + " ".join(pipes.quote(s) for s in args[1:]),
            ),
            file=sys.stderr,
        )
    os.execvpe(binary, args, env)


# instead of exec-ing, execute the binary in a subprocess and then exit the program with
# the same exit code.
# This lets us record accurate timing stats for commands like `bzl test //foo`.
# the arguments match typical exec arguments, i.e. args is expected to contain
# the list of args passed to the program (including binary display name) and binary is expected
# to be actual binary path
# NOTE this currently deliberately doesn't try to forward any signals or do any signal handling,
# to keep code simple. All uses for subprocess_exec is currently expected to be interactive, from a shell.
# Shells will send signal to the entire session.
def subprocess_exec(binary, args, env=None):
    # type: (str, List[str], Optional[Mapping[str, str]]) -> int
    if os.getenv("BZL_DEBUG"):
        print(
            "subprocess_exec: {} {}".format(
                binary, " ".join(pipes.quote(s) for s in args[1:])
            ),
            file=sys.stderr,
        )
    try:
        proc = subprocess.Popen(args, executable=binary, env=env)
        exit_code = proc.wait()
    except KeyboardInterrupt:
        # Wait for child process to die on graceful interrupt.
        exit_code = proc.wait()
    metrics.set_extra_attributes("exit_code", str(exit_code))
    if exit_code != 0:
        metrics.set_error(
            "subprocess_exec_bad_exit",
            "subprocess_exec {} returned non-zero exit code {}".format(
                binary, exit_code
            ),
        )
    sys.exit(exit_code)
