# mypy: allow-untyped-defs

from __future__ import print_function

import os.path
import subprocess
import zipfile

import build_tools.bazel_utils as bazel_utils
import build_tools.build_parser as build_parser

from build_tools.bzl_lib import build_merge
from build_tools.py import vinst

DEFAULT_EXCLUDES = ["test", "tests", "testing", "SelfTest", "Test", "Tests"]
BUILD_INPUT = "BUILD.in"
BUILD = "BUILD"
BUILD_OUTPUT = "BUILD.gen_build_pip~"

PIP_RULE_TYPES = ("dbx_py_pypi_piplib", "dbx_py_local_piplib")

LOAD_STATEMENT = "load('@dbx_build_tools//build_tools/py:py.bzl', %s)" % (
    ", ".join([repr(t) for t in PIP_RULE_TYPES])
)

PUBLIC_STATEMENT = "package(default_visibility = ['//visibility:public'])\n"

# This logic is duplicated in build_tools/py/py.bzl:_get_build_interpreters and
# must be kept in sync.
def _get_build_interpreters(attr):
    interpreters = []
    if attr.get("python2_compatible", True):
        interpreters.append("cpython-27")
    if attr.get("python3_compatible", True):
        interpreters.append("cpython-37")
    return interpreters


class BasePipBuildGenerator(object):
    """Base class for generators on pip rules. Its regenerate function will parse
    the BUILD files for pip versions, and subclasses should implement process_pip_rules
    to gen based on those pip rules.
    """

    def __init__(
        self,
        workspace_dir,
        generated_files,
        verbose,
        skip_deps_generation,
        dry_run,
        use_magic_mirror,
    ):
        self.workspace_dir = workspace_dir
        self.generated_files = generated_files
        self.verbose = verbose
        self.skip_deps_generation = skip_deps_generation
        self.dry_run = dry_run
        self.use_magic_mirror = use_magic_mirror

        self.visited_dirs = set()

    def regenerate(self, bazel_targets, cwd="."):
        targets = bazel_utils.expand_bazel_target_dirs(
            self.workspace_dir,
            [t for t in bazel_targets if not t.startswith("@")],
            require_build_file=False,
            cwd=cwd,
        )

        for target in targets:
            assert target.startswith("//"), "Target must be absolute: " + target
            target_dir = target[2:]

            if target_dir in self.visited_dirs:
                continue
            self.visited_dirs.add(target_dir)

            build_bzl = os.path.join(self.workspace_dir, target_dir, BUILD_INPUT)
            if not os.path.isfile(build_bzl):
                continue

            parsed = build_parser.parse_file(build_bzl)

            pip_rules = parsed.get_rules_by_types(PIP_RULE_TYPES)
            if not pip_rules:
                if self.verbose:
                    print("No pip targets found in %s/%s" % (target_dir, BUILD_INPUT))
                continue

            if not self.skip_deps_generation:
                for rule in pip_rules:
                    self.regenerate(
                        rule.attr_map.get("deps", []),
                        cwd=os.path.join(self.workspace_dir, target_dir),
                    )

            if self.verbose:
                head = "(dry run) " if self.dry_run else ""
                print(
                    head
                    + "Processing pip targets in %s: %s"
                    % (target_dir, [rule.attr_map["name"] for rule in pip_rules])
                )

            if self.dry_run:
                continue

            self.process_pip_rules(target_dir, pip_rules)

    def process_pip_rules(self, target_dir, pip_rules):
        # do actual generation after sanity checks and parsing are complete.
        # subclasses can override this to do custom generation
        raise NotImplementedError


class PipBuildGenerator(BasePipBuildGenerator):
    """This creates intermediate BUILD.gen_build_pip files which contains
    pip targets with 'contents' attribute populated.  bzl gen will consume
    the intermediate files to generate the fully merged BUILD files."""

    def process_pip_rules(self, target_dir, pip_rules):
        self.generate_build_file(target_dir, pip_rules)

    def build(self, targets):
        subprocess.check_call(["bazel", "build"] + targets)

    def exclude_path(self, excludes, path):
        if path in excludes:
            return True
        for name in path.split("/"):
            if name in excludes:
                return True
        return False

    def generate_build_file(self, target_dir, pip_rules):
        # Temporarily make BUILD.in file a real BUILD file, and generate
        # the piplib zips.  Unlike piplibgen, we will leave the temporary
        # BUILD file around to ensure we can recursively generate pips.
        # The temporary BUILD files will be overwritten by gazel as the
        # last step.
        build = os.path.join(self.workspace_dir, target_dir, BUILD)

        content = [PUBLIC_STATEMENT, LOAD_STATEMENT]

        for rule in pip_rules:
            attrs_copy = dict(rule.attr_map)
            attrs_copy["use_magic_mirror"] = self.use_magic_mirror

            content.append("")
            content.append("%s(" % rule.rule_type)
            for key, val in attrs_copy.items():
                content.append("    %s = %s," % (key, repr(val)))
            content.append(")")

        with open(build, "w") as fd:
            fd.write("\n".join(content))

        self.build(
            ["//%s:%s" % (target_dir, rule.attr_map["name"]) for rule in pip_rules]
        )

        out_dir = os.path.join(self.workspace_dir, "bazel-bin", target_dir)
        output = [LOAD_STATEMENT]
        # For each piplib rule, list the zipfile created by Bazel and insert
        # the 'contents' attribute.  We'll rely on gazel to merge in the
        # remaining attributes.
        for rule in pip_rules:
            name = rule.attr_map["name"]
            excludes = list(rule.attr_map.get("py_excludes", DEFAULT_EXCLUDES))
            for namespace_pkg in rule.attr_map.get("namespace_pkgs", []):
                excludes.append(namespace_pkg.replace(".", "/") + "/__init__.py")

            contents = {}
            for build_key in _get_build_interpreters(rule.attr_map):
                wheel = os.path.join(
                    out_dir,
                    name + "-" + build_key,
                    name + "-0.0.0-py2.py3-none-any.whl",
                )
                if not os.path.exists(wheel):
                    continue
                with zipfile.ZipFile(wheel) as zf:
                    contents[build_key] = [
                        f
                        for f in vinst.wheel_contents(zf)
                        if not self.exclude_path(excludes, f)
                    ]

            output.append("%s(" % rule.rule_type)
            output.append("  name = %s," % repr(name))
            output.append("  contents = {")
            for build_key in sorted(contents):
                output.append("    %s: [" % repr(build_key))
                for filename in sorted(contents[build_key]):
                    output.append("      %s," % repr(filename))
                output.append("    ],")
            output.append("  },")
            output.append(")")
            output.append("")

        build_outdir = os.path.join(self.workspace_dir, target_dir)
        build_output = os.path.join(build_outdir, BUILD_OUTPUT)
        with open(build_output, "w") as fp:
            fp.write("\n".join(output))

        # Proactively generate the BUILD file because rdeps may depend on "contents" being properly
        # filled.
        build_merge.merge_build_files(build, build_output, build)
        self.generated_files[build_outdir].append(build_output)
