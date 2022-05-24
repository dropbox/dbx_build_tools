#!/bin/bash -e

target="$1"
shift
test_exec="$1"
shift

if [[ -n "$COVERAGE_OUTPUT_FILE" ]]; then
    coverage_out=$(mktemp)
else
    coverage_out=""
fi

temp=$(mktemp)

# Set +e for this block so that we can get the retcode
set +e
# -test.v is required to obtain the full event log for JUnit creation.
"$test_exec" -test.coverprofile="$coverage_out" -test.v -test.outputdir="${TEST_UNDECLARED_OUTPUTS_DIR}" -test.failfast="${TESTBRIDGE_TEST_RUNNER_FAIL_FAST:-0}" "$@" | tee "$temp"
retcode=${PIPESTATUS[0]}
set -e

"$RUNFILES/../dbx_build_tools/../go_1_18_linux_amd64_tar_gz/go/pkg/tool/linux_amd64/test2json" < "$temp" -t | "$RUNFILES/../dbx_build_tools/go/src/dropbox/build_tools/gojunit/gojunit/gojunit" -target "$target"

if [[ -n "$COVERAGE_OUTPUT_FILE" ]]; then
    "$RUNFILES/../dbx_build_tools/go/src/dropbox/build_tools/gocov2cobertura/gocov2cobertura" < "$coverage_out" > "$COVERAGE_OUTPUT_FILE"
fi

exit "$retcode"
