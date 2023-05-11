from unittest import TestCase

from build_tools import bazel_utils
from build_tools.bzl_lib.selenium_build_util import find_test_tags


class TagsTests(TestCase):
    def test_no_tags(self) -> None:
        result = find_test_tags("")
        self.assertEqual(result, set())

    def test_single_tag(self) -> None:
        source = "@tag(Tag.Priority.P0_TEST)\ndef test_example(): pass"
        expected_tags = {"p0-server-selenium-tests"}

        result = find_test_tags(source)
        self.assertEqual(result, expected_tags)

    def test_multiple_tags(self) -> None:
        source = "@tag(Tag.Priority.P0_TEST)\n@tag(Tag.Priority.TO_DELETE)\ndef test_example(): pass"
        expected_tags = {"p0-server-selenium-tests", "test-to-delete"}
        result = find_test_tags(source)
        self.assertEqual(result, expected_tags)

    def test_multiple_tags_in_one_decorator(self) -> None:
        source = "@tag(Tag.Priority.P0_TEST, Tag.Priority.TO_DELETE)\ndef test_example(): pass"
        expected_tags = {"p0-server-selenium-tests", "test-to-delete"}
        result = find_test_tags(source)
        self.assertEqual(result, expected_tags)

    def test_partially_tagged_raises_BazelError(self) -> None:
        source = (
            "@tag(Tag.Priority.P0_TEST, Tag.Priority.TO_DELETE)\ndef test_example(): pass"
            "\ndef test_example2(): pass"
        )
        with self.assertRaises(bazel_utils.BazelError):
            find_test_tags(source)
