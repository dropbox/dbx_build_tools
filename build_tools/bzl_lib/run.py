from __future__ import print_function

import subprocess
import sys

from typing import List, Text

from build_tools.go.env import make_go_env


def run_cmd(cmd, verbose=False):
    # type: (List[str], bool) -> Text
    env = make_go_env()
    env_args = ["%s=%s" % x for x in sorted(env.items())]
    if verbose:
        print("exec:", " ".join(env_args + cmd), file=sys.stderr)
    try:
        output = subprocess.check_output(cmd, env=env).decode("ascii")
    except subprocess.CalledProcessError:
        sys.exit(1)

    return output
