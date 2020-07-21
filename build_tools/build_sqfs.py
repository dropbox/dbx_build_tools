# mypy: allow-untyped-defs

from __future__ import annotations

import argparse
import multiprocessing
import os
import shutil
import stat
import subprocess

from build_tools.bazelpkg import dedup_file

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


class CapabilityException(Exception):
    pass


def _copy_manifest_wrapper(args):
    short_dest, src, out_dir, contents_path = args
    dest = os.path.join(out_dir, short_dest)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if src:
        # TODO: Possible optimization: only copy if it doesn't already exist in .contents.
        shutil.copy2(src, dest)
    else:
        # Make an empty file.
        open(dest, "wb").close()
    # Even though mksquashfs dedupes, it seems that deduping before handing it off to
    # mksquashfs is faster.
    dedup_file(dest, contents_path)


def copy_manifest(manifest_path, out_dir):
    contents_path = os.path.join(out_dir, ".contents")
    args = []
    conflicts = set()
    with open(manifest_path) as manifest:
        for line in manifest:
            short_dest, _, src = line.rstrip().partition("\0")
            if os.path.isdir(src):
                raise ValueError(
                    "A raw target pointing to a directory was detected: %s\n"
                    "Please use a filegroup instead." % short_dest
                )
            if short_dest in conflicts:
                raise ValueError("conflict %r" % (short_dest,))
            conflicts.add(short_dest)
            args.append((short_dest, src, out_dir, contents_path))

    with multiprocessing.Pool() as wpool:
        wpool.map_async(_copy_manifest_wrapper, args, chunksize=1).get(3600)

    shutil.rmtree(contents_path)


def main(args) -> None:
    output_dir = args.scratch_dir

    copy_manifest(args.manifest, output_dir)

    with open(args.symlink, "r") as symlink_file:
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

    # First we modify mtimes for symlinks
    for f in symlink_files:
        os.utime(f, (CONSTANT_TIMESTAMP, CONSTANT_TIMESTAMP), follow_symlinks=False)

    # Then we modify mtimes for all files -- if there are symlinks we might
    # update some files multiple times, but that's fine for now.
    for (dirpath, dirnames, filenames) in os.walk(output_dir):
        os.chmod(dirpath, DIRECTORY_MODE)
        os.utime(dirpath, (CONSTANT_TIMESTAMP, CONSTANT_TIMESTAMP))

        for filename in filenames:
            fullpath = os.path.join(dirpath, filename)
            current_mode = os.stat(fullpath).st_mode
            os.chmod(fullpath, current_mode & FILE_MODE_AND_MASK | FILE_MODE_OR_MASK)
            os.utime(
                os.path.join(dirpath, filename),
                (CONSTANT_TIMESTAMP, CONSTANT_TIMESTAMP),
            )

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

    subprocess.check_call(subprocess_args)


def create_setcap_command(capability_file: str, output_dir: str):
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
    main(args)
