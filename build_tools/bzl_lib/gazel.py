# mypy: allow-untyped-defs, allow-untyped-globals

import os

from typing import Callable, DefaultDict, Dict, Iterable, List, Sequence, Set

from build_tools import bazel_utils
from build_tools.bzl_lib import build_merge, metrics
from build_tools.bzl_lib.generator import Config, Generator, GeneratorInfo
from build_tools.bzl_lib.run import run_cmd

from dropbox import runfiles

HEADER = (
    "# @"
    + """generated: This file was generated by bzl. Do not modify!
# Argument overrides and custom targets should be specified in BUILD.in.

"""
)


class CopyGenerator(Generator):
    """This creates empty BUILD.gen_empty files to ensure BUILD.in contents are
    copied into BUILD, even when it does not include any generated targets"""

    def info(self) -> GeneratorInfo:
        return GeneratorInfo(
            description="""This creates empty BUILD.gen_empty files to ensure BUILD.in contents are
    copied into BUILD, even when it does not include any generated targets"""
        )

    def __init__(
        self, workspace_dir: str, generated_files: Dict[str, List[str]], cfg: Config
    ) -> None:

        self.workspace_dir = workspace_dir
        self.generated_files = generated_files
        self.cfg = cfg

        self.visited_dirs: Set[str] = set()

    def regenerate(self, bazel_targets: Iterable[str], cwd: str = ".") -> None:

        targets = bazel_utils.expand_bazel_target_dirs(
            self.workspace_dir,
            [t for t in bazel_targets if not t.startswith("@")],
            require_build_file=False,
            cwd=cwd,
        )

        for target in targets:
            assert target.startswith("//"), "Target must be absolute: " + target
            pkg, _, _ = target.partition(":")
            pkg_path = bazel_utils.normalize_relative_target_to_os_path(pkg[2:])
            target_dir = os.path.join(self.workspace_dir, pkg_path)

            if target_dir in self.visited_dirs:
                continue
            self.visited_dirs.add(target_dir)

            if not os.path.exists(os.path.join(target_dir, "BUILD.in")):
                continue

            if target_dir in self.generated_files:
                continue

            if self.cfg.dry_run:
                continue

            out = os.path.join(target_dir, "BUILD.gen_empty")
            open(out, "w").close()

            self.generated_files[target_dir].append(out)


class GazelError(Exception):
    pass


def regenerate_build_files(
    bazel_targets_l: Sequence[str],
    generators: Sequence[Callable[..., Generator]],
    cfg: Config,
    reverse_deps_generation: bool = False,
) -> None:
    workspace_dir = bazel_utils.find_workspace()
    generated_files = DefaultDict[str, List[str]](list)

    generator_instances: List[Generator] = []
    for gen in generators:
        # Most of the time `generator` is a class. Sometimes it's a functools.partial, so handle that too.
        generator_name = gen.__name__
        with metrics.Timer("bzl_gen_{}_init_ms".format(generator_name)) as init_timer:
            generator_instances.append(gen(workspace_dir, generated_files, cfg))
        metrics.log_cumulative_rate(init_timer.name, init_timer.get_interval_ms())

    # let generators potentially create folders / BUILD.in files and add these
    # to the targets we're generating
    for generator in generator_instances:
        bazel_targets_l = generator.preprocess_targets(bazel_targets_l)

    bazel_targets = set(bazel_targets_l)

    if reverse_deps_generation:
        targets = bazel_utils.expand_bazel_target_dirs(
            workspace_dir,
            [t for t in bazel_targets if not t.startswith("@")],
            require_build_file=False,
            cwd=".",
        )
        pkgs = [t.partition(":")[0] for t in targets]

        patterns = ['"%s"' % pkg for pkg in pkgs]
        patterns.extend(['"%s:' % pkg for pkg in pkgs])

        for path, dirs, files in os.walk(workspace_dir):
            if "BUILD" not in files:
                continue

            build_content = open(os.path.join(workspace_dir, path, "BUILD")).read()

            should_regen = False
            for pattern in patterns:
                if pattern in build_content:
                    should_regen = True
                    break

            if should_regen:
                # convert abs path to relative to workspace
                bazel_targets.add(
                    "//"
                    + bazel_utils.normalize_os_path_to_target(
                        os.path.relpath(path, workspace_dir)
                    )
                )

    # In order to ensure we don't miss generating specific target types,
    # recursively expands the generated set until it converges.
    prev_visited_dirs: Set[str] = set()

    while bazel_targets:
        for generator in generator_instances:
            with metrics.generator_metric_context(generator.__class__.__name__):
                generator.regenerate(bazel_targets)

        visited_dirs = set(generated_files.keys())
        newly_visited_dirs = visited_dirs.difference(prev_visited_dirs)
        if newly_visited_dirs:
            # continue processing
            prev_visited_dirs = visited_dirs
            bazel_targets = set(
                [
                    bazel_utils.normalize_os_path_to_target(
                        d.replace(workspace_dir, "/")
                    )
                    for d in newly_visited_dirs
                ]
            )
        else:
            break

    with metrics.Timer("bzl_gen_merge_build_files_ms") as merge_timer:
        merge_generated_build_files(generated_files)
    metrics.log_cumulative_rate(merge_timer.name, merge_timer.get_interval_ms())


def merge_generated_build_files(generated_files):
    buildfmt_path = runfiles.data_path("@dbx_build_tools//build_tools/buildfmt")

    merge_batch = []
    files_to_remove = set()

    for dirpath, intermediate_build_files in generated_files.items():
        # if `intermediate_build_files` contains only 'BUILD', it means
        # exactly one build generator generates the BUILD file directly
        # in the directory and there's no need to merge it
        output_file = os.path.join(dirpath, "BUILD")
        alt_output_file = os.path.join(dirpath, "BUILD.bazel")

        if intermediate_build_files == [output_file]:
            # always buildfmt even if not merging generated files
            run_cmd([buildfmt_path, output_file])
            continue

        # Clean out any existing BUILD/BUILD.bazel files beforehand.
        # Note that this may clobber unexpected files on case-insensitive systems.
        removed_alt_output = False
        if os.path.isfile(output_file):
            os.remove(output_file)
        if os.path.isfile(alt_output_file):
            removed_alt_output = True
            os.remove(alt_output_file)

        # Extra crap to deal with shitty case-insensitive file systems.
        build_names = []
        for name in os.listdir(dirpath):
            if name.lower() == "build":
                build_names.append(name)

        if len(build_names) > 0:
            print(
                (
                    "WARNING: %s renamed to BUILD.bazel due to case "
                    "insensitivity or folder name conflict" % output_file
                )
            )
            output_file = alt_output_file
        elif removed_alt_output:
            print("WARNING: %s removed" % alt_output_file)

        with open(output_file, "w") as fd:
            fd.write(HEADER)

        assert intermediate_build_files, dirpath
        assert output_file not in intermediate_build_files

        intermediate_build_files = sorted(set(intermediate_build_files))

        for filename in intermediate_build_files:
            merge_batch.append((output_file, filename, output_file))
            files_to_remove.add(filename)

        annotation_file = os.path.join(dirpath, "BUILD.in")

        if os.path.isfile(annotation_file):
            merge_batch.append((output_file, annotation_file, output_file))
        else:
            annotation_file = os.path.join(dirpath, "BUILD.in-gen-proto~")

            if os.path.isfile(annotation_file):
                merge_batch.append((output_file, annotation_file, output_file))

    # NOTE(jhance) Build merge merges in order, and this relies on that, since some of these
    # files in the batch have the same output file.
    build_merge.batch_merge_build_files(merge_batch)

    # Sort the final merged output. BUILD.in files may have out of order lists that bypassed
    # lint when being committed.
    formatted = []
    for batch in merge_batch:
        for file in batch:
            if file.endswith("/BUILD") and file not in formatted:
                formatted.append(file)
    if len(formatted):
        run_cmd([buildfmt_path] + formatted)

    for f in files_to_remove:
        os.remove(f)
