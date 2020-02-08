#!/bin/bash -eux

if [ -d $RUNFILES/../dbx_build_tools ]; then
  dbx_build_tools_root=$RUNFILES/../dbx_build_tools
else
  dbx_build_tools_root=$RUNFILES/external/dbx_build_tools
fi

# Use a var to avoid a pipe - that would make number of processes nondeterministic
out=$(ps ux)
procs1=$(wc -l <<< out)
$dbx_build_tools_root/go/src/dropbox/build_tools/svcctl/cmd/svcctl/svcctl stop-all
$dbx_build_tools_root/go/src/dropbox/build_tools/svcctl/cmd/svcctl/svcctl start-all
out=$(ps ux)
procs2=$(wc -l <<< out)
if [ "$procs1" -lt "$procs2" ]; then
  echo "Restarting all services leaked some processes. Before: $procs1\nAfter:$procs2"
  exit -1
fi
