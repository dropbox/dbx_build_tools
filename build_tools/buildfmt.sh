#!/bin/bash -e

exec "$RUNFILES/../dbx_build_tools/go/src/github.com/bazelbuild/buildtools/buildifier/buildifier" -add_tables "$RUNFILES/../dbx_build_tools/build_tools/buildifier.json" "$@"
