# mypy: allow-untyped-defs

"""
Helper functions that replace os.exec* functions. This is mostly for debugging
and metrics purposes.
"""
import os
import pipes
import sys

from typing import Any, List, Text

from build_tools.bzl_lib import metrics


def execv(binary, args):
    # type: (Text, List[Any]) -> None
    metrics.report_metrics()
    if os.getenv("BZL_DEBUG"):
        print >>sys.stderr, "exec: {} {}".format(
            binary, " ".join(pipes.quote(s) for s in args[1:])
        )
    os.execv(binary, args)


def execve(binary, args, env):
    metrics.report_metrics()
    if os.getenv("BZL_DEBUG"):
        print >>sys.stderr, "exec: {env} {args}".format(
            env=" ".join("{}={}".format(k, pipes.quote(v)) for k, v in env.iteritems()),
            args=binary + " " + " ".join(pipes.quote(s) for s in args[1:]),
        )
    os.execve(binary, args, env)


def execvpe(binary, args, env):
    metrics.report_metrics()
    if os.getenv("BZL_DEBUG"):
        print >>sys.stderr, "exec: {env} {args}".format(
            env=" ".join("{}={}".format(k, pipes.quote(v)) for k, v in env.iteritems()),
            args=binary + " " + " ".join(pipes.quote(s) for s in args[1:]),
        )
    os.execvpe(binary, args, env)
