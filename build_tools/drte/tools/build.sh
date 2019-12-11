#!/bin/bash -eux

# Toplevel script to build DRTE. Takes the configuration file as its
# sole argument.

dir=$(realpath $(dirname "$0"))
docker run -i -t --net=bridge --rm -a stdin -a stdout -a stderr \
       -v "$dir:$dir" \
       -v "$dir/output:/output" \
       -v "$dir/sources:/sources" \
       -w "$dir" \
       -e JFLAGS=-j8 \
       -e SKIP_STAGE1="${SKIP_STAGE1:-}" \
       -e SKIP_STAGE2="${SKIP_STAGE2:-}" \
       -e DISABLE_BOOTSTRAP="${DISABLE_BOOTSTRAP:-}" \
       ubuntu:16.04 \
       ./container-driver.sh "$1" /output/drte
