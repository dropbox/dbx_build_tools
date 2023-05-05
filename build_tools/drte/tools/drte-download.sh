#!/bin/bash -e

# Download DRTE sources. This expects two arguments, the configuration
# file and directory the source archives should be downloaded to.

cfg="$1"
[ -f "$cfg" ] || {
    echo "could not find $cfg"
    exit 1
}

. "$cfg"

TAR_DIR="$2"
echo "changing to $TAR_DIR"
mkdir -p $TAR_DIR
cd $TAR_DIR

wget -c https://forge-magic-mirror.awsvip.dbxnw.net/archives/glibc/glibc-${glibc_version}.tgz
wget -c https://forge-magic-mirror.awsvip.dbxnw.net/archives/binutils/binutils-${binutils_version}.tar.bz2
wget -c https://forge-magic-mirror.awsvip.dbxnw.net/archives/gcc/gcc-${gcc_version}.tar.xz
wget -c https://forge-magic-mirror.awsvip.dbxnw.net/archives/gmp/gmp-${gmp_version}.tar.bz2
wget -c https://forge-magic-mirror.awsvip.dbxnw.net/archives/mpfr/mpfr-${mpfr_version}.tar.bz2
wget -c https://forge-magic-mirror.awsvip.dbxnw.net/archives/mpc/mpc-${mpc_version}.tar.gz
wget -c https://forge-magic-mirror.awsvip.dbxnw.net/archives/zlib/zlib-${zlib_version}.tar.gz
wget -c https://forge-magic-mirror.awsvip.dbxnw.net/archives/linux/linux-${kernel_headers_version}.tar.xz
wget -c https://forge-magic-mirror.awsvip.dbxnw.net/archives/isl/isl-${isl_version}.tar.bz2
wget -c https://forge-magic-mirror.awsvip.dbxnw.net/archives/bison/bison-${bison_version}.tar.xz
