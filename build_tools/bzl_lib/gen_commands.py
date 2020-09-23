# mypy: allow-untyped-defs

import functools

from typing import Any, Callable, Optional, Sequence

from build_tools.bzl_lib import gazel
from build_tools.bzl_lib.generator import Config, Generator


def cmd_gen(args: Any, bazel_args, mode_args, generators) -> None:
    gazel.regenerate_build_files(
        args.targets,
        cfg=Config(
            bazel_path=args.bazel_path,
            verbose=args.verbose,
            skip_deps_generation=not args.deps_generation,
            dry_run=args.dry_run,
            use_magic_mirror=args.use_magic_mirror,
        ),
        reverse_deps_generation=args.reverse_deps_generation,
        generators=generators,
    )


def register_cmd_gen(
    sp: Any, generators: Sequence[Callable[..., Generator]], sap: Optional[Any] = None
) -> None:
    if not sap:
        sap = sp.add_parser(
            "gen", help="Generate a BUILD file or proto files for a list of targets."
        )
    sap.add_argument("--dry-run", action="store_true", help="Just show commands.")
    sap.add_argument(
        "--deps-generation",
        action="store_true",
        help="When true, do recursive dependency generation.",
    )
    sap.add_argument(
        "--reverse-deps-generation",
        action="store_true",
        help=(
            "When true, also regenerate packages that "
            "immediate depends on the specified packages."
        ),
    )
    sap.add_argument(
        "--use-magic-mirror",
        action="store_true",
        help="Use magic mirror instead the public internet",
    )
    sap.add_argument("-v", "--verbose", action="store_true")
    sap.add_argument("targets", nargs="+", help="A list of bazel targets.")
    sap.add_argument("--bazel-path", type=str, default="bazel")
    sap.set_defaults(
        func=functools.partial(cmd_gen, generators=generators),
        missing_build_file_ok=True,
    )
