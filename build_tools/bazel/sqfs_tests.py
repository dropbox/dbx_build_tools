from subprocess import run
from typing import Optional

import pytest
import six

from dropbox.runfiles import data_path


@pytest.mark.parametrize(
    "algo,block_size,level,file",
    [
        ("gzip", 131072, 1, "test_sqfs_gzip_1.sqfs"),
        ("lz4", 16384, None, "test_sqfs_lz4.sqfs"),
    ],
)
def test_sqfs_compression(
    algo: str, block_size: int, level: Optional[int], file: str
) -> None:
    p = run(
        [
            data_path("@com_github_plougher_squashfs_tools//unsquashfs"),
            "-s",
            data_path(f"//build_tools/bazel/{file}"),
        ],
        check=True,
        capture_output=True,
    )
    stdout = frozenset(six.ensure_str(l.strip()) for l in p.stdout.splitlines())

    assert f"Block size {block_size}" in stdout, f"{stdout}"
    assert f"Compression {algo}" in stdout, f"{stdout}"
    if level is not None:
        assert f"compression-level {level}" in stdout, f"{stdout}"
