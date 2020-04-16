# mypy: allow-untyped-defs

from __future__ import print_function

import os

from typing import Text

from build_tools import bazel_utils, build_parser
from build_tools.bzl_lib.cfg import BUILD_INPUT, GO_RULE_TYPES, WHITELISTED_GO_SRCS_PATHS
from build_tools.bzl_lib.run import run_cmd

from dropbox import runfiles


def srcs_allowed(path):
    # type: (Text) -> bool
    return any(path.endswith(p) for p in WHITELISTED_GO_SRCS_PATHS)


# Convert bazel targets into Go packages in the GOPATH.
def targets2packages(bazel_targets):
    go_packages = []
    workspace_dir = bazel_utils.find_workspace()
    targets = bazel_utils.expand_bazel_target_dirs(
        workspace_dir, bazel_targets, require_build_file=False
    )
    for x in targets:
        if x.startswith("//go/src/"):
            go_packages.append(x.replace("//go/src/", ""))
    return go_packages


class GoBuildGenerator(object):
    """This creates intermediate BUILD.gen-build-go files which contains
    various go targets.  bzl gen will consume the intermediate files
    to generate the fully merged BUILD files."""

    def __init__(
        self,
        workspace_dir,
        generated_files,
        verbose,
        skip_deps_generation,
        dry_run,
        use_magic_mirror,
    ):
        self.go_src_dir = os.path.join(workspace_dir, "go/src")
        self.generated_files = generated_files
        self.verbose = verbose
        self.skip_deps_generation = skip_deps_generation
        self.dry_run = dry_run

        self.visited_dirs = set()

    def regenerate(self, bazel_targets):
        go_packages = targets2packages(bazel_targets)
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
        if self.verbose:
            args += ["--verbose"]
        if self.skip_deps_generation:
            args += ["--skip-deps-generation"]
        if self.dry_run:
            args += ["--dry-run"]

        # Write out some temporary BUILD files that we can merge with
        # exisiting ones.
        tmp_buildfile = "BUILD.gen-build-go~"
        args += ["--build-filename", tmp_buildfile]
        args += go_packages
        output = run_cmd(args, verbose=self.verbose)

        if self.dry_run or self.verbose:
            print(output)

        if self.dry_run:
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
                    assert "go_versions" not in rule.attr_map, (
                        "Do not specify `go_versions` in %s - "
                        "code should build with all supported Go versions." % bzl_path
                    )
            else:
                print(line)
