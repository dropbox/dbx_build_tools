#!/bin/bash -eu

# This takes care of building CPython with all the right compiler flags
# including PGO and LTO. It needs to be run from the workspace root. The output
# is a python-$version.tar.xz file in the workspace root. It will also produce a
# bunch of intermediate artifacts in a build-temp/ directory.

if [[ $# != 2 ]]; then
    echo "pass version to build (3.8 or 3.9) as the first argument and drte version (e.g., v2) as the second"
    exit 2
fi

ver="$1"
if [[ "$ver" = "3.8" ]]; then
    repo=org_python_cpython_38
    version=3.8.8-dbx1
    abitag=3.8
    pgo_task=("--pgo")
elif [[ "$ver" = "3.8" ]]; then
    repo=org_python_cpython_39
    version=3.9.9-dbx1
    abitag=3.9
    pgo_task=("--pgo")
fi

drte_version="$2"

declare -a flags
# Enable optimized builds
flags+=("--compilation_mode=opt" "--experimental_omitfp")
# Use the requested DRTE version.
flags+=("--crosstool_top=@drte_${drte_version}_build_sysroot//:drte-${drte_version}")
# Enable link time optimization.
flags+=("--copt=-flto" "--linkopt=-flto" "--linkopt=-flto-partition=none")
# Set -g during linking, so the LTO step generates debug info.
flags+=("--linkopt=-g")

rm -rf build-temp
mkdir -p build-temp/lib/python$ver

bazel build "@$repo//:test-stdlib-zip" "@$repo//:bin/python" "${flags[@]}" "--fdo_instrument=$(realpath build-temp/prof.data)"

# make test_distutils happy
mkdir -p "build-temp/include/python$abitag" "build-temp/lib/python$ver/config-$abitag"
touch "build-temp/include/python$abitag/Python.h" "build-temp/include/python$abitag/pyconfig.h"

cp "bazel-bin/external/$repo/bin/python" "build-temp/python"
unzip "bazel-bin/external/$repo/test-stdlib.zip" -d "build-temp/lib/python$ver"
mkdir "build-temp/lib/python$ver/lib-dynload"

# Run the test suite. We set TZDIR because some tests rely on certain
# information in the Olson database.
(cd build-temp; TZDIR=/usr/share/zoneinfo ./python -m test.regrtest "${pgo_task[@]}")

# Build with final stamps and PGO. We used to be happy users of Bazel's
# --fdo_optimize option until upstream removed GCC FDO support without public
# comment. See https://github.com/bazelbuild/bazel/issues/5960. So, we hack PGO
# in with --copt. It's important that we give the profile data directory a
# unique name, since the directory name is the only thing keeping Bazel from
# caching compilation across FDO datasets.
pgo_hash="$(tar -cf - --mtime=2018-11-11 --mode=go=rX,u+rw --numeric-owner --owner=65534 --group=65534 -C build-temp/prof.data . | sha512sum | cut -f1 -d ' ')"
profdir="/home/nobody/prof.data-$pgo_hash"
bazel build "@$repo//:drte-python.tar.xz" "${flags[@]}" "--sandbox_add_mount_pair=$(realpath build-temp/prof.data):$profdir" --copt=-fprofile-use "--copt=-fprofile-dir=$profdir" --copt=-fprofile-correction --stamp --workspace_status_command "bazel-$(basename "$(pwd)")/external/bazel_tools/tools/buildstamp/get_workspace_status"
cp "bazel-bin/external/$repo/drte-python.tar.xz" "python-$version-drte-${drte_version}.tar.xz"
