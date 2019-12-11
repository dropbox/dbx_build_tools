#!/bin/bash -eu

# This script takes artifacts produced by build.sh and packages them
# into the cwd. The only argument is the drte configuration file.

cfg="$1"
if [ ! -f "$cfg" ]; then
    echo "configuration file doesn't exist"
    exit 2
fi
. "$cfg"

rm -rf packaging-temp
mkdir packaging-temp
FINAL_RUNTIME_ROOT="/usr/drte/$DRTEVERSION"
INPUT_ROOT="output/drte/final/packaging/root/$FINAL_RUNTIME_ROOT"
BUILD_SYSROOT="packaging-temp/drte-build-sysroot"
RUNTIME_ROOT="packaging-temp/drte-runtime-sysroot"
DEBUG_ROOT="packaging-temp/drte-debug-sysroot"
RUNTIME_SYSROOT="$RUNTIME_ROOT$FINAL_RUNTIME_ROOT"

# First, create the build sysroot by copying the directories we want out of the
# raw input root. We can't put the root files directly in $BUILD_SYSROOT because
# it confuses the toolchain if the sysroot is a symlink (which $BUILD_SYSROOT
# will be in the Bazel sandbox). Thus, we make a root subdirectory.
rm -fr "$BUILD_SYSROOT"
mkdir "$BUILD_SYSROOT"
mkdir "$BUILD_SYSROOT/root"
rsync -a --delete "$INPUT_ROOT/" \
      --include "/bin/***" \
      --include "/include/***" \
      --include "/lib/***" \
      --include "/lib64/***" \
      --include "/libexec/***" \
      --include "/x86_64-linux-gnu/***" \
      --exclude "*" \
      "$BUILD_SYSROOT/root"

# Adjust glibc linker scripts to use relative paths. We can almost use
# "absolute" paths relative to the DRTE root like "/lib64/libm.so"; the linker
# will resolve "absolute" paths it determines to be within the sysroot relative
# to the sysroot. However, the linker determines whether something is in the
# sysroot after resolving symlinks, which fails miserably in the Bazel sandbox.
sed -i 's/\/usr\/drte\/'"$DRTEVERSION"'\/lib64\///g' \
    "$BUILD_SYSROOT/root/lib64/libc.so" \
    "$BUILD_SYSROOT/root/lib64/libm.a" \
    "$BUILD_SYSROOT/root/lib64/libm.so" \
    "$BUILD_SYSROOT/root/lib64/libpthread.so"

# Remove copies of binutils.
for f in "$BUILD_SYSROOT/root/bin/"*; do
    if [ -f "$BUILD_SYSROOT/root/x86_64-linux-gnu/bin/"$(basename "$f") ]; then
        rm "$f"
    fi
done

# Strip debug info from the toolchain to save space.
for f in $(find "$BUILD_SYSROOT/root/bin" "$BUILD_SYSROOT/root/libexec" "$BUILD_SYSROOT/root/x86_64-linux-gnu"); do
    if grep -q "ELF.*executable" <(file "$f"); then
        echo "Stripping debug info from $f"
        strip -d "$f"
    fi
done

rm -rf "$RUNTIME_ROOT"
mkdir -p "$RUNTIME_SYSROOT"

# Prepare the final runtime sysroot.
mkdir "$RUNTIME_SYSROOT/lib64"

# These just get copied over verbatim.
cp -R "$BUILD_SYSROOT/root/lib64/audit" "$RUNTIME_SYSROOT/lib64/audit"
cp -R "$BUILD_SYSROOT/root/lib64/gconv" "$RUNTIME_SYSROOT/lib64/gconv"
cp -R "$BUILD_SYSROOT/root/lib64/locale" "$RUNTIME_SYSROOT/lib64/locale"

# We only place the library corresponding to its soname. Unversioned
# symlinks are omitted. This is cleaner and makes it harder to build
# against the runtime sysroot.
for so in "$BUILD_SYSROOT/root/lib64"/*.so*; do
    base=$(basename "$so")
    # Ignore files that are actually linker scripts or Python.
    case "$base" in
        libc.so|libm.so|libpthread.so|libgcc_s.so|*.py)
            continue
    esac
    soname=$(objdump -p "$so" | grep SONAME | awk '{print $2}')
    if [ -z "$soname" ]; then
        echo "Can't find soname for $so"
        exit 1
    fi
    cp -H "$so" "$RUNTIME_SYSROOT/lib64/$soname"
done

mkdir "$RUNTIME_SYSROOT/etc"
cp "$(dirname $0)/files/nsswitch.conf" "$RUNTIME_SYSROOT/etc"

# Construct the debug sysroot. Transfer debug information from the
# runtime sysroot to the debug sysroot.
rm -rf "$DEBUG_ROOT"
mkdir -p "$DEBUG_ROOT/usr/lib/debug/$FINAL_RUNTIME_ROOT/lib64"
mkdir "$DEBUG_ROOT/usr/lib/debug/$FINAL_RUNTIME_ROOT/lib64/audit"
mkdir "$DEBUG_ROOT/usr/lib/debug/$FINAL_RUNTIME_ROOT/lib64/gconv"
for so in $(find "$RUNTIME_SYSROOT/lib64" -name "*.so*"); do
    # Split debug data into a .dbg file.
    objcopy --only-keep-debug "$so" "$so".dbg
    # Note --add-gnu-debuglink must be given a file that exists hence the
    # directory-changing contortions
    (cd $(dirname "$so"); objcopy --strip-debug $(basename "$so") --add-gnu-debuglink=$(basename "$so".dbg))
    mv "$so".dbg "$DEBUG_ROOT/usr/lib/debug/$FINAL_RUNTIME_ROOT/lib64""${so#$RUNTIME_SYSROOT/lib64}".dbg
done
cp -R "output/drte/final/packaging/debug-src/"* "$DEBUG_ROOT"

# Generate version file for shelflife. We assume only gcc and glibc libraries
# make it into the runtime sysroot.
cat <<EOF > "$RUNTIME_SYSROOT/.dep_versions"
[
  {"type": "upstream", "name": "gcc", "version": "${gcc_version}"},
  {"type": "ubuntu", "name": "libc6", "version": "${glibc_ubuntu_version}"}
]
EOF

# Generate packages.
echo "Generating packages"
tar -caf "drte-${DRTEVERSION}-build-sysroot_${DRTEPACKAGEVERSION}.tar.xz" --mtime=2018-11-11 --numeric-owner --owner=65534 --group=65534 -C "$BUILD_SYSROOT" --sort=name .
tar -caf "drte-${DRTEVERSION}_${DRTEPACKAGEVERSION}.tar.xz" --mtime=2018-11-11 --numeric-owner --owner=65534 --group=65534 -C "$RUNTIME_ROOT" --sort=name .
tar -caf "drte-${DRTEVERSION}-dbg_${DRTEPACKAGEVERSION}.tar.xz" --mtime=2018-11-11 --numeric-owner --owner=65534 --group=65534 -C "$DEBUG_ROOT" --sort=name .

rm -f *.deb
fpm -s dir -t deb -C "$RUNTIME_ROOT" \
    --name "drte-$DRTEVERSION" \
    --version "$DRTEPACKAGEVERSION" \
    -m "Dropbox Build Infrastructure <build-infrastructure@dropbox.com>" \
    --description "Dropbox base native runtime libraries, namely libc and gcc runtimes." \
    --vendor "Dropbox Build Toolchains Team"

fpm -s dir -t deb -C "$DEBUG_ROOT" \
    --name "drte-$DRTEVERSION-dbg" \
    --version "$DRTEPACKAGEVERSION" \
    -m "Dropbox Build Infrastructure <build-infrastructure@dropbox.com>" \
    --description "Dropbox base native runtime libraries debug information." \
    --vendor "Dropbox Build Toolchains Team"
