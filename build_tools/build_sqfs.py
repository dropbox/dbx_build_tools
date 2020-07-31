from __future__ import annotations

import argparse
import contextlib
import errno
import logging
import multiprocessing
import os
import shutil
import stat
import subprocess
import time

from typing import Any, Iterator, List, Optional, Tuple

from build_tools.bazelpkg import sha256_file

from dropbox import runfiles

# In order to make our sqfs files reproducible, we pick an arbitrary
# unix timestamp to use for all file modification times and the
# sqfs creation time.
CONSTANT_TIMESTAMP = 1000000000

# In more reproducibility fun across machines, we need to normalize
# the file modes. We'll simply assume that directories should be given
# a 0775 mode, while files should only be readable by everyone, and
# writable by no one. We preserve the executable bits.
DIRECTORY_MODE = 0o755
FILE_MODE_OR_MASK = stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH
FILE_MODE_AND_MASK = ~(stat.S_IWOTH | stat.S_IWUSR | stat.S_IWGRP)


@contextlib.contextmanager
def measure_time(name: str) -> Iterator[None]:
    start = time.time()
    try:
        yield
    finally:
        logging.debug("%s took %ds", name, time.time() - start)


class CapabilityException(Exception):
    pass


def link_file_to_dest(args: Tuple[str, Optional[str], str]) -> None:
    short_dest, src, out_dir = args
    dest = os.path.join(out_dir, short_dest)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if src:
        os.link(src, dest)
    else:
        # Make an empty file.
        open(dest, "wb").close()


def fix_mtime(args: Tuple[str, List[str], List[str]]) -> None:
    dirpath, dirnames, filenames = args
    os.chmod(dirpath, DIRECTORY_MODE)
    os.utime(dirpath, (CONSTANT_TIMESTAMP, CONSTANT_TIMESTAMP))

    for filename in filenames:
        fullpath = os.path.join(dirpath, filename)
        current_mode = os.stat(fullpath).st_mode
        os.chmod(fullpath, current_mode & FILE_MODE_AND_MASK | FILE_MODE_OR_MASK)
        os.utime(
            os.path.join(dirpath, filename), (CONSTANT_TIMESTAMP, CONSTANT_TIMESTAMP)
        )


def prepare_content_addressable_tree(args: Tuple[str, str]) -> Optional[str]:
    src, contents_path = args
    if not src:
        return None
    f_hash = sha256_file(src)
    f_hash_dir = os.path.join(contents_path, f_hash[:2])
    f_hash_path = os.path.join(f_hash_dir, f_hash[2:])

    os.makedirs(f_hash_dir, exist_ok=True)
    try:
        shutil.copy2(src, f_hash_path)
    except OSError as e:
        if e.errno != errno.EEXIST:
            raise
    return f_hash_path


def chunksize(total_work: int) -> int:
    """
    Return a reasonable chunksize to avoid unnecessary serialization when used with multiprocessing.Pool.map
    """
    return max(1, int(total_work / 50.0 / multiprocessing.cpu_count()))


def copy_manifest(
    wpool: multiprocessing.pool.Pool, manifest_path: str, out_dir: str
) -> None:
    contents_path = os.path.join(out_dir, ".contents")
    args = []
    prepare_args = []
    dest_src_pair = []
    src_set = set()
    conflicts = set()
    with measure_time("read_manifest"), open(manifest_path) as manifest:
        for line in manifest:
            short_dest, _, src = line.rstrip().partition("\0")
            if short_dest in conflicts:
                raise ValueError("conflict %r" % (short_dest,))
            conflicts.add(short_dest)
            src_set.add(src)
            dest_src_pair.append((short_dest, src))
    for src in src_set:
        # check src here instead of when reading manifest to dedup and avoid calling isdir too many times
        if os.path.isdir(src):
            raise ValueError(
                "A raw target pointing to a directory was detected: %s\n"
                "Please use a filegroup instead." % short_dest
            )
        prepare_args.append((src, contents_path))
    with measure_time("prepare_content_addressable_tree"):
        content_addressable_files = wpool.map_async(
            prepare_content_addressable_tree,
            prepare_args,
            chunksize=chunksize(len(prepare_args)),
        ).get(3600)
    src_to_content = dict()
    for content_file, (src, _) in zip(content_addressable_files, prepare_args):
        if src:
            assert content_file
            src_to_content[src] = content_file
    for short_dest, src in dest_src_pair:
        args.append((short_dest, src_to_content.get(src), out_dir))
    with measure_time("link_file_to_dest"):
        wpool.map_async(link_file_to_dest, args, chunksize=chunksize(len(args))).get(
            3600
        )

    shutil.rmtree(contents_path)


def main(args: Any) -> None:
    output_dir = args.scratch_dir
    with multiprocessing.Pool() as wpool:

        with measure_time("copy_manifest"):
            copy_manifest(wpool, args.manifest, output_dir)

        with measure_time("create_symlinks"), open(args.symlink, "r") as symlink_file:
            symlink_files = []
            for line in symlink_file:
                link_path, link_target = line.strip().split("\0")
                # Strip any trailing slashes in case we're linking directories.
                link_path = link_path.rstrip("/")

                # Calculate the relative path so the symlink works correctly.
                link_target = os.path.relpath(link_target, os.path.dirname(link_path))
                link_path = os.path.join(output_dir, link_path)

                os.makedirs(os.path.dirname(link_path), exist_ok=True)
                os.symlink(link_target, link_path)
                symlink_files.append(link_path)

        with measure_time("fix_mtime"):
            # First we modify mtimes for symlinks
            for f in symlink_files:
                os.utime(
                    f, (CONSTANT_TIMESTAMP, CONSTANT_TIMESTAMP), follow_symlinks=False
                )

            # Then we modify mtimes for all files -- if there are symlinks we might
            # update some files multiple times, but that's fine for now.
            mtime_args = []
            for (dirpath, dirnames, filenames) in os.walk(output_dir):
                mtime_args.append((dirpath, dirnames, filenames))
            wpool.map_async(
                fix_mtime, mtime_args, chunksize=chunksize(len(mtime_args))
            ).get(3600)

    # setcap does not appear to change the mtime of the file, so we can run
    # this after fiddling with the timestamps without worrying about breaking
    # reproducibility.
    if args.capability_map:
        setcap_args = create_setcap_command(args.capability_map, output_dir)
        try:
            output = subprocess.check_output(
                ["/sbin/setcap"] + setcap_args, stderr=subprocess.STDOUT
            )
        except subprocess.CalledProcessError as e:
            print("Error running setcap:", e.output)
            raise

        # There are lots of errors that setcap returns an exit code of 0 for, so we check if it
        # emitted any output, and assume that if it did, some error occurred.
        # For example, applying a capability to a non-existent file gives an exit code of 0.
        if output:
            raise CapabilityException("\n%r" % output)

    subprocess_args = [
        runfiles.data_path("@dbx_build_tools//build_tools/chronic"),
        runfiles.data_path("@com_github_plougher_squashfs-tools//mksquashfs"),
        output_dir,
        args.output,
        "-no-progress",
        "-noappend",
        "-no-fragments",
        "-no-duplicates",
        "-processors",
        "16",
        "-fstime",
        str(CONSTANT_TIMESTAMP),
    ]
    if args.block_size_kb:
        subprocess_args += ["-b", str(args.block_size_kb * 1024)]

    with measure_time("mksquashfs"):
        subprocess.check_call(subprocess_args)


def create_setcap_command(capability_file: str, output_dir: str) -> List[str]:
    capabilities_args = []
    with open(capability_file, "r") as capf:
        for line in capf:
            filepath, capability_str = line.strip().split("\0")
            capabilities_args.append(capability_str)
            capabilities_args.append(os.path.join(output_dir, filepath))
    return capabilities_args


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Build a sqfs file")
    parser.add_argument("--manifest", required=True, help="manifest file")
    parser.add_argument(
        "--output", required=True, help="path to write the output sqfs file"
    )
    parser.add_argument(
        "--capability-map", required=False, help="capability file, if any"
    )
    parser.add_argument("--symlink", required=True, help="symlink file")
    parser.add_argument(
        "--scratch-dir",
        default="/tmp/sqfs_pkg",
        help="path to write temporary sqfs files",
    )
    parser.add_argument("--block-size-kb", type=int, help="sqfs block size (in KB)")
    args = parser.parse_args()
    with measure_time("main"):
        main(args)
