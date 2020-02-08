#!/bin/bash -e

if [ -d $RUNFILES/../dbx_build_tools ]; then
  dbx_build_tools_root=$RUNFILES/../dbx_build_tools
else
  dbx_build_tools_root=$RUNFILES/external/dbx_build_tools
fi

exec "$dbx_build_tools_root/go/src/github.com/bazelbuild/buildtools/buildifier/buildifier" -add_tables "$dbx_build_tools_root/build_tools/buildifier.json" "$@"
