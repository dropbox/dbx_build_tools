from __future__ import annotations
import subprocess
import sys

from typing import List, Optional

from build_tools.go.env import make_go_env


def run_cmd(cmd: List[str], use_go_env: bool = False, verbose: bool = False, cwd: Optional[str] = None) -> str:
    env = dict()
    if use_go_env:
        env = make_go_env()

    env_args = ["%s=%s" % x for x in sorted(env.items())]
    if verbose:
        print("exec:", " ".join(env_args + cmd), cwd, file=sys.stderr)
    try:
        output = subprocess.check_output(cmd, env=env, encoding="ascii", cwd=cwd)
    except subprocess.CalledProcessError:
        sys.exit(1)

    return output
