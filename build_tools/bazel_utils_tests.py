# mypy: allow-untyped-defs

from xml.dom import minidom  # type: ignore[import]

import pytest

from build_tools import bazel_utils

# Trimmed version of some actual query output
EXAMPLE_XML = """<?xml version="1.1" encoding="UTF-8" standalone="no"?>
<query version="2">
<rule class="genrule" location="/home/jhance/src/server/java/clogger/BUILD:5:1" name="//java/clogger:clogger-kafka-connect">
<string name="name" value="clogger-kafka-connect"/>
<list name="srcs">
<label value="//java/clogger:.gitignore"/>
<label value="//java/clogger:BUILD"/>
<label value="//java/clogger:kafka-connect/src/test/java/com/dropbox/clogger/kafka/connect/TestUtils.java"/>
<label value="//java/clogger:kafka-connect/src/test/resources/sample-schema.avsc"/>
<label value="//java/clogger:project/build.properties"/>
<label value="//java/clogger:project/plugins.sbt"/>
<label value="//java/clogger:ruleset.xml"/>
<label value="//java/clogger:scalastyle-config.xml"/>
<label value="//java/src/main/java/com/dropbox/dblogger:dblogger"/>
<label value="//java/src/main/java/com/dropbox/dbjson:dbjson"/>
</list>
<output name="out" value="//java/clogger:clogger-kafka-connect.jar"/>
<list name="args">
<string value="-DdbloggerJarPath=$ROOTDIR/$(location //java/src/main/java/com/dropbox/dblogger)"/>
<string value="-DdbjsonJarPath=$ROOTDIR/$(location //java/src/main/java/com/dropbox/dbjson)"/>
<string value="kafka-connect/assembly"/>
</list>
<string name="output_path" value="kafka-connect/target/scala-2.11"/>
<string name="package_dir" value="java/clogger"/>
<rule-input name="@sbt//:bin/sbt"/>
<rule-output name="//java/clogger:clogger-kafka-connect.jar"/>
</rule>
</query>
"""

PY_BINARY_RULE = bazel_utils.BazelRule(
    target="//build_tools:bzl", kind="dbx_py_binary", output_targets=[]
)

JAR_BUILD_RULE = bazel_utils.BazelRule(
    target="//java/clogger:clogger-kafka-connect",
    kind="genrule",
    output_targets=["//java/clogger:clogger-kafka-connect.jar"],
)

JAVA_BINARY_RULE = bazel_utils.BazelRule(
    target="//java/src/main/java/com/dropbox/mahalotranslator:MahaloTranslator",
    kind="java_binary",
    output_targets=[
        "//java/src/main/java/com/dropbox/mahalotranslator:MahaloTranslator.jar",
        "//java/src/main/java/com/dropbox/mahalotranslator:MahaloTranslator-src.jar",
        "//java/src/main/java/com/dropbox/mahalotranslator:MahaloTranslator_deploy.jar",
        "//java/src/main/java/com/dropbox/mahalotranslator:MahaloTranslator_deploy-src.jar",
    ],
)

INVALID_RULE = bazel_utils.BazelRule(
    target="//foo:bar", kind="foo_bar", output_targets=["//foo:xx", "//foo:yy"]
)


def test_normalize_target_abs_path():
    for label, normalized_label in [
        ("//services/metaserver", "//services/metaserver:metaserver"),
        ("//services/metaserver:metaserver", "//services/metaserver:metaserver"),
    ]:
        assert bazel_utils.BazelTarget(label).label == normalized_label


def test_normalize_target_rel_path():
    for label, normalized_label, cwd in [
        ("services/metaserver", "//services/metaserver:metaserver", "/<WORKSPACE>"),
        (
            "services/metaserver:metaserver",
            "//services/metaserver:metaserver",
            "/<WORKSPACE>",
        ),
        ("metaserver", "//services/metaserver:metaserver", "/<WORKSPACE>/services"),
        (
            "metaserver:metaserver",
            "//services/metaserver:metaserver",
            "/<WORKSPACE>/services",
        ),
        (
            ":metaserver",
            "//services/metaserver:metaserver",
            "/<WORKSPACE>/services/metaserver",
        ),
    ]:
        assert (
            bazel_utils.BazelTarget(label, cwd=cwd, workspace="/<WORKSPACE>").label
            == normalized_label
        )


def test_rules_from_xml_doc():
    rules = bazel_utils._rules_from_xml_doc(minidom.parseString(EXAMPLE_XML))
    assert len(rules) == 1
    assert rules[0].target == "//java/clogger:clogger-kafka-connect"
    assert rules[0].kind == "genrule"
    assert rules[0].output_targets == ["//java/clogger:clogger-kafka-connect.jar"]


def test_outputs_for_rule_py_binary():
    outputs = bazel_utils._outputs_for_rule(PY_BINARY_RULE)
    assert len(outputs) == 2
    assert "bazel-bin/build_tools/bzl" in outputs
    assert "bazel-bin/build_tools/bzl.runfiles" in outputs


def test_outputs_for_rule_genrule_like():
    outputs = bazel_utils._outputs_for_rule(JAR_BUILD_RULE)
    assert len(outputs) == 1
    assert "bazel-bin/java/clogger/clogger-kafka-connect.jar" in outputs


def test_outputs_for_java_binary():
    outputs = bazel_utils._outputs_for_rule(JAVA_BINARY_RULE)
    assert len(outputs) == 2
    assert (
        "bazel-bin/java/src/main/java/com/dropbox/mahalotranslator/MahaloTranslator"
        in outputs
    )
    assert (
        "bazel-bin/java/src/main/java/com/dropbox/mahalotranslator/MahaloTranslator.runfiles"
        in outputs
    )


def test_outputs_for_rule_with_too_many_outputs():
    with pytest.raises(bazel_utils.BazelError):
        bazel_utils._outputs_for_rule(INVALID_RULE)


def test_outputs_for_rules():
    outputs_map = bazel_utils._outputs_for_rules(
        [PY_BINARY_RULE, JAR_BUILD_RULE, JAVA_BINARY_RULE]
    )

    # Lightweight test is enough here, because we are already testing the
    # functionality well above.
    assert len(outputs_map.keys()) == 3


def test_normalize_relative_target_to_absolute() -> None:
    norm = bazel_utils.normalize_relative_target_to_absolute
    assert norm("foo/bar", "actions/...") == "//foo/bar/actions/..."
    assert norm("foo/bar", ":baz") == "//foo/bar:baz"
    assert norm("foo/bar", "../wat:baz") == "//foo/wat:baz"
    assert norm("foo/bar", "//already/absolute") == "//already/absolute"
    assert norm("foo/bar", "@other//already/absolute") == "@other//already/absolute"


def test_expand_short_form_label() -> None:
    expand = bazel_utils.expand_short_form_label

    # relative
    assert expand("foo/bar:baz") == "foo/bar:baz"
    assert expand("foo/bar") == "foo/bar:bar"
    assert expand("foo/bar/") == "foo/bar:bar"

    # absolute
    assert expand("//foo/bar:baz") == "//foo/bar:baz"
    assert expand("//foo/bar") == "//foo/bar:bar"
    assert expand("//foo/bar/") == "//foo/bar:bar"

    # no subdirectory
    assert expand("foo") == "foo:foo"
    assert expand("//foo") == "//foo:foo"
    assert expand("foo:bar") == "foo:bar"
    assert expand("//foo:bar") == "//foo:bar"


def test_parse_bazel_label() -> None:
    parse = bazel_utils.parse_bazel_label
    assert parse("//a/b:c") == ("__main__", "a/b", "c")
    assert parse("//a/b") == ("__main__", "a/b", "b")
    assert parse("//a") == ("__main__", "a", "a")
    assert parse("//:top") == ("__main__", "", "top")

    assert parse("@other//a/b:c") == ("other", "a/b", "c")
    assert parse("@other//a/b") == ("other", "a/b", "b")
    assert parse("@other//a") == ("other", "a", "a")
    assert parse("@other//:top") == ("other", "", "top")

    # Apparently legal, according to https://bazel.build/concepts/labels
    assert parse("//a/b:some/file.txt") == ("__main__", "a/b", "some/file.txt")

    with pytest.raises(bazel_utils.BazelError):
        parse("other//a/b:c")
    with pytest.raises(bazel_utils.BazelError):
        parse("a/b:c")
    with pytest.raises(bazel_utils.BazelError):
        parse("//a/b/")
    with pytest.raises(bazel_utils.BazelError):
        parse("//a/b/:c")
    with pytest.raises(bazel_utils.BazelError):
        parse("//a:")
