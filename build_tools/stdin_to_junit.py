# mypy: allow-untyped-defs

""" This file is a short utility which makes it easy to dump the stdout of
    another executable to a junit.xml file when run in changes.

    It's intended to be used like:

        set -o pipefail && <command> | build_tools/stdin_to_junit <testclass> <testname>
"""

import os
import re
import string
import sys
import time

from xml.sax.saxutils import escape


def printable(line):
    ansi_escape = re.compile(r"(\x9B|\x1B\[)[0-?]*[ -/]*[@-~]")
    removed_ansi = ansi_escape.sub("", line)
    return "".join(c for c in removed_ansi if c in string.printable)


def main():
    start = time.time()
    stdin_lines = sys.stdin.readlines()
    duration = time.time() - start

    # Write stdin to stdout line-by-line, instead of the previous `print stdin` that mysteriously
    # failed with a "IOError: [Errno 11] Resource temporarily unavailable"
    for line in stdin_lines:
        sys.stdout.write(line)

    # if there's no output, assume the test passed.
    # the exit code is the real measure of this but changes seems to assume
    # if there's a .xml file output with a <failure /> that it means the
    # test failed.
    stdin = "\n".join(stdin_lines)
    if stdin:
        junit_template = """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuite tests="1" time="%(duration).3f">
          <testcase classname="%(classname)s" name="%(testname)s" time="%(duration).3f">
            <failure type="test failed">%(input)s</failure>
          </testcase>
        </testsuite>
        """.strip().replace(
            "\n", ""
        )
        exit_code = 1
    else:
        junit_template = """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuite tests="1" time="%(duration).3f">
          <testcase classname="%(classname)s" name="%(testname)s" time="%(duration).3f" />
        </testsuite>
        """.strip().replace(
            "\n", ""
        )
        exit_code = 0

    output_file = os.environ.get("XML_OUTPUT_FILE", "/dev/null")
    with open(output_file, "w") as f:  # type: ignore[arg-type]
        f.write(
            junit_template
            % dict(
                duration=duration,
                classname=escape(sys.argv[1]),
                testname=escape(sys.argv[2]),
                input=escape(printable(stdin)),
            )
        )

    # changes gets the failures from junit.xml, but bazel only respects the
    # exit code.  In some typechecking cases, tsc "fails" with output about the
    # configuration being invalid but gives an exit code of 0; we want bazel
    # test to be consistent with changes and fail in these cases, so we have
    # to exit(1)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
