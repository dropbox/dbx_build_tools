from __future__ import annotations

import ast
import os

from typing import List, Set

from build_tools import bazel_utils, build_parser

"""
TEST TAG TO TARGET TAG MAP FOR BZL GEN to ADD THE APPROPRIATE TARGET_TAGS TO SELENIUM TEST TARGETS
"""
TARGET_TAG_MAP = {
    "P0_TEST": "p0-server-selenium-tests",
    "P1_TEST": "p1-server-selenium-tests",
    "TO_DELETE": "test-to-delete",
}

"""
FUNCTION TO ADD TARGET TAG LIST WHEN BUILDING SELENIUM TARGET
"""


def build_target_tags(
    pkg: str, rule: build_parser.Rule, output: List[str]
) -> List[str]:
    srcs = build_parser.maybe_expand_attribute(rule.attr_map.get("srcs", None))
    tags = set()
    for src in set(srcs):
        src = os.path.join(pkg[2:], src)
        content = get_src_content(src)
        tags.update(find_test_tags(content))
    # append target tags only if tags were found
    if tags:
        output.append("    target_tags = [")
        sorted_tag = sorted(list(tags))
        for target_tag in sorted_tag:
            output.append("        '%s'," % target_tag)
        output.append("    ],")
    return output


"""
FUNCTION TO RETRIEVE CONTENT FORM SRC FILE
"""


def get_src_content(curr_src_file: str) -> str:
    with open(curr_src_file) as file:
        return file.read()


"""
FUNCTION TO FIND ALL SELENIUM TEST TAGS IN A PYTHON SOURCE FILE
"""


def find_test_tags(content: str) -> Set[str]:
    tag_set: Set[str] = set()
    targets_tags: List[str] = []
    tree = ast.parse(content)
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef):
            for decorator in node.decorator_list:
                if (
                    isinstance(decorator, ast.Call)
                    and isinstance(decorator.func, ast.Name)
                    and decorator.func.id == "tag"
                ):
                    for arg in decorator.args:
                        if (
                            isinstance(arg, ast.Attribute)
                            and isinstance(arg.value, ast.Attribute)
                            and getattr(arg.value, "value", None)
                            and getattr(arg.value.value, "id", None) == "Tag"
                        ):
                            targets_tags.append(arg.attr)
    for tag in set(targets_tags):
        if tag in TARGET_TAG_MAP:
            tag_set.add(TARGET_TAG_MAP[tag])
        else:
            raise bazel_utils.BazelError(
                "Unsupported test tag: '{}' found Supported tags are {}'".format(
                    tag, ", ".join(TARGET_TAG_MAP.keys())
                )
            )
    return tag_set
