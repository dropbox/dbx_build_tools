#!/bin/bash -eu
if [ -z "$LAUNCH_CMD" ]; then
  echo 'LAUNCH_CMD is a required environment variable' 1>&2
  exit 1
fi
if [ -z "$CLEANDIR" ]; then
  echo 'CLEANDIR is a required environment variable' 1>&2
  exit 1
fi
if [ -z "$TEST_TMPDIR" ]; then
  echo 'TEST_TMPDIR is a required environment variable' 1>&2
  exit 1
fi
if [ -z "$HOST_TEST_TMPDIR" ]; then
  echo 'HOST_TEST_TMPDIR is a required environment variable' 1>&2
  exit 1
fi

SVCCTL_LOG=$TEST_TMPDIR/logs/svcctl.log
PID_FILE_LOCATION=/tmp/bzl-itest-init-pid  # not using TEST_TMPDIR, we don't want this ever persisted
EXPOSED_USER_FILE_LOCATION=/tmp/bzl-itest-exposed-user
EXIT_CODE_FILE_LOCATION=/tmp/bzl-itest-init-exit-code  # not using TEST_TMPDIR, we don't want this ever persisted
