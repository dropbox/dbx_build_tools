#!/bin/bash

# This runs inside docker container as root to build DRTE.

set -ex

# Load configuration.
cfg="$1"
if [ ! -f "$cfg" ]; then
    echo "need to pass configuration as the first argument to this script"
    exit 2
fi
. "$cfg"

# Install various packages needed to do the build.
apt-get update
# "basic" build utilities
apt-get install -y perl gawk make autoconf
# required for downloading, unpacking sources, and applying patches
apt-get install -y xz-utils wget bzip2 cpio dpkg-dev
# We need some toolchain packages to bootstrap the build, but don't want them to
# end up affecting the final product. drte-build.sh removes these after stage1.
TOOLCHAIN_PKGS="gcc g++ gcc-multilib binutils"
apt-get install -y $TOOLCHAIN_PKGS

DRTE_TMPDIR="$2"
mkdir "$DRTEROOT"

./drte-download.sh "$cfg" /sources
./drte-prepare-sources.sh "$cfg" /sources
apt-get purge -y dpkg-dev
apt-get autoremove -y --purge
./drte-build.sh "$cfg" "$DRTE_TMPDIR" "$TOOLCHAIN_PKGS"
