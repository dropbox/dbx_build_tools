# mypy: allow-untyped-defs

from __future__ import annotations

import ast
import os.path

from pathlib import Path
from typing import List, Mapping, MutableMapping, NamedTuple, Set, Tuple

from build_tools.bzl_lib.parse_py_imports import normalize_module
from build_tools.py.bazel_validation.builtins import BUILTIN_MODULES

SourceLocation = NamedTuple("SourceLocation", [("source_file", Path), ("lineno", int)])

Import = NamedTuple(
    "Import",
    [
        # slight misnomer; could be a module or an item from a module, but we can't tell
        ("module", str),
        ("location", SourceLocation),
        ("is_from", bool),
    ],
)

DependencyValidationResult = NamedTuple(
    "DependencyValidationResult",
    [("unresolved_imports", List[Import]), ("unused_targets", Set[str])],
)


class AmbiguousModuleException(Exception):
    pass


def parse_imports(source_file: Path, pythonpath=None) -> List[Import]:
    if not pythonpath:
        pythonpath = "."

    with source_file.open("rb") as f:
        content = f.read()

    parsed = ast.parse(content, str(source_file))

    # We need the path relative to the pythonpath here so that normalize_module
    # will return the correct import name for relative imports
    rel_source_file = os.path.relpath(str(source_file), pythonpath)

    imports = []
    for node in ast.walk(parsed):
        if isinstance(node, ast.Import):
            for entry in node.names:
                imports.append(
                    Import(
                        module=normalize_module(rel_source_file, entry.name),
                        location=SourceLocation(
                            source_file=source_file, lineno=node.lineno
                        ),
                        is_from=False,
                    )
                )
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                assert node.level is not None
                prefix = ("." * node.level) + node.module
            else:
                assert node.level is not None
                assert node.level > 0
                prefix = "." * (node.level - 1)
            for entry in node.names:
                imports.append(
                    Import(
                        module=normalize_module(
                            rel_source_file, prefix + "." + entry.name
                        ),
                        location=SourceLocation(
                            source_file=source_file, lineno=node.lineno
                        ),
                        is_from=True,
                    )
                )

    return imports


def flatten_provides(
    primary_target: str, target_provides: List[Tuple[str, str]]
) -> Mapping[str, str]:
    provides_map: MutableMapping[str, str] = {}
    for target, provides in target_provides:
        if target != primary_target:
            # we only allow conflicts with the actual target (often the cause for dbx_py_binary with main
            # which is in some library)
            if provides in provides_map:
                raise AmbiguousModuleException(
                    "More than one dependency provides the module {}".format(provides)
                )
            assert provides not in provides_map
            provides_map[provides] = target

    # Ensure that the main target provides its sources directly by overriding it in a separate path
    for target, provides in target_provides:
        if target == primary_target:
            provides_map[provides] = target

    return provides_map


def flatten_provides_prefix(
    target_provides_prefix: List[Tuple[str, str]]
) -> Mapping[str, str]:
    prefix_provides_map: MutableMapping[str, str] = {}
    for target, provides in target_provides_prefix or []:
        if provides in prefix_provides_map:
            raise AmbiguousModuleException(
                "More than one dependency provides the module {}".format(provides)
            )
        prefix_provides_map[provides] = target
    return prefix_provides_map


def validate_bazel_deps(
    imports: List[Import],
    primary_target: str,
    provides_map: Mapping[str, str],
    prefix_provides_map: Mapping[str, str],
) -> DependencyValidationResult:
    system_modules = BUILTIN_MODULES

    target_set: Set[str] = set()
    target_set.update(provides_map.values())
    target_set.update(prefix_provides_map.values())

    unresolved_imports: List[Import] = []
    unused_targets = set()

    # Add primary_target to targets_used so we don't assert that we use it
    targets_used = set([primary_target])
    for i in imports:
        # This is used for thirdparty modules which generally provide something like `grpc` which includes `grpc.<anything>`
        found_prefix = False
        # NOTE(jhance) We are iterating in reverse order of prefix length so that for example
        # we see flask.ext.restful before flask, which results in us marking the correct target
        # as used.
        for prefix, target in reversed(
            sorted(prefix_provides_map.items(), key=lambda kv: len(kv[0]))
        ):
            if i.module.startswith(prefix + ".") or i.module == prefix:
                found_prefix = True
                targets_used.add(target)
                break

        if found_prefix:
            continue

        # There are two cases here.
        # 1) The import is of the form 'from dropbox.runfiles import data_path`
        # 2) The import is of the form `import dropbox.runfiles` or 'from dropbox import runfiles'
        # Note in the case of (2), if we are missing //dropbox:runfiles but we have //dropbox, which contains
        # __init__.py and thus provides the module `dropbox` then we will mistakenly think that we are importing
        # from dropbox and allow it.
        #
        # This checks case (2)
        if i.module in provides_map:
            targets_used.add(provides_map[i.module])
            continue

        # This checks case (1), but only for 'from' style imports
        if i.is_from:
            assert "." in i.module
            short_i = ".".join(i.module.split(".")[:-1])
            if short_i in provides_map:
                targets_used.add(provides_map[short_i])
                continue

        # Filter out anything that looks like a system module
        if i.module in system_modules:
            continue
        found_sys_prefix = False
        for sys_module in system_modules:
            if i.module.startswith(sys_module + "."):
                found_sys_prefix = True
                break
        if found_sys_prefix:
            continue

        unresolved_imports.append(i)

    for target in target_set:
        if target not in targets_used:
            unused_targets.add(target)

    return DependencyValidationResult(
        unresolved_imports=unresolved_imports, unused_targets=unused_targets
    )
