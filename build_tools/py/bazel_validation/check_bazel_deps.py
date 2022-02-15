import argparse
import sys

from pathlib import Path
from typing import List, Tuple

from build_tools.py.bazel_validation.bazel_deps import (
    flatten_provides,
    Import,
    parse_imports,
    validate_bazel_deps,
)


def _split_equal(s: str) -> Tuple[str, str]:
    spli = s.split("=")
    assert len(spli) == 2
    return spli[0], spli[1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--src", action="append", help="a file to check the imports of")
    parser.add_argument(
        "--target-provides",
        action="append",
        help="Format target=module. Indicates that a target provides a module",
    )
    parser.add_argument(
        "--target-provides-prefix", action="append", help="Format target=moduleprefix"
    )
    parser.add_argument("--target", help="name of actual target")
    parser.add_argument("--pythonpath", help="pythonpath of bazel target")
    parser.add_argument(
        "--allow-unused-targets",
        action="store_true",
        help="Allow unused depndencies, useful when using additional_deps for automagically imported things",
    )
    args = parser.parse_args()

    primary_target = args.target
    imports = []  # type: List[Import]
    for src in args.src:
        imports.extend(
            parse_imports(
                source_file=Path(src),
                pythonpath=args.pythonpath,
            )
        )

    result = validate_bazel_deps(
        imports=imports,
        primary_target=primary_target,
        provides_map=flatten_provides(
            primary_target, [_split_equal(t) for t in args.target_provides or []]
        ),
        prefix_provides_map=flatten_provides(
            primary_target, [_split_equal(t) for t in args.target_provides_prefix or []]
        ),
    )
    if (
        result.unresolved_imports
        or result.unused_targets
        and not args.allow_unused_targets
    ):
        # Force a newline so that the output stands out better, making it easier to
        # reads the logs from bazel output
        print("")
        print(
            "=========== import validation failures (target {})".format(primary_target)
        )
        print("to run locally, try using:")
        print(
            "bazel build --aspects=build_tools/py/bazel_validation/import_validation.bzl%dbx_py_validate_imports --output_groups=py_import_validation_files {}".format(
                primary_target
            )
        )
        for i in result.unresolved_imports:
            print(
                "  unresolved import ({}:{}): {}".format(
                    i.location.source_file, i.location.lineno, i.module
                )
            )
        if not args.allow_unused_targets:
            for t in result.unused_targets:
                print("  unused dependency: {}".format(t))
        print("")
        sys.exit(1)


if __name__ == "__main__":
    main()
