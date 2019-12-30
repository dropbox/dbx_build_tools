# This script runs a command and drops all output unless the command fails.
# It's useful for wrapping spammy scripts in build steps.
#
# This is inspired by chronic from moreutils: https://joeyh.name/code/moreutils/
from __future__ import print_function

import subprocess
import sys

if len(sys.argv) == 1:
    print("usage: {} cmd args...".format(sys.argv[0]), file=sys.stderr)
    sys.exit(2)

try:
    subprocess.check_output(sys.argv[1:], stderr=subprocess.STDOUT)
except subprocess.CalledProcessError as e:
    sys.stderr.buffer.write(e.output)  # type: ignore[attr-defined]
    if e.returncode < 0:
        # subprocess killed by signal
        sys.exit(1)
    sys.exit(e.returncode)
