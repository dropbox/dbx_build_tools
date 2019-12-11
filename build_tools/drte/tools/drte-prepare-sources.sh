#!/bin/bash

# Unpack DRTE sources. Create kernel headers. Expects two arguments:
# the configuration file and a directory of source archives (filled by
# drte-download.sh).

exec < /dev/null

# stop on any error, echo commands.
set -ex

# Set locale to C, so that e.g., 'sort' will work consistently regardless
# of system and user environment settings.
LC_ALL=C
export LC_ALL

# The 'gzip' environment variable passes flags to gzip.  We set -n to
# avoid putting timestamps and filenames in gzip files.  This enables
# deterministic builds.
GZIP=-n
export GZIP

absname=`readlink -f "$0"`
absroot="${absname%/*}"

. "$1"

OSRC="${absroot}/sources/unpacked"
TAR_DIR="$2"

echo "Unpack sources to ${OSRC}"
rm -rf "${OSRC}"
mkdir -p "${OSRC}"
cd "${OSRC}"

tar xf ${TAR_DIR}/gcc-${gcc_version}.tar.xz
tar jxf ${TAR_DIR}/gmp-${gmp_version}.tar.bz2
tar jxf ${TAR_DIR}/mpfr-${mpfr_version}.tar.bz2
tar zxf ${TAR_DIR}/mpc-${mpc_version}.tar.gz
tar xf ${TAR_DIR}/isl-${isl_version}.tar.bz2
mv gmp-${gmp_version} gcc-${gcc_version}/gmp
mv mpfr-${mpfr_version} gcc-${gcc_version}/mpfr
mv mpc-${mpc_version} gcc-${gcc_version}/mpc
mv isl-${isl_version} gcc-${gcc_version}/isl
# Prepare for hacky GCC patch in drte-build.sh.
cp gcc-${gcc_version}/gcc/Makefile.in gcc-Makefile.in.orig
tar Jxf ${TAR_DIR}/linux-${kernel_headers_version}.tar.xz
make -C linux-${kernel_headers_version} headers_install \
    INSTALL_HDR_PATH=${OSRC}/linux-libc-headers-${kernel_headers_version} \
    ARCH=x86
tar jxf ${TAR_DIR}/binutils-${binutils_version}.tar.bz2
tar xf ${TAR_DIR}/glibc-${glibc_version}.tgz --one-top-level
# Apply glibc patches. We may need to generalize this for other packages, too.
for patch in "${absroot}/patches/glibc-${glibc_version}"/*; do
    cp "$patch" glibc-${glibc_version}/debian/patches/any
    echo "any/$(basename $patch)" >> glibc-${glibc_version}/debian/patches/series
done
dpkg-source --before-build glibc-${glibc_version}
tar xf ${TAR_DIR}/bison-${bison_version}.tar.xz
