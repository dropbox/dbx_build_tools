# mypy: allow-untyped-defs

from __future__ import absolute_import, print_function

import errno
import fnmatch
import hashlib
import itertools
import multiprocessing
import os
import shutil
import signal
import subprocess
import sys

from collections import defaultdict
from typing import List, Optional, Text, Union

import six

from build_tools import bazel_utils, build_parser


# Return current revision in the workspace repo.
def get_workspace_repo_revision(args):
    git_cmd = [args.git_path, "rev-parse", "HEAD"]
    return subprocess.check_output(git_cmd).strip()


def sha256_file(path):
    with open(path, "rb") as f:
        h = hashlib.sha256()
        h.update(str(os.stat(path).st_mode).encode("utf-8"))
        while True:
            buf = f.read(1024 * 1024)
            if not buf:
                break
            h.update(buf)
        return h.hexdigest()


# Make a directory, but allow that there might be a race creating it.
def _maybe_makedirs(path):
    # type: (Union[str, Text]) -> None
    try:
        os.makedirs(path)
    except OSError as e:
        if e.errno != errno.EEXIST:
            raise


# Replace duplicate files with a hardlinks to a hidden content-addressable subdirectory in contents_path.
def dedup_dir(fdir, contents_path, match=None):
    _maybe_makedirs(contents_path)
    for root, _, files in os.walk(fdir):
        for f in files:
            if match and not fnmatch.fnmatch(f, match):
                continue
            fpath = os.path.join(root, f)
            dedup_file(fpath, contents_path)


# Create a hardlink between fpath and a content addressable name.
def dedup_file(fpath, contents_path):
    # Don't hardlink empty files; it's fairly pointless.
    if os.stat(fpath).st_size == 0:
        return
    f_hash = sha256_file(fpath)
    f_hash_dir = os.path.join(contents_path, f_hash[:2])
    f_hash_path = os.path.join(f_hash_dir, f_hash[2:])

    _maybe_makedirs(f_hash_dir)
    try:
        # Create a link to a content addressable name if this is the first time.
        os.link(fpath, f_hash_path)
        return
    except OSError as e:
        # Make sure only one worker creates the hashed file so all other files reference the same
        # inode.
        if e.errno != errno.EEXIST:
            raise bazel_utils.BazelError("hard link error", e, fpath, f_hash_path)

    # Replace ourselves with a hardlink to the content addressable file.
    os.remove(fpath)
    try:
        os.link(f_hash_path, fpath)
    except OSError as e:
        raise bazel_utils.BazelError("hard link error", e, f_hash_path, fpath)


def _copy_manifest_wrapper(args):
    short_dest, src, out_dir, contents_path = args
    dest = os.path.join(out_dir, short_dest)
    _maybe_makedirs(os.path.dirname(dest))
    # TODO: Possible optimization: only copy if it doesn't already exist in .contents.
    shutil.copy2(src, dest)
    # Even though mksquashfs dedupes, it seems that deduping before handing it off to
    # mksquashfs is faster.
    dedup_file(dest, contents_path)


def copy_manifest(manifest_path, out_dir):
    contents_path = os.path.join(out_dir, ".contents")
    args = []
    with open(manifest_path) as manifest:
        for line in manifest:
            short_dest, src = line.strip().split("\0")
            if os.path.isdir(src):
                raise bazel_utils.BazelError(
                    "A raw target pointing to a directory was detected: %s\n"
                    "Please use a filegroup instead." % short_dest
                )
            args.append((short_dest, src, out_dir, contents_path))

    wpool = multiprocessing.Pool(initializer=_init_worker)

    try:
        # Use async + timeout to make sure KeyboardInterrupt fires.
        wpool.map_async(_copy_manifest_wrapper, args, chunksize=1).get(3600)
    except KeyboardInterrupt:
        wpool.terminate()
        wpool.join()
        raise

    shutil.rmtree(contents_path)


def _init_worker():
    # type: () -> None
    signal.signal(signal.SIGINT, signal.SIG_IGN)


def _copy_file(src, dst, preserve_symlinks):
    # If we're trying to copy symlinks over, we'll need to do readlink twice as
    # the first link should be bazel-bin -> bazel-cache.
    if preserve_symlinks and os.path.islink(src) and os.path.islink(os.readlink(src)):
        os.symlink(os.readlink(os.readlink(src)), dst)
        return

    shutil.copy2(src, dst)


def _copy_outputs_wrapper(args):
    _copy_outputs(*args)


def _copy_outputs_multi(
    bazel_path,  # type: str
    outputs,  # type: List[Text]
    out_dir,  # type: Text
    preserve_paths,  # type: bool
    preserve_symlinks,  # type: bool
    _dedup_files,  # type: Text
    bazel_args,  # type: Optional[List[str]]
    bazel_build_args,  # type: Optional[List[str]]
):
    # type: (...) -> None
    # ask bazel where the bazel-bin directory is, to support read-only
    # workspaces where bazel is not allowed to create a bazel-bin symlink
    # at the root of the workspace
    bazel_info_cmd = [bazel_path]
    if bazel_args:
        bazel_info_cmd += bazel_args
    bazel_info_cmd.append("info")
    if bazel_build_args:
        bazel_info_cmd += bazel_build_args
    bazel_bin_dir = bazel_utils.check_output_silently(
        bazel_info_cmd + ["bazel-bin"]
    ).strip()
    wpool = multiprocessing.Pool(initializer=_init_worker)

    args = [
        (
            [output],
            bazel_bin_dir,
            out_dir,
            preserve_paths,
            preserve_symlinks,
            _dedup_files,
        )
        for output in outputs
    ]
    try:
        # Use async + timeout to make sure KeyboardInterrupt fires.
        wpool.map_async(_copy_outputs_wrapper, args, chunksize=1).get(3600)
    except KeyboardInterrupt:
        wpool.terminate()
        wpool.join()
        raise


def _copy_outputs(
    outputs, bazel_bin_dir, out_dir, preserve_paths, preserve_symlinks, contents_path
):
    for output in outputs:
        assert output.startswith("bazel-bin/"), output
        abs_output = os.path.join(bazel_bin_dir, os.path.relpath(output, "bazel-bin"))
        if output.endswith(".runfiles") and not os.path.exists(abs_output):
            # Runfiles is optional for some target types, so we only
            # include if it exists.
            continue
        assert os.path.exists(abs_output), "Path {} must exist".format(abs_output)
        if os.path.isdir(abs_output):
            relative_out_path = (
                os.path.relpath(output, "bazel-bin")
                if preserve_paths
                else os.path.basename(output)
            )
            out_path = os.path.join(out_dir, relative_out_path)
            if preserve_symlinks:
                # If we want to preserve any relative symlinks that we've created, we need
                # to walk the entire directory and read symlinks.
                for (dirpath, dirnames, filenames) in os.walk(abs_output):
                    for f in filenames:
                        # This should be in sync with the shutil ignore pattern below.
                        if f.endswith(".pyc"):
                            continue
                        file_path = os.path.join(dirpath, f)
                        file_path_rel = os.path.relpath(file_path, abs_output)
                        output_file = os.path.join(out_path, file_path_rel)
                        _maybe_makedirs(os.path.dirname(output_file))
                        _copy_file(
                            file_path, output_file, preserve_symlinks=preserve_symlinks
                        )
            else:
                shutil.copytree(
                    abs_output, out_path, ignore=shutil.ignore_patterns("*.pyc")
                )
            if contents_path:
                # Deduplicate before compiling so all embedded timestamps match.
                dedup_dir(out_path, contents_path)
        else:
            relative_out_path = (
                os.path.dirname(os.path.relpath(output, "bazel-bin"))
                if preserve_paths
                else ""
            )
            final_resting_dir = os.path.join(out_dir, relative_out_path)
            _maybe_makedirs(final_resting_dir)
            _copy_file(
                abs_output, final_resting_dir, preserve_symlinks=preserve_symlinks
            )
            if contents_path:
                fname = os.path.join(final_resting_dir, os.path.basename(abs_output))
                dedup_file(fname, contents_path)


def check_for_duplicate_outputs(labels_to_outputs):
    output_to_labels = defaultdict(list)  # type: ignore[var-annotated]
    for label, outputs in six.iteritems(labels_to_outputs):
        for output in outputs:
            output_to_labels[os.path.basename(output)].append(label)
    duplicate_output_labels = set()
    for output, labels in six.iteritems(output_to_labels):
        if len(labels) > 1:
            duplicate_output_labels.add(frozenset(labels))
    if duplicate_output_labels:
        pretty_output = ["\n  ".join(labels) for labels in duplicate_output_labels]
        raise bazel_utils.BazelError(
            "these labels provide the same outputs:\n  %s"
            % "\n\n  ".join(pretty_output)
        )


def copy_labels(
    labels,  # type: List[str]
    out_dir,  # type: Text
    preserve_paths=False,  # type: bool
    preserve_symlinks=False,  # type: bool
    _dedup_files=False,  # type: bool
    bazel_query_args=None,  # type: Optional[List[str]]
    bazel_args=None,  # type: Optional[List[str]]
    bazel_build_args=None,  # type: Optional[List[str]]
):
    # type: (...) -> None
    if _dedup_files:
        contents_path = os.path.join(out_dir, ".contents")
    else:
        contents_path = None  # type: ignore[assignment]

    query_args = []  # type: ignore[var-annotated]
    if bazel_args:
        query_args += bazel_args
    if bazel_query_args:
        query_args += bazel_query_args

    labels_to_outputs = bazel_utils.outputs_for_labels(
        "bazel", labels, bazel_args=bazel_args, bazel_query_args=bazel_query_args
    )
    if not preserve_paths:
        check_for_duplicate_outputs(labels_to_outputs)

    outputs = list(itertools.chain.from_iterable(six.itervalues(labels_to_outputs)))

    _copy_outputs_multi(
        "bazel",
        outputs,
        out_dir,
        preserve_paths,
        preserve_symlinks,
        contents_path,
        bazel_args,
        bazel_build_args,
    )
    if contents_path:
        # Purge the contents directory to remove superfluous inodes before squashing
        shutil.rmtree(contents_path)


def _build_targets(
    args,
    bazel_args,
    mode_args,
    pkg_target,
    pkg_prefix,
    name="",
    data=(),
    output_extension="tmp",
    file_map=None,
    preserve_symlinks=False,
    dedup_files=False,
):
    if not pkg_target.name.endswith(output_extension):
        raise bazel_utils.BazelError(
            "invalid target '%s' - must end with .%s"
            % (pkg_target.label, output_extension)
        )
    # Treat data as our list of targets.
    targets = [bazel_utils.BazelTarget(x) for x in data]

    if targets:
        bazel_cmd = [args.bazel_path] + bazel_args + ["build"] + mode_args + data
        subprocess.check_call(bazel_cmd)

    # ask bazel where bazel-bin and bazel-genfiles are, instead of relying on
    # the symlinks, to support read-only workspaces
    pkg_dir_root = bazel_utils.check_output_silently(
        [args.bazel_path] + bazel_args + ["info", "bazel-genfiles"]
    ).strip()
    out_dir_root = bazel_utils.check_output_silently(
        [args.bazel_path] + bazel_args + ["info", "bazel-bin"]
    ).strip()

    pkg_dir = os.path.join(pkg_dir_root, pkg_target.package, pkg_target.name + "-tmp")
    out_file = os.path.join(out_dir_root, pkg_target.package, pkg_target.name)

    out_dir = pkg_dir
    if pkg_prefix:
        out_dir = os.path.join(pkg_dir, pkg_prefix.strip("/"))
    # Prep and move things into the pkg_dir so they get squashed.
    if os.path.exists(out_file):
        os.remove(out_file)
    if os.path.exists(pkg_dir):
        shutil.rmtree(pkg_dir)
    os.makedirs(pkg_dir)
    if pkg_dir != out_dir:
        if os.path.exists(out_dir):
            shutil.rmtree(out_dir)
        os.makedirs(out_dir)

    if file_map:
        for dst, src in six.iteritems(file_map):
            if src:
                pkg_dst = os.path.join(pkg_dir, dst.strip("/"))
                pkg_dst_dir = os.path.dirname(pkg_dst)
                if not os.path.exists(pkg_dst_dir):
                    os.makedirs(pkg_dst_dir)
                shutil.copy2(os.path.join(pkg_target.package, src), pkg_dst)
            else:
                # If there is no source, assume it's a directory.
                pkg_dst_dir = os.path.join(pkg_dir, dst.strip("/"))
                if not os.path.exists(pkg_dst_dir):
                    os.makedirs(pkg_dst_dir)
    if targets:
        copy_labels(
            [t.label for t in targets],
            out_dir,
            preserve_symlinks=preserve_symlinks,
            _dedup_files=dedup_files,
            bazel_args=bazel_args,
            bazel_build_args=mode_args,
        )
    return pkg_dir, out_file


def dbx_pkg_deb(
    args,
    bazel_args,
    mode_args,
    pkg_target,
    name="",
    data=(),
    file_map=None,
    prefix="/usr/bin",
    preserve_symlinks=False,
    package=None,
    version=None,
    depends=(),
    after_install="",
    after_upgrade="",
    before_remove="",
    before_upgrade="",
    replaces=(),
    conflicts=(),
    provides=(),
):
    pkg_dir, out_file = _build_targets(
        args,
        bazel_args,
        mode_args,
        pkg_target,
        pkg_prefix=prefix,
        name=name,
        data=data,
        output_extension="deb",
        preserve_symlinks=preserve_symlinks,
        file_map=file_map,
    )

    out_dir = os.path.dirname(out_file)
    out_file = os.path.join(out_dir, "%s_%s_amd64.deb" % (package, version))
    if os.path.exists(out_file):
        os.remove(out_file)
    if not os.path.exists(out_dir):
        os.makedirs(out_dir)

    pack_cmd = [
        args.fpm_path,
        "-s",
        "dir",
        "-t",
        "deb",
        "-C",
        os.path.abspath(pkg_dir),
        "--name",
        package,
        "--version",
        version,
        "--package",
        out_file,
        "--deb-no-default-config-files",
    ]
    if after_install:
        pack_cmd += ["--after-install", after_install]
    if after_upgrade:
        pack_cmd += ["--after-upgrade", after_upgrade]
    if before_remove:
        pack_cmd += ["--before-remove", before_remove]
    if before_upgrade:
        pack_cmd += ["--before-upgrade", before_upgrade]

    # We're building with Bazel, which requires DRTE.
    # To save the effort in guessing the right one to use,
    # set both all versions as dependencies -- most hosts will have all anyway.
    depends = set(depends)
    depends.update(["drte-v3"])
    for dependency in depends:
        pack_cmd.extend(("-d", dependency))

    for pkg in replaces:
        pack_cmd += ["--replaces", pkg]
    for pkg in conflicts:
        pack_cmd += ["--conflicts", pkg]
    for pkg in provides:
        pack_cmd += ["--provides", pkg]

    subprocess.check_call(pack_cmd)
    symlink_name = os.path.join(out_dir, name)
    if os.path.exists(symlink_name):
        os.remove(symlink_name)
    os.symlink(os.path.basename(out_file), symlink_name)


def run_rule(args, bazel_args, mode_args, target, rule):

    attrs = rule.attr_map.copy()
    attrs.pop(
        "visibility", None
    )  # always a legal param, but we have no use for it here
    if rule.rule_type == "dbx_pkg_deb":
        dbx_pkg_deb(args, bazel_args, mode_args, target, **attrs)
    else:
        raise bazel_utils.BazelError("invalid rule type: " + rule.rule_type)


def cmd_pkg(args, bazel_args, mode_args):
    workspace_dir = bazel_utils.find_workspace()
    curdir = os.getcwd()
    os.chdir(workspace_dir)
    # Each target must be of type dbx_pkg_* just for sanity.
    for target_str in args.targets:
        target = bazel_utils.BazelTarget(target_str)
        try:
            bp = build_parser.BuildParser()
            bp.parse_file(os.path.join(workspace_dir, target.build_file))
            rule = bp.get_rule(target.name)
        except (IOError, KeyError) as e:
            sys.exit("No such target: " + target_str + " " + str(e))

        run_rule(args, bazel_args, mode_args, target, rule)

        outputs = bazel_utils.outputs_for_label(args.bazel_path, target.label)
        print("bzl target", target.label, "up-to-date:")
        for f in outputs:
            print("  " + f)
    os.chdir(curdir)
