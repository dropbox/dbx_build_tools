#!/bin/bash -e

exec "$RUNFILES/../dbx_build_tools/../com_github_bazelbuild_buildtools/buildifier/buildifier" -add_tables "$RUNFILES/../dbx_build_tools/build_tools/buildifier.json" "$@"
