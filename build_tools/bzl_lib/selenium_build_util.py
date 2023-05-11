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


def build_target_tags(
    pkg: str, rule: build_parser.Rule, output: List[str]
) -> List[str]:
    """
    FUNCTION TO ADD TARGET TAG LIST WHEN BUILDING SELENIUM TARGET
    """
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


def get_src_content(curr_src_file: str) -> str:
    """
    FUNCTION TO RETRIEVE CONTENT FORM SRC FILE
    """
    with open(curr_src_file) as file:
        return file.read()


def find_test_tags(content: str) -> Set[str]:
    """
    FUNCTION TO FIND ALL SELENIUM TEST TAGS IN A PYTHON SOURCE FILE
    """
    tag_set: Set[str] = set()
    targets_tags: List[str] = []
    tree = ast.parse(content)
    # map to store each test and the associated tags with that test
    test_name_dict: dict[str, int] = dict()

    for node in ast.walk(tree):

        if (
            isinstance(node, ast.FunctionDef)
            and hasattr(node, "name")
            and node.name.startswith("test_")
        ):
            tag_count = 0
            for decorator in node.decorator_list:
                if (
                    isinstance(decorator, ast.Call)
                    and isinstance(decorator.func, ast.Name)
                    and decorator.func.id == "tag"
                ):
                    tag_count += 1
                    for arg in decorator.args:
                        if (
                            isinstance(arg, ast.Attribute)
                            and isinstance(arg.value, ast.Attribute)
                            and getattr(arg.value, "value", None)
                            and getattr(arg.value.value, "id", None) == "Tag"
                        ):
                            targets_tags.append(arg.attr)

            test_name_dict[node.name] = tag_count

    for tag in set(targets_tags):
        if tag in TARGET_TAG_MAP:
            tag_set.add(TARGET_TAG_MAP[tag])
        else:
            raise bazel_utils.BazelError(
                "Unsupported test tag: '{}' found Supported tags are {}'".format(
                    tag, ", ".join(TARGET_TAG_MAP.keys())
                )
            )

    # Check Allow target to build if there are no tagged tests
    if is_all_test_untagged(test_name_dict):
        return tag_set

    # Allow target to build if 100% of the tests in target are tagged
    # Raise error fif target is partially tagged
    missing_test_list = get_untagged_tests(test_name_dict)

    if missing_test_list:
        raise bazel_utils.BazelError(
            f"The following tests are missing @tags {missing_test_list}.  See \n"
            "https://dropbox-kms.atlassian.net/wiki/spaces/TESTINFRA/pages/922649173/Test+Cast+Tagging+Selenium"
            "+Python+E2E"
        )

    return tag_set


def is_all_test_untagged(map_of_test: dict[str, int]) -> bool:
    """
    Check if any test in the target was tagged. Has a value > 0
    returns true if all values == 0 and false if not
    """

    return all(tag_count == 0 for tag_count in map_of_test.values())


def get_untagged_tests(map_of_test: dict[str, int]) -> List[str]:
    """fuction to get list of untagged test in map"""
    return [test_name for test_name, tag_count in map_of_test.items() if tag_count == 0]
