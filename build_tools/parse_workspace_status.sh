#!/bin/bash
set -eu

# This parses the Bazel stable status file and returns the git commit,
# or 40 0's if the stable status file doesn't have the git revision.
# Requires running the appropriate --workspace_status_command.

STABLE_STATUS_FILE='bazel-out/stable-status.txt'

if [[ -f "$STABLE_STATUS_FILE" ]]; then
  grep_output=$(grep "STABLE_GIT_REVISION" "$STABLE_STATUS_FILE" || :)
  if [[ $grep_output ]]; then
    echo "$grep_output" | cut --delimiter=" " -f2
    exit 0
  fi
fi

echo 0000000000000000000000000000000000000000
