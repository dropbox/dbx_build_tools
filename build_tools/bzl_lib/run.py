import subprocess
import sys

from typing import Any

from build_tools.go.env import make_go_env


def run_cmd(cmd, verbose=False):
    # type: (Any, bool) -> str
    env = make_go_env()
    env_args = ["%s=%s" % x for x in sorted(env.iteritems())]
    if verbose:
        print >>sys.stderr, "exec:", " ".join(env_args + cmd)
    try:
        output = subprocess.check_output(cmd, env=env)
    except subprocess.CalledProcessError:
        sys.exit(1)

    return output
