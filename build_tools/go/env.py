import os
import subprocess

from typing import Dict

from build_tools import bazel_utils


def ensure_goroot_exists(goroot):
    # type: (str) -> None
    """Checks if the GOROOT specified actually exists, and tries to populate it
    if it doesn't exist."""
    if not goroot or os.path.isdir(goroot):
        return

    # Doesn't actually build anything, but should populate the Go toolchain.
    subprocess.check_call(["bazel", "build", "@dbx_build_tools//build_tools/go:go1.12"])
    assert os.path.isdir(goroot), "Could not populate GOROOT"


def make_go_env():
    # type: () -> Dict[str, str]
    # TODO(msolo) Respect args to bzl to use the proper default runtime.
    ws = bazel_utils.find_workspace()
    bazel_ws_root = "bazel-" + os.path.basename(ws)
    GOROOT = os.path.join(
        ws, bazel_ws_root, "external/go_1_12_17_linux_amd64_tar_gz/go"
    )
    ensure_goroot_exists(GOROOT)

    return {
        "GOROOT": GOROOT,
        "GOPATH": os.path.join(bazel_utils.find_workspace(), "go"),
        # go-errcheck behaves incorrectly if $GOROOT/bin is not added to $PATH
        "PATH": os.path.join(GOROOT, "bin") + os.pathsep + os.getenv("PATH", ""),
        "GOCACHE": "/tmp/go_build_cache",
    }
