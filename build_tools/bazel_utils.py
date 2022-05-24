from __future__ import annotations, print_function

import os
import pipes
import subprocess
import sys

from xml.dom import minidom  # type: ignore[import]

from build_tools.npm_utils import target_to_npm_name

MYPY = False
if MYPY:
    from typing import Any, Dict, Iterable, List, Optional, Sequence, Text, Tuple


class BazelError(Exception):
    pass


class NoSuchTargetError(BazelError):
    pass


class BazelTarget(object):
    def __init__(
        self, label: str, cwd: Optional[str] = None, workspace: Optional[str] = None
    ) -> None:
        if ":" in label:
            self.name = label.lstrip("//").split(":")[-1]
        else:
            self.name = os.path.basename(label.lstrip("//"))
        self.package = label.lstrip("//").split(":")[0]
        if not label.startswith("//"):
            if not cwd:
                cwd = os.getcwd()
            if not workspace:
                workspace = find_workspace()
            package_path = os.path.join(os.path.relpath(cwd, workspace), self.package)
            unclean_package_target = normalize_os_path_to_target(package_path)
            unclean_package_target = unclean_package_target.lstrip("./")
            self.package = unclean_package_target.rstrip("/")
        self.label = "//{}:{}".format(self.package, self.name)
        self.build_file = build_file_for_target(label)


class BazelRule(object):
    def __init__(self, target: str, kind: str, output_targets: List[Any]) -> None:
        self.target = target
        self.kind = kind
        self.output_targets = output_targets

    @staticmethod
    def from_xml_node(rule: Any) -> BazelRule:
        return BazelRule(
            target=rule.getAttribute("name"),
            kind=rule.getAttribute("class"),
            output_targets=[
                node.getAttribute("name")
                for node in rule.getElementsByTagName("rule-output")
            ],
        )


def expand_bazel_target_dirs(
    workspace: Text,
    targets: Iterable[Any],
    normalize: bool = True,
    require_build_file: bool = True,
    cwd: Text = ".",
) -> List[Any]:
    """Expand the Bazel target syntax into a list of directories that
    represent Bazel targets. If normalize is 'False', replace '//' with
    the workspace.  If require_build_file is 'False', target directory without
    BUILD files are included in the result set.
    """
    ntargets = expand_bazel_targets(
        workspace,
        targets,
        normalize=normalize,
        require_build_file=require_build_file,
        cwd=cwd,
    )
    return [x.split(":")[0] for x in ntargets]


def expand_bazel_targets(
    workspace: Text,
    targets: Iterable[Any],
    normalize: bool = True,
    require_build_file: bool = True,
    cwd: Text = ".",
    allow_nonexistent_npm_folders: bool = False,
    expand_short_form_labels: bool = False,
) -> List[Any]:
    matched = set()  # type: ignore[var-annotated]
    filtered = set()  # type: ignore[var-annotated]
    for target in targets:
        if not target:
            continue
        if target.startswith("-"):
            filtered.update(
                _expand_bazel_target(
                    workspace,
                    target[1:],
                    normalize=normalize,
                    require_build_file=require_build_file,
                    cwd=cwd,
                    allow_nonexistent_npm_folders=allow_nonexistent_npm_folders,
                    expand_short_form_labels=expand_short_form_labels,
                )
            )
        else:
            matched.update(
                _expand_bazel_target(
                    workspace,
                    target,
                    normalize=normalize,
                    require_build_file=require_build_file,
                    cwd=cwd,
                    allow_nonexistent_npm_folders=allow_nonexistent_npm_folders,
                    expand_short_form_labels=expand_short_form_labels,
                )
            )
    return list(sorted(matched - filtered))


def _expand_bazel_target(
    workspace: Text,
    target: Any,
    normalize: bool = True,
    require_build_file: bool = True,
    cwd: Text = ".",
    allow_nonexistent_npm_folders: bool = False,
    expand_short_form_labels: bool = False,
) -> List[Any]:
    if target.endswith("..."):
        recursive = True
        target_dir = target[:-3]
    else:
        recursive = False
        target_dir, _, rule = target.partition(":")
    if target_dir == "":
        target_dir = cwd
    if target_dir.startswith("//"):
        target_dir = os.path.join(workspace, target_dir[2:])
    else:
        target_dir = os.path.join(os.path.abspath(cwd), target_dir)

    target_dir = os.path.abspath(target_dir)

    if not os.path.isdir(target_dir):
        if recursive or not (
            allow_nonexistent_npm_folders and target_to_npm_name(target) is not None
        ):
            raise NoSuchTargetError("no such target directory: " + target_dir)

    if recursive:
        targets = [t[0] for t in os.walk(target_dir)]
    else:
        target = target_dir
        if rule:
            target += ":" + rule

        targets = [target]

    if require_build_file:
        filtered = []
        for target in targets:
            target_dir, _, _ = target.partition(":")
            if os.path.exists(os.path.join(target_dir, "BUILD")):
                filtered.append(target)

        targets = filtered

    # Normalize target paths to use //
    if normalize:
        targets = [
            "//" + os.path.relpath(os.path.abspath(x), workspace) for x in targets
        ]
        if "//." in targets:
            targets[targets.index("//.")] = "//"

    # Despite the name, items in "targets" are actually paths that are likely to have
    # a mix of forward and backwards slashes on Windows.
    targets = [normalize_os_path_to_target(target) for target in targets]

    if expand_short_form_labels:
        targets = [expand_short_form_label(target) for target in targets]

    return targets


def find_workspace(starting_dir: Optional[str] = None) -> str:
    """Return the path of the enclosing Bazel workspace."""
    if starting_dir is None:
        starting_dir = os.getcwd()
    return _find_parent_directory_containing(starting_dir, "WORKSPACE")


def find_package_dir(starting_dir: str) -> str:
    """Return the path of the enclosing Bazel package."""
    try:
        return _find_parent_directory_containing(starting_dir, "BUILD")
    except BazelError:
        return _find_parent_directory_containing(starting_dir, "BUILD.bazel")


def find_workspace_and_package(test_path: str) -> Tuple[str, str, str]:
    """Return the workspace and Bazel package containing the file `path`."""
    package_dir = _find_parent_directory_containing(test_path, "BUILD")
    workspace_dir = find_workspace(package_dir)
    if package_dir == workspace_dir:
        # Avoid building '//.' from relpath(), which in Bazel is a syntax error
        package = "//"
    else:
        target = normalize_os_path_to_target(
            os.path.relpath(package_dir, workspace_dir)
        )
        package = "//" + target
    return workspace_dir, package_dir, package


def _find_parent_directory_containing(start: str, filename: str) -> str:
    """Given file or directory `start`, search upwards for `filename`.

    This can return the path `start` itself (if `start` is a directory),
    or one of its ancestor directories, or can raise an error if a file
    named `filename` is not found.

    """
    path = start
    while True:
        if os.path.exists(os.path.join(path, filename)):
            return path
        next_directory_up = os.path.dirname(path)
        at_filesystem_root = next_directory_up == path
        if at_filesystem_root:
            raise BazelError(
                "cannot find a {} file in any parent directory of {}".format(
                    filename, start
                )
            )
        path = next_directory_up


def _tags_query(operator: str, tags: Optional[Iterable[str]]) -> str:
    assert operator in [
        "except",
        "intersect",
        "union",
    ], "bazel query operator {} not in list".format(operator)
    queries = []
    if tags:
        for tag in tags:
            queries.append(
                '{} (attr("tags", "(\[| ){}(\]|,)", $t))'.format(operator, tag)
            )
    return " ".join(queries)


def check_output_silently(cmd: List[str]) -> Text:
    "similar to subprocess.check_output, but swallows stderr on success."
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True
    )
    stdout, stderr = proc.communicate()
    if proc.returncode != 0:
        print(stderr, file=sys.stderr)
        printable_cmd = " ".join(pipes.quote(s) for s in cmd)
        raise BazelError(
            "The following command returned non-zero exit status {}: {}".format(
                proc.returncode, printable_cmd
            )
        )
    return stdout


# filter a list of labels by kinds. Return xml output.
# (['binary'], ['//code/sfp:all']) -> xml representation of ['//code/sfp:bin']
# (['binary'], ['//code/sfp:bin', '//code/sfp:lib']) -> xml representation of ['//code/sfp:bin']
# exclude_tags: tags to ignore.
# require_tags: require all tags to be present.
def targets_of_kinds_for_labels_xml(
    bazel_bin_path: str,
    kinds: List[str],
    labels: List[str],
    exclude_tags: Optional[Iterable[str]] = None,
    require_tags: Optional[Iterable[str]] = None,
) -> Any:
    labels_string = " + ".join(labels)
    kinds_queries = ['kind("{}", {})'.format(k, labels_string) for k in kinds]
    bazel_cmd = [
        bazel_bin_path,
        "query",
        "--output=xml",
        "let t = {} in $t {} {}".format(
            " + ".join(kinds_queries),
            _tags_query("except", exclude_tags),
            _tags_query("intersect", require_tags),
        ),
    ]
    output = check_output_silently(bazel_cmd)
    return minidom.parseString(output)


# [//code/sfp:all] -> [//code/sfp:sfp_test, //code/sfp:sfp2_test]
# [code/sfp:sfp_test] -> [//code/sfp:sfp_test]
# exclude_tags: a list of tags to exclude from the query
# require_tags: a list of must have tags for the query
def test_targets_for_labels(
    bazel_bin_path: str,
    labels: List[str],
    exclude_tags: Optional[Iterable[str]] = None,
    require_tags: Optional[Iterable[str]] = None,
) -> List[Text]:
    bazel_cmd = [
        bazel_bin_path,
        "query",
        "let t = tests({}) in $t {} {}".format(
            " + ".join(labels),
            _tags_query("except", exclude_tags),
            _tags_query("intersect", require_tags),
        ),
    ]
    output = check_output_silently(bazel_cmd)
    targets = [x for x in output.strip().split("\n") if x]
    return targets


# //code/sfp:sfp
# //code/sfp:sfp.par
# Return paths that should be archived based on simple heuristics.
def outputs_for_label(
    bazel_bin_path: str,
    target: str,
    bazel_args: Optional[List[str]] = None,
    bazel_query_args: Optional[List[str]] = None,
) -> List[Text]:
    return outputs_for_labels(bazel_bin_path, [target], bazel_args, bazel_query_args)[
        target
    ]


def outputs_for_labels(
    bazel_bin_path: str,
    targets: Iterable[str],
    bazel_args: Optional[Sequence[str]] = None,
    bazel_query_args: Optional[Sequence[str]] = None,
) -> Dict[str, List[Text]]:
    # Some targets aren't named for their rule, which is a shame. This
    # is slow, but fortunately rare. Some targets don't actually have an
    # explict output, which is also unfortunate.
    bazel_cmd = [bazel_bin_path]
    if bazel_args:
        bazel_cmd += bazel_args
    bazel_cmd += ["query", "--output=xml"]
    if bazel_query_args:
        bazel_cmd += bazel_query_args
    for t in targets:
        bazel_cmd += [t, "+"]
    # -1 to remove last +
    bazel_cmd = bazel_cmd[:-1]

    with open(os.devnull, "w") as dev_null:
        try:
            xml_data = subprocess.check_output(bazel_cmd, stderr=dev_null)
        except subprocess.CalledProcessError as e:
            # Reraise error because of multiprocessing bugs.
            raise BazelError(str(e))
    xml_doc = minidom.parseString(xml_data)
    rules = _rules_from_xml_doc(xml_doc)

    return _outputs_for_rules(rules)


def _rules_from_xml_doc(xml_doc: Any) -> List[Any]:
    rules = xml_doc.getElementsByTagName("rule")
    return [BazelRule.from_xml_node(node) for node in rules]


def _outputs_for_rules(rules: List[BazelRule]) -> Dict[str, List[Text]]:
    outputs = {}
    for rule in rules:
        target_outputs = _outputs_for_rule(rule)
        outputs[rule.target] = target_outputs

    return outputs


def _outputs_for_rule(rule: BazelRule) -> List[Text]:
    # Some targets return outputs that don't get built or are not executable.
    ignore_extensions = [".stripped", ".dwp", ".a"]

    # .jar files are ignored to ensure that `java_binary` lists a bunch of .jar files as rule
    # outputs. However, we always want to use the shim which is generated as the entry point.
    # On the other hand some other rules produce jar files as a real output, so we need to
    # only ignore them for java_binary rules.
    if rule.kind == "java_binary":
        ignore_extensions.append(".jar")

    output_targets = [
        t for t in rule.output_targets if not t.endswith(tuple(ignore_extensions))
    ]

    if len(output_targets) == 1:
        executable = executable_for_label(output_targets[0])
    elif len(output_targets) == 0:
        executable = executable_for_label(rule.target)
    else:
        raise BazelError(
            "invalid target '%s' - must have 1 output" % rule.target, output_targets
        )

    outputs = [executable]
    if _rule_has_runfiles(rule):
        outputs.append(executable + ".runfiles")

    return outputs


def _rule_has_runfiles(rule: BazelRule) -> bool:
    extensions_without_runfiles = (".par", ".tar", ".sqfs", ".deb", ".tgz", ".zip")

    # TODO (T192829) Arguably we should be including all rules here (as either with or
    # without runfiles, and error if unknown), to ensure for
    # accountability, and then remove extensions_without_runfiles.
    rule_kinds_without_runfiles = ("genrule", "dbx_pkg_sqfs")

    return (
        not rule.target.endswith(extensions_without_runfiles)
        and not rule.kind in rule_kinds_without_runfiles
    )


def executable_for_label(target: str) -> Text:
    if "//" in target:
        remote, target = target.split("//")
        remote = remote.lstrip("@")
    else:
        remote = ""
        target = os.path.join(os.path.relpath(os.getcwd(), find_workspace()), target)
    if remote:
        remote = os.path.join("external", remote)

    if target.endswith(":"):
        raise BazelError("invalid empty target '%s'" % target)
    if ":" in target:
        target = os.path.join(*target.split(":", 1))
    else:
        # Handle implicit names.
        target = os.path.join(target, target.split("/")[-1])
    target_path = normalize_relative_target_to_os_path(target)
    return os.path.join("bazel-bin", remote, target_path)


# Scan for args that look like targets. We have to guess because I am
# too lazy to parse bazel args correctly.
def split_args_targets(argv: List[str]) -> Tuple[List[str], List[str]]:
    args = []
    targets = []
    for x in argv:
        if x.startswith("//"):
            targets.append(x)
        else:
            args.append(x)
    return args, targets


def build_file_for_target(target: str) -> str:
    target_dir = normalize_relative_target_to_os_path(target.lstrip("//").split(":")[0])
    return os.path.join(target_dir, "BUILD")


def normalize_os_path_to_target(path: str) -> str:
    """A simple helper function that converts OS-specific path separators
    to the forward slash "/" as is used in Bazel targets."""
    return path.replace(os.path.sep, "/")


def normalize_relative_target_to_os_path(target: str) -> str:
    """A simple helper function that converts Bazel targets into paths
    with the appropriate OS-specific file separator (e.g. for use with os.path).

    Note that this is intended for use with relative targets that do not contain ":".
    Callers are expected to remove the "//" prefix if using absolute targets.
    """
    return target.replace("/", os.path.sep)


def normalize_relative_target_to_absolute(package: str, target: str) -> str:
    """
    Given a target pattern that may be relative to a package (for example, ':my_lib' or 'tests/...') and an absolute package,
    return an absolute version of the target pattern.
    If the target pattern is already absolute, it'll just be returned as-is.
    """
    if target.startswith("//"):
        return target
    colon = target.find(":")
    if colon == -1:
        return "//" + os.path.join(package, target)
    return (
        "//"
        + normalize_os_path_to_target(
            os.path.normpath(os.path.join(package, target[:colon]).rstrip("./"))
        )
        + target[colon:]
    )


def normalize_relative_target_to_absolute_cwd(target: str) -> str:
    """
    Given a target pattern that may be relative to a package (for example, ':my_lib' or 'tests/...')
    return an absolute version of the target pattern. The current package is determined by looking
    at the cwd.
    If the target pattern is already absolute, it'll just be returned as-is.
    """
    if target.startswith("//") or target.startswith("@"):
        return target

    _, _, package = find_workspace_and_package(os.getcwd())
    return normalize_relative_target_to_absolute(package[2:], target)


# If the target name is a short form label, convert it to a long form
# Note: this only supports explicit label names
def expand_short_form_label(target: str) -> str:
    if ":" in target:
        return target
    return target.rstrip(os.path.sep) + ":" + os.path.basename(os.path.normpath(target))


# A macro to build an internal tool in the background.
# Returns a path to the executable.
def build_tool(
    bazel_path: str,
    target: str,
    targets: Sequence[str] = (),
    squelch_output: bool = True,
) -> Text:
    cmd = [bazel_path, "build", target] + list(targets)
    if os.environ.get("BZL_DEBUG"):
        print("exec:", " ".join(cmd), file=sys.stderr)
    if squelch_output:
        try:
            subprocess.check_output(
                cmd, stderr=subprocess.STDOUT, universal_newlines=True
            )
        except subprocess.CalledProcessError as e:
            # Overwrite the return code to indicate this is a nested bazel failure.
            e.returncode = 255
            raise
    else:
        subprocess.check_call(cmd)

    # This is either clever or evil. Hopefully this doesn't return to haunt me.
    # BZL_BOOTSTRAP_BUILD contains the normalized command that built successfully. In modes that
    # require a build, we can check this variable for an exact match and elide a subsequent no-op
    # rebuild to save time. We can't use something more savory like a global variable because the
    # program may have called fork-exec on itself.
    os.environ["BZL_BOOTSTRAP_BUILD"] = " ".join(cmd[1:])
    return executable_for_label(target)
