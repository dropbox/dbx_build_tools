import os
import subprocess

from pathlib import Path
from typing import Dict

from build_tools import bazel_utils


def _ensure_goroot_exists(goroot: str) -> None:
    """Tries to populate GOROOT and verify that it exists."""
    # Doesn't actually build anything, but should populate the Go toolchain.
    subprocess.run(
        ["bazel", "build", "@dbx_build_tools//build_tools/go:go1.18"], check=True, capture_output=True
    )
    assert os.path.isdir(goroot), "Could not populate GOROOT"


def make_go_env(ensure_goroot: bool = True) -> Dict[str, str]:
    # TODO(msolo) Respect args to bzl to use the proper default runtime.
    ws = bazel_utils.find_workspace()

    env = {
        "GOCACHE": "/tmp/go_build_cache",
        # Use the user's preferred GOPATH if one is specified, otherwise fallback to the implicit
        # default of $HOME/go/
        "GOPATH": os.getenv("GOPATH") or str(Path.home() / "go"),
    }

    bazel_ws_root = "bazel-" + os.path.basename(ws)
    GOROOT = os.path.join(ws, bazel_ws_root, "external/go_1_18_linux_amd64_tar_gz/go")
    if ensure_goroot and not os.path.isdir(GOROOT):
        _ensure_goroot_exists(GOROOT)

    if os.path.isdir(GOROOT):
        env["GOROOT"] = GOROOT
        # go-errcheck behaves incorrectly if $GOROOT/bin is not added to $PATH
        env["PATH"] = os.path.join(GOROOT, "bin") + os.pathsep + os.getenv("PATH", "")

    return env
