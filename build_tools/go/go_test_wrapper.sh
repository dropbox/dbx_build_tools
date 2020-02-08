#!/bin/bash -e

target="$1"
shift
test_exec="$1"
shift

if [ -d $RUNFILES/../dbx_build_tools ]; then
  dbx_build_tools_root=$RUNFILES/../dbx_build_tools
else
  dbx_build_tools_root=$RUNFILES/external/dbx_build_tools
fi

if [[ -n "$COVERAGE_OUTPUT_FILE" ]]; then
    coverage_out=$(mktemp)
else
    coverage_out=""
fi

temp=$(mktemp)

# Set +e for this block so that we can get the retcode
set +e
# -test.v is required to obtain the full event log for JUnit creation.
"$test_exec" -test.coverprofile="$coverage_out" -test.v "$@" | tee "$temp"
retcode=${PIPESTATUS[0]}
set -e

"$dbx_build_tools_root/../go_1_12_16_linux_amd64_tar_gz/go/pkg/tool/linux_amd64/test2json" < "$temp" -t | "$dbx_build_tools_root/go/src/dropbox/build_tools/gojunit/gojunit/gojunit" -target "$target"

if [[ -n "$COVERAGE_OUTPUT_FILE" ]]; then
    "$dbx_build_tools_root/go/src/dropbox/build_tools/gocov2cobertura/gocov2cobertura" < "$coverage_out" > "$COVERAGE_OUTPUT_FILE"
fi

exit "$retcode"
