from build_tools import build_parser

BUILD_WITHOUT_SELECT = """
package(default_visibility=["//visibility:private"])

rule1(
    name = "a",
    srcs = ["e", "f"],
    main = "g",
    testonly = True,
)

rule2(
    name = "b",
    srcs = ["y", "z"],
)
"""

BUILD_WITH_SELECT = """
rule1(
    name = "a",
    srcs = [
        "common1",
        "common2",
    ] + select({
        "//conditions:windows": [
            "windows1",
            "windows2",
        ],
        "//conditions:osx": [
            "osx1",
            "osx2",
        ],
        "//conditions:linux": [
            "linux1",
        ],
    }),
    tags = ["hello"],
)
"""


BUILD_WITH_STRUCT = """
load("@bazel_skylib//lib:selects.bzl", "selects")

config_setting(
    name = "sunny",
    define_values = {
        "sunny": "1",
    },
)

config_setting(
    name = "warm",
    define_values = {
        "warm": "1",
    },
)

selects.config_setting_group(
    name = "perfect-day",
    match_all = [
        ":warm",
        ":sunny",
    ],
)
"""


def test_parse_basic_build_file():
    # type: () -> None
    """Ensures that we can parse simple BUILD files."""
    bp = build_parser.parse(BUILD_WITHOUT_SELECT)

    assert bp.default_visibility() == ["//visibility:private"]

    rule1 = bp.get_rule("a")
    assert rule1.attr_map["name"] == "a"
    assert rule1.attr_map["srcs"] == ["e", "f"]
    assert rule1.attr_map["main"] == "g"
    assert rule1.attr_map["testonly"] is True

    rule2_rules = bp.get_rules_by_types(["rule2"])
    assert len(rule2_rules) == 1
    assert rule2_rules[0].attr_map["name"] == "b"
    assert rule2_rules[0].attr_map["srcs"] == ["y", "z"]


def test_build_with_select():
    # type: () -> None
    """Ensures that we can parse BUILD files with select() clauses,
    and that they are appropriately preserved in rules."""
    bp = build_parser.parse(BUILD_WITH_SELECT)
    rule = bp.get_rule("a")
    assert rule.attr_map["name"] == "a"

    expanded_srcs = build_parser.maybe_expand_attribute(rule.attr_map["srcs"])
    expected_srcs = set(
        ["common1", "common2", "windows1", "windows2", "osx1", "osx2", "linux1"]
    )
    assert len(expanded_srcs) == 7
    assert set(expanded_srcs) == expected_srcs

    raw_srcs = rule.attr_map["srcs"]
    assert len(raw_srcs) == 3

    select_item = None
    for val in raw_srcs:
        if isinstance(val, build_parser.Select):
            select_item = val
    assert select_item

    assert len(select_item.select_map) == 3
    assert select_item.select_map["//conditions:windows"] == ["windows1", "windows2"]
    assert select_item.select_map["//conditions:osx"] == ["osx1", "osx2"]
    assert select_item.select_map["//conditions:linux"] == ["linux1"]


def test_select_aware_repr():
    # type: () -> None
    """Ensures that we can get a Starlark-valid string representation of a select()
    clause."""
    bp = build_parser.parse(BUILD_WITH_SELECT)
    rule = bp.get_rule("a")
    raw_srcs = rule.attr_map["srcs"]

    # To check the repr func, we re-parse the repr and see if the data is all the same.
    rewritten_build = "rule1(name='a', srcs={})".format(
        build_parser.get_select_aware_attribute_repr(raw_srcs)
    )
    bp2 = build_parser.parse(rewritten_build)
    new_rule = bp2.get_rule("a")

    expanded_srcs = build_parser.maybe_expand_attribute(new_rule.attr_map["srcs"])
    expected_srcs = set(
        ["common1", "common2", "windows1", "windows2", "osx1", "osx2", "linux1"]
    )
    assert len(expanded_srcs) == 7
    assert set(expanded_srcs) == expected_srcs

    new_raw_srcs = new_rule.attr_map["srcs"]
    assert len(new_raw_srcs) == 3

    new_select_item = None
    for val in new_raw_srcs:
        if isinstance(val, build_parser.Select):
            new_select_item = val
    assert new_select_item

    assert len(new_select_item.select_map) == 3
    assert new_select_item.select_map["//conditions:windows"] == [
        "windows1",
        "windows2",
    ]
    assert new_select_item.select_map["//conditions:osx"] == ["osx1", "osx2"]
    assert new_select_item.select_map["//conditions:linux"] == ["linux1"]


def test_build_with_structs():
    # type: () -> None
    """Ensures that build_parser doesn't choke on BUILD files that load
    structs."""
    bp = build_parser.parse(BUILD_WITH_STRUCT)

    rule = bp.get_rule("perfect-day")
    assert rule.rule_type == "selects.config_setting_group"
    assert rule.attr_map["match_all"] == [":warm", ":sunny"]
