"""
Helper functions that replace os.exec* functions. This is mostly for debugging
and metrics purposes.
"""
from __future__ import print_function

import os
import pipes
import sys

from typing import Any, List, Mapping, Text

from build_tools.bzl_lib import metrics


def execv(binary, args):
    # type: (Text, List[Any]) -> None
    metrics.report_metrics()
    if os.getenv("BZL_DEBUG"):
        print(
            "exec: {} {}".format(binary, " ".join(pipes.quote(s) for s in args[1:])),
            file=sys.stderr,
        )
    os.execv(binary, args)


def execvp(binary, args):
    # type: (Text, List[str]) -> None
    metrics.report_metrics()
    if os.getenv("BZL_DEBUG"):
        print(
            "exec: {} {}".format(binary, " ".join(pipes.quote(s) for s in args[1:])),
            file=sys.stderr,
        )
    os.execvp(binary, args)


def execve(binary, args, env):
    # type: (Text, List[str], Mapping[str, str]) -> None
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
    # type: (Text, List[str], Mapping[str, str]) -> None
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
