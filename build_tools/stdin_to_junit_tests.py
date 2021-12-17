import subprocess
import tempfile

import pytest

from dropbox import runfiles


def test_stdin_to_junit_missing_arguments() -> None:
    with pytest.raises(subprocess.CalledProcessError) as e:
        subprocess.check_output([runfiles.data_path("@dbx_build_tools//build_tools/stdin_to_junit")])
    assert e.value.returncode == 1


def test_stdin_to_junit_no_stdin() -> None:
    with tempfile.NamedTemporaryFile() as xml_output:
        assert (
            subprocess.check_output(
                (runfiles.data_path("@dbx_build_tools//build_tools/stdin_to_junit"), "class", "test"),
                env={"XML_OUTPUT_FILE": xml_output.name},
            )
            == b""
        )
        assert xml_output.read().decode("utf-8") == (
            '<testsuite tests="1" time="0.000">          '
            '<testcase classname="class" name="test" time="0.000" />        '
            "</testsuite>"
        )


def test_stdin_to_junit() -> None:
    message = "test error"
    echo = subprocess.Popen(["echo"] + message.split(" "), stdout=subprocess.PIPE)
    with tempfile.NamedTemporaryFile() as xml_output:
        stdin_to_junit = subprocess.Popen(
            (runfiles.data_path("@dbx_build_tools//build_tools/stdin_to_junit"), "class", "method"),
            stdin=echo.stdout,
            stdout=subprocess.PIPE,
            env={"XML_OUTPUT_FILE": xml_output.name},
        )
        echo.wait()
        stdin_to_junit.wait()
        assert stdin_to_junit.returncode == 1  # because we have input
        assert stdin_to_junit.stdout
        # We have to make sure that stdin_to_junit outputs without modification received data from stdin,
        # otherwise we will miss piped output.
        assert stdin_to_junit.stdout.read().decode("utf-8").strip() == message
        assert xml_output.read().decode("utf-8") == (
            '<testsuite tests="1" time="0.000">          '
            '<testcase classname="class" name="method" time="0.000">            '
            '<failure type="test failed">test error\n</failure>          '
            "</testcase>        "
            "</testsuite>"
        )
