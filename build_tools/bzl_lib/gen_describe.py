"""
This module is for the --describe_generator command.
It's a utility for quickly seeing which generators are available, getting a short summary or
finding detailed documentation links
"""

import inspect

from pathlib import Path
from typing import Any, Callable, DefaultDict, Dict, List, Optional, Sequence

from build_tools import bazel_utils
from build_tools.bzl_lib.generator import Config, Generator, GeneratorInfo

GEN_TABLE_KEY = "__BuildMarkdownTable"


def cmd_describe(args: Any, gen_infos: Dict[str, GeneratorInfo]) -> None:
    gen_name = args.describe_generator
    if gen_name == GEN_TABLE_KEY:
        print(generate_table(gen_infos))
    else:
        # guaranteed to be in dictionary because of "choices" restriction
        info = gen_infos[args.describe_generator]
        print(info_user_output(args.describe_generator, info))


def generate_table(infos: Dict[str, GeneratorInfo]) -> str:
    """Just a utility function for printing out a table you can put in confluence"""

    table_str = (
        "| name | description | doc_link | file |\n| --- | --- | --- | --- | --- |\n"
    )

    for info_name, info in infos.items():
        table_str += f"| {info_name} |  {' '.join(info.description.split())} | {info.doc_link} | {info.file_name} | \n"

    return table_str


def generator_infos(
    generators: Sequence[Callable[..., Generator]],
    cfg: Optional[Config],
) -> Dict[str, GeneratorInfo]:
    """Builds out a map of GeneratorInfo for each of the generators provided by instantiating them"""
    workspace_dir = bazel_utils.find_workspace()
    generated_files = DefaultDict[str, List[str]](list)

    generator_instances: List[Generator] = []
    for gen in generators:
        generator_instances.append(gen(workspace_dir, generated_files, cfg))

    gen_info_map = {}
    for gi in generator_instances:
        name = str(gi.__class__.__name__)
        file_name = Path(inspect.getfile(gi.__class__)).name.strip()

        gi_info = gi.info()

        # Enrich what we have in GeneratorInfo
        gi_info.file_name = file_name

        gen_info_map[name] = gi_info

    return gen_info_map


def info_user_output(name: str, info: GeneratorInfo) -> str:
    info_str = f"-- {name} -- \n{info.description}"
    if info.doc_link is not None:
        info_str += f"\nDetailed Documentation: {info.doc_link}"

    return info_str
