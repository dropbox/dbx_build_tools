#!/bin/bash -eux

# Use a var to avoid a pipe - that would make number of processes nondeterministic
out=$(ps ux)
procs1=$(wc -l <<< out)
$RUNFILES/../dbx_build_tools/go/src/dropbox/build_tools/svcctl/cmd/svcctl/svcctl stop-all
$RUNFILES/../dbx_build_tools/go/src/dropbox/build_tools/svcctl/cmd/svcctl/svcctl start-all
out=$(ps ux)
procs2=$(wc -l <<< out)
if [ "$procs1" -lt "$procs2" ]; then
  echo "Restarting all services leaked some processes. Before: $procs1\nAfter:$procs2"
  exit -1
fi
