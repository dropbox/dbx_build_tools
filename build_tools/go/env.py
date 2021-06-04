import os
import subprocess

from typing import Dict

from build_tools import bazel_utils


def _ensure_goroot_exists(goroot):
    # type: (str) -> None
    """Tries to populate GOROOT and verify that it exists."""
    # Doesn't actually build anything, but should populate the Go toolchain.
    subprocess.run(
        ["bazel", "build", "@dbx_build_tools//build_tools/go:go1.16"], check=True, capture_output=True
    )
    assert os.path.isdir(goroot), "Could not populate GOROOT"


def make_go_env(ensure_goroot=True):
    # type: (bool) -> Dict[str, str]
    # TODO(msolo) Respect args to bzl to use the proper default runtime.
    ws = bazel_utils.find_workspace()

    env = {
        "GOPATH": os.path.join(bazel_utils.find_workspace(), "go"),
        "GOCACHE": "/tmp/go_build_cache",
        "GO111MODULE": "off",
    }

    bazel_ws_root = "bazel-" + os.path.basename(ws)
    GOROOT = os.path.join(ws, bazel_ws_root, "external/go_1_16_4_linux_amd64_tar_gz/go")
    if ensure_goroot and not os.path.isdir(GOROOT):
        _ensure_goroot_exists(GOROOT)

    if os.path.isdir(GOROOT):
        env["GOROOT"] = GOROOT
        # go-errcheck behaves incorrectly if $GOROOT/bin is not added to $PATH
        env["PATH"] = os.path.join(GOROOT, "bin") + os.pathsep + os.getenv("PATH", "")

    return env
