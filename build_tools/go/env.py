import os

from typing import Dict

from build_tools import bazel_utils


def make_go_env():
    # type: () -> Dict[str, str]
    # TODO(msolo) Respect args to bzl to use the proper default runtime.
    ws = bazel_utils.find_workspace()
    bazel_ws_root = "bazel-" + os.path.basename(ws)
    GOROOT = os.path.join(
        ws, bazel_ws_root, "external/go_1_12_17_linux_amd64_tar_gz/go"
    )

    return {
        "GOROOT": GOROOT,
        "GOPATH": os.path.join(bazel_utils.find_workspace(), "go"),
        # go-errcheck behaves incorrectly if $GOROOT/bin is not added to $PATH
        "PATH": os.path.join(GOROOT, "bin") + ":" + os.getenv("PATH", ""),
    }
