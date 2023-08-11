import os

from typing import Dict, Iterable, List, Set

from build_tools import bazel_utils, build_parser
from build_tools.bzl_lib.cfg import (
    BUILD_INPUT,
    GO_DEPENDENCIES_LOCAL_PATH,
    GO_DEPENDENCIES_RUNFILES_PATH,
    GO_GEN_CONFIG_LOCAL_PATH,
    GO_GEN_CONFIG_RUNFILES_PATH,
    GO_LIBRARY_RULE,
    GO_RULE_TYPES,
    GO_TEST_RULE,
    WHITELISTED_GO_SRCS_PATHS,
)
from build_tools.bzl_lib.generator import Config, Generator, GeneratorInfo
from build_tools.bzl_lib.run import run_cmd

from dropbox import runfiles


def srcs_allowed(path: str) -> bool:
    return any(path.endswith(p) for p in WHITELISTED_GO_SRCS_PATHS)


# Convert bazel targets into Go packages in the GOPATH.
def targets2packages(workspace_dir: str, bazel_targets: Iterable[str]) -> List[str]:
    go_packages = []
    targets = bazel_utils.expand_bazel_target_dirs(
        workspace_dir, bazel_targets, require_build_file=False
    )
    for x in targets:
        if x.startswith("//go/src/"):
            go_packages.append(x.replace("//go/src/", ""))
    return go_packages


def _resolve_path(workspace_dir: str, local_path: str, runfiles_path: str) -> str:
    config_path = os.path.join(workspace_dir, local_path)
    if not os.path.exists(config_path):
        config_path = runfiles.data_path(runfiles_path)
    return config_path


class GoBuildGenerator(Generator):
    """This creates intermediate BUILD.gen-build-go files which contains
    various go targets.  bzl gen will consume the intermediate files
    to generate the fully merged BUILD files."""

    def info(self) -> GeneratorInfo:
        return GeneratorInfo(
            description="""This creates intermediate BUILD.gen-build-go files which contains
    various go targets.  bzl gen will consume the intermediate files
    to generate the fully merged BUILD files."""
        )

    def __init__(
        self, workspace_dir: str, generated_files: Dict[str, List[str]], cfg: Config
    ) -> None:
        self.workspace_dir = workspace_dir
        self.go_src_dir = os.path.join(self.workspace_dir, "go/src")
        self.generated_files = generated_files
        self.cfg = cfg

        self.visited_dirs: Set[str] = set()

    def regenerate(self, bazel_targets: Iterable[str]) -> None:
        go_packages = targets2packages(self.workspace_dir, bazel_targets)
        go_packages = [
            p
            for p in go_packages
            if os.path.join(self.go_src_dir, p) not in self.visited_dirs
        ]

        if not go_packages:
            return

        tool_path = runfiles.data_path(
            "@dbx_build_tools//go/src/dropbox/build_tools/gen-build-go/gen-build-go"
        )

        args = [tool_path]
        if self.cfg.verbose:
            args += ["--verbose"]
        if self.cfg.skip_deps_generation:
            args += ["--skip-deps-generation"]
        if self.cfg.dry_run:
            args += ["--dry-run"]

        # Write out some temporary BUILD files that we can merge with
        # exisiting ones.
        tmp_buildfile = "BUILD.gen-build-go~"
        args += ["--build-filename", tmp_buildfile]
        args += [
            "--build-config",
            _resolve_path(
                self.workspace_dir,
                GO_GEN_CONFIG_LOCAL_PATH,
                GO_GEN_CONFIG_RUNFILES_PATH,
            ),
        ]
        args += [
            "--dependencies-path",
            _resolve_path(
                self.workspace_dir,
                GO_DEPENDENCIES_LOCAL_PATH,
                GO_DEPENDENCIES_RUNFILES_PATH,
            ),
        ]
        args += go_packages
        output = run_cmd(args, use_go_env=True, verbose=self.cfg.verbose)

        if self.cfg.dry_run or self.cfg.verbose:
            print(output)

        if self.cfg.dry_run:
            return

        for line in output.split("\n"):
            line = line.strip()
            if not line:
                continue

            chunks = line.split()
            if (
                len(chunks) == 2
                and chunks[0] == "Writing"
                and chunks[1].endswith(tmp_buildfile)
            ):
                dirpath = os.path.dirname(chunks[1])
                self.generated_files[dirpath].append(chunks[1])
                self.visited_dirs.add(dirpath)

                bzl_path = os.path.join(dirpath, BUILD_INPUT)
                if not os.path.isfile(bzl_path):
                    continue

                bzl_content = build_parser.parse_file(bzl_path)
                for rule in bzl_content.get_rules_by_types(GO_RULE_TYPES):
                    assert srcs_allowed(bzl_path) or "srcs" not in rule.attr_map, (
                        "Do not specify `srcs` in %s - "
                        "these are autoinferred by `bzl gen`" % bzl_path
                    )
                    assert (
                        rule.rule_type == GO_TEST_RULE
                        or rule.rule_type == GO_LIBRARY_RULE
                        or "go_versions" not in rule.attr_map
                    ), (
                        "Do not specify `go_versions` in %s - "
                        "Only dbx_go_test and dbx_go_library are allowed to specify "
                        "Go versions, and this should only be used during migrations "
                        "to newer Go versions" % bzl_path
                    )
            else:
                print(line)
