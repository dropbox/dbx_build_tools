#!/usr/bin/env python

# mypy: allow-untyped-defs

import argparse
import os
import subprocess
import sys
import time

from xml.sax import saxutils

XML_TMPL = """<?xml version="1.0" encoding="utf-8"?>
<testsuite name="{suite_name}" time="{time}" errors="0" failures="{fail}" skips="0" tests="1">
    <testcase classname="{class_name}" name="{test_name}" time="{time}">
{failure_element}
    </testcase>
</testsuite>"""

FAIL_TMPL = """        <failure message="{message}">{output}</failure>"""

OUTPUT_TMPL = """
==================== stdout ====================

{stdout}

==================== stderr ====================

{stderr}
"""


def run(
    suite_name, class_name, test_name, args, fail_stdout, fail_stderr, xml_path=None
):

    start_time = time.time()

    with open(os.devnull, "w") as dev_null:
        cmd = subprocess.Popen(
            args,
            stdin=dev_null,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            encoding="utf-8",
        )
        (stdout, stderr) = cmd.communicate()

    elapsed_time = time.time() - start_time

    message = None
    if cmd.returncode != 0:
        message = "Got returncode: {}".format(cmd.returncode)
    elif fail_stdout and stdout:
        message = "Output on stdout"
    elif fail_stderr and stderr:
        message = "Output on stderr"

    output = OUTPUT_TMPL.format(stdout=stdout, stderr=stderr)

    if message is not None:
        print(message)
        print(output)

    if xml_path:
        if message is not None:
            failure_element = FAIL_TMPL.format(
                message=message, output=saxutils.escape(output)
            )
        else:
            failure_element = ""

        xml = XML_TMPL.format(
            suite_name=suite_name,
            time=elapsed_time,
            fail=int(message is not None),
            class_name=class_name,
            test_name=test_name,
            failure_element=failure_element,
        )

        with open(xml_path, "w") as fp:
            fp.write(xml)

    return message is None


def main():
    parser = argparse.ArgumentParser(description="junit sh_test wrapper.")
    parser.add_argument(
        "--fail_stdout",
        action="store_true",
        help="Fail test if there's any output on stdout.",
    )
    parser.add_argument(
        "--fail_stderr",
        action="store_true",
        help="Fail test if there's any output on stderr.",
    )
    parser.add_argument("--verbose", "-v", action="count")
    parser.add_argument("--junit_suite_name")
    parser.add_argument("--junit_class_name")
    parser.add_argument("--junit_test_name")
    parser.add_argument("args", nargs=argparse.REMAINDER)

    args = parser.parse_args()

    xml_path = os.environ.get("XML_OUTPUT_FILE", None)

    return run(
        suite_name=args.junit_suite_name,
        class_name=args.junit_class_name,
        test_name=args.junit_test_name,
        args=args.args,
        fail_stdout=args.fail_stdout,
        fail_stderr=args.fail_stderr,
        xml_path=xml_path,
    )


if __name__ == "__main__":
    sys.exit(not main())
