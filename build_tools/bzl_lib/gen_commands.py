# mypy: allow-untyped-defs

import argparse
import functools

from typing import Any, Callable, Optional, Sequence

from build_tools.bzl_lib import gazel
from build_tools.bzl_lib.gen_describe import (
    cmd_describe,
    GEN_TABLE_KEY,
    generator_infos,
)
from build_tools.bzl_lib.generator import Config, Generator


def cmd_gen(args: Any, bazel_args, mode_args, generators) -> None:
    cfg = Config(
        bazel_path=args.bazel_path,
        verbose=args.verbose,
        skip_deps_generation=not args.deps_generation,
        dry_run=args.dry_run,
        use_magic_mirror=args.use_magic_mirror,
        use_artifactory=args.use_artifactory,
        use_public_internet=args.use_public_internet,
    )

    if args.describe_generator is not None:
        gen_infos = generator_infos(generators, cfg)
        cmd_describe(args, gen_infos)

    else:
        gazel.regenerate_build_files(
            args.targets,
            cfg=cfg,
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
    sap.add_argument(
        "--use-artifactory",
        action="store_true",
        help="Use artifactory instead the public internet",
    )
    sap.add_argument(
        "--use-public-internet",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Allow use of public internet.",
    )
    sap.add_argument("-v", "--verbose", action="store_true")
    sap.add_argument("targets", nargs="+", help="A list of bazel targets.")
    sap.add_argument("--bazel-path", type=str, default="bazel")

    sap.add_argument(
        "--describe_generator",
        metavar="",  # 'metavar' to simply remove the "choices" from showing up in the --help
        type=str,
        choices=list(generator_infos(generators, None)) + [GEN_TABLE_KEY],
        required=False,
        help=f"Usage 'bzl gen . --describe_generator <choice>'. Get info about a particular code generator. Use '{GEN_TABLE_KEY}' to get the entire list",
    )
    sap.set_defaults(
        func=functools.partial(cmd_gen, generators=generators),
        missing_build_file_ok=True,
    )
