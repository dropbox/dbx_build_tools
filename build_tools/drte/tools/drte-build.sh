#!/bin/bash -ex

#
# This script builds the Dropbox Runtime Environment (DRTE) and a
# toolchain that can build code against it.
#
# Great care must be taken to build everything hermetically. To this
# end, we end up recompiling some things several times in order to
# ensure that we are in fact using tools freshly built from the
# sources. This takes a long time.
#
# Building the circularly-dependent toolchain components of gcc,
# glibc, and binutils is rather tricky, so everyone borrows widely
# from previous attempts. This script is not an exception. Perhaps the
# first widely used tool to build toolchains was Dan Kegel's crosstool
# script (http://www.kegel.com/crosstool/). Google's adaption of this
# crosstool script, build-grte, is available to us thanks to the the
# Google Search Appliance and the magic of the GPL:
# https://code.google.com/archive/p/google-search-appliance-mirror/downloads
# LRTE (https://github.com/bazelment/lrte) modernized a bunch of the
# grte code dump. Some other ideas for this script were taken from the
# crosstool-ng project, which derives from the original crosstool.
#
# Pictorially, here is the heritage of this script:
#
#                   (original) crosstool
#                 /                     \
#                /                       \
#               /                         \
#            crosstool-ng               grte-build
#               |                          |
#               |                         lrte
#               \                          /
#                \                        /
#                 \                      /
#                  \                    /
#                   \                  /
#                      build-drte.sh
#

# Prevent configure scripts from trying to read anything useful from stdin.
exec < /dev/null

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

# Read configuration file.
. "$1"

function warn {
  echo "" >&2
  if [ $# -eq 0 ] ;then
    echo -n "WARNING: " >&2
    cat >&2
  else
    echo "WARNING: $@" >&2
  fi
  echo "" >&2
}

function error {
  # stop printing to get a clear error message
  set +x
  echo "" >&2
  if [ $# -eq 0 ] ;then
    echo -n "ERROR: " >&2
    cat >&2
  else
    echo "ERROR: $@" >&2
  fi
  exit 1
}

function usage {
  # stop printing to get a clear error message
  set +x
  cat <<EOF
Usage: host-build DRTECONFIG DRTEBUILD TOOKCHAIN_PKGS

DRTECONFIG path to drte configuration file
DRTEBUILD is the full path to the directory in which the builds will take
          place. This script will indescriminately remove this directory
          very early on in its life unless "\$PRESERVE_BUILD" is non-empty.
TOOLCHAIN_PKGS will be purged after the system toolchain is no longer
required.

EOF

  [ -n "$@" ] && error "$@"
  exit 1
}

[ $# -eq 3 ] || usage

case "$DRTEROOT" in
  *\.\.*)  error "DRTEROOT must be an absolute path name" ;;
  /*) ;;
  *)       error "DRTEROOT must be an absolute path name" ;;
esac

DRTEROOT="${DRTEROOT}/${DRTEVERSION}"
OSRC="${absroot}/sources/unpacked"
BUILD=`readlink -f "$2"`
SRC="${BUILD}/sources"

PKGVERSION="DRTE ${DRTEVERSION}"

origpath="${PATH}"

#
# Canonical architecture names
#
arch64="x86_64-linux-gnu"
arch64build="x86_64-build-linux-gnu"

m=`uname -m`
[ "${m}" = "x86_64" ] || usage "build system must be x86_64"

#
# Sanity check the arguments pased to the script
#
[ -d "${OSRC}/gcc-${gcc_version}" -a -d "${OSRC}/glibc-${glibc_version}" ] || {
  usage "ERROR: badly populated source directory (missing gcc and glibc)."
}

[ -d "${OSRC}/linux-libc-headers-${kernel_headers_version}" ] || {
  usage "ERROR: badly populated source directory (missing kernel headers)."
}

[ -d "${OSRC}/binutils-${binutils_version}" ] || {
  usage "ERROR: badly populated source directory (missing binutils)."
}

#
# Unless we've been asked not to, remove the entire build directory.
#
[ -n "${SKIP_STAGE1}" ] && PRESERVE_BUILD=1
[ -n "${SKIP_STAGE2}" ] && PRESERVE_BUILD=1
[ -n "${SKIP_FINAL}" ] && PRESERVE_BUILD=1
[ -z "${PRESERVE_BUILD}" ] && {
  rm -fr "${BUILD}" || {
    error "failed to remove build directory"
  }
  [ -d "${BUILD}" ] && {
    error "failed to remove build directory"
  }
}

[ -d "${BUILD}" ] || mkdir -p "${BUILD}" || {
  error "failed to create build directory"
}

[ -w "${BUILD}" ] || {
  error "Build directory not writable"
}

[ -w "${1}" ] || {
  error "DRTEROOT (${1}) not writable"
}

[ -z "${PRESERVE_BUILD}" ] || {
  warn "not doing a clean build (PRESERVE_BUILD set)."
}

STAGE1ROOT="${BUILD}/stage1"
STAGE2ROOT="${BUILD}/stage2"
FINALROOT="${BUILD}/final"

# Set up mappings from actual source location to the location where
# the sources will be installed for the debuginfo package.  Note that
# we have to include stage2, because some stage2 bits (gcc, glibc)
# survive into the final binaries.
DEBUG_PREFIX_MAPPINGS=
DEBUG_PREFIX_MAP_GCC_FLAGS=
DEBUG_PREFIX_MAP_GAS_FLAGS=
for mapping in "${SRC}=${DRTEROOT}/debug-src/src" \
               "${STAGE2ROOT}=${DRTEROOT}/debug-src/stage2" \
               "${FINALROOT}=${DRTEROOT}/debug-src/final"; do
  DEBUG_PREFIX_MAPPINGS="${DEBUG_PREFIX_MAPPINGS} ${mapping}"
  DEBUG_PREFIX_MAP_GCC_FLAGS="${DEBUG_PREFIX_MAP_GCC_FLAGS} -fdebug-prefix-map=${mapping}"
  DEBUG_PREFIX_MAP_GAS_FLAGS="${DEBUG_PREFIX_MAP_GAS_FLAGS} --debug-prefix-map=${mapping}"
done

# We have multilib enabled for future extension but only build 64-bit currently.
xtra_gcc_cfg="--with-multilib-list=m64 --enable-multilib"

if [ -n "$DISABLE_BOOTSTRAP" ]; then
    xtra_gcc_cfg="$xtra_gcc_cfg --disable-bootstrap"
fi

#
# bison is required to build glibc. While its output is thus compiled into DRTE,
# bison itself is not part of the final DRTE product. Therefore, we install a
# pinned version of bison into the system, so its output is reproducible.  We
# assume that which compiler is used to compile bison doesn't affect its output.
#
if which bison; then
    error "bison installed already!"
fi
BISONBUILD="${BUILD}/bison"
rm -rf "$BISONBUILD"
mkdir "$BISONBUILD"
cd "$BISONBUILD"
# Passing --disable-yacc disables the creation and installation of liby.a, which
# makes us feel a bit more confident that code we compile here isn't leaking
# into the final product.
"${OSRC}/bison-${bison_version}/configure" \
  --disable-yacc \
  --disable-nls \
  || error "bison configure failed"
make $JFLAGS || error "bison build failed"
make install || error "bison install failed"

#
# The first order of business is to compile a binutils/gcc combination
# for x86_64 using whatever underlying host compiler is present. This is
# built in a temporary staging area.
# This is the stage 1 bootstrap compiler, so things can be fairly minimal.
[ -z "${SKIP_STAGE1}" ] && {
  SYSROOT="${STAGE1ROOT}/${arch64}-root"
  HDRDIR="${SYSROOT}/include"

  #
  # The sources need to be writable ... copy the original sources into a new
  # location and make sure they are all writable.
  #
  echo "Copying sources to temporary build location"
  rm -fr "${SRC}"
  mkdir -p "${SRC}"
  cd "${OSRC}"
  find . -depth -print | cpio -pdum "${SRC}" > /dev/null 2>&1
  chmod -Rf u+w "${SRC}"

  #
  # Put the new binutils first in the path for when we configure gcc.
  #
  PATH="${STAGE1ROOT}/root/bin:${origpath}"

  rm -fr "${STAGE1ROOT}"
  mkdir -p "${STAGE1ROOT}"
  cd "${STAGE1ROOT}"
  mkdir root
  cd root
  mkdir -p "${SYSROOT}/include"

  #
  # Copy the kernel headers into $HDRDIR
  #
  cd "${SRC}/linux-libc-headers-${kernel_headers_version}/include"
  cp -r * "${HDRDIR}"
  cd "${HDRDIR}"
  mkdir sys
  cp linux/capability.h sys

  cd "${STAGE1ROOT}"
  rm -fr binutils-build
  mkdir binutils-build
  cd binutils-build
  CC=gcc "${SRC}/binutils-${binutils_version}/configure" \
    --prefix="${STAGE1ROOT}/root" \
    --target="${arch64}" \
    --disable-nls \
    --disable-shared \
    --enable-64-bit-bfd \
    --with-sysroot="${SYSROOT}" \
    --enable-deterministic-archives \
    || error "binutils stage1 configuration failed"
  make $JFLAGS || error "binutils stage1 build failed"
  make install || error "binutils stage1 install failed"

  #
  # Now install glibc's headers into $HDRDIR
  #
  cd "${STAGE1ROOT}"
  rm -fr glibc-build-headers
  mkdir glibc-build-headers
  cd glibc-build-headers
  "${SRC}/glibc-${glibc_version}/configure" \
    --build="${arch64}" \
    --host="${arch64}" \
    --prefix=/ \
    --with-headers="${HDRDIR}" \
    --without-cvs \
    --disable-profile \
    --disable-debug \
    --without-gd \
    --with-tls \
    --with-__thread \
    --with-binutils="${STAGE1ROOT}/root/bin" \
    --enable-add-ons= \
    || error "glibc stage1 configure failed"
  make cross-compiling=yes install-headers install_root="${SYSROOT}" \
    || error "glibc stage1 build failed"
  cp "${SRC}/glibc-${glibc_version}/include/gnu/stubs.h" \
    "${HDRDIR}/gnu"
  cp "${SRC}/glibc-${glibc_version}/include/features.h" "${HDRDIR}"
  cp bits/stdio_lim.h "${HDRDIR}/bits/"

  #
  # Now build a minimal gcc that can target 64-bit machines. We
  # only need the C compiler because we will be using this compiler
  # for re-producing binutils, glibc and gcc below.
  #
  cd "${STAGE1ROOT}"
  rm -fr gcc-build
  mkdir gcc-build
  cd gcc-build
  CC=gcc "${SRC}/gcc-${gcc_version}/configure" \
    --prefix="${STAGE1ROOT}/root" \
    --target="${arch64}" \
    --enable-languages=c,c++ \
    --disable-nls \
    --disable-shared \
    --disable-threads \
    --enable-__cxa_atexit \
    --with-sysroot="${SYSROOT}" \
    --with-multilib-list=m64 \
    --with-native-system-header-dir=/include \
    --disable-bootstrap \
    || error "gcc stage1 configuration failed"
  make $JFLAGS all-gcc || error "gcc stage1 build failed"
  make $JFLAGS all-target-libgcc || error "gcc stage1 build failed"
  make install-gcc install-target-libgcc || error "gcc stage1 install failed"

  #
  # Now for the full glibc build, which will also result in things like
  # crt1.o being built.
  cd "${STAGE1ROOT}"
  rm -fr glibc-build64
  mkdir glibc-build64
  cd glibc-build64
  CC="${STAGE1ROOT}/root/bin/${arch64}-gcc" \
  MAKEINFO=: \
  "${SRC}/glibc-${glibc_version}/configure" \
    --build="${arch64}" \
    --host="${arch64}" \
    --prefix=/ \
    --with-headers="${HDRDIR}" \
    --without-cvs \
    --disable-profile \
    --disable-debug \
    --without-gd \
    --with-tls \
    --with-__thread \
    --disable-werror \
    --enable-add-ons= \
    || error "glibc 64-bit stage1 configure failed"
  make PARALLELMFLAGS="${JFLAGS}" \
    || error "glibc 64-bit stage1 build failed"
  make install install_root="${SYSROOT}" \
    || error "glibc 64-bit stage1 install failed"

  #
  # Finally do the full gcc build that will include everything (such as
  # libmudflap, libgcc_eh etc) and not just the compiler.
  cd "${STAGE1ROOT}"
  rm -fr gcc-final
  mkdir gcc-final
  cd gcc-final
  CC=gcc "${SRC}/gcc-${gcc_version}/configure" \
    --prefix="${STAGE1ROOT}/root" \
    --target="${arch64}" \
    --enable-languages=c,c++ \
    --disable-nls \
    --enable-__cxa_atexit \
    --with-sysroot="${SYSROOT}" \
    --with-multilib-list=m64 \
    --with-native-system-header-dir=/include \
    --disable-bootstrap \
    --disable-libssp \
    || error "gcc stage1 configuration failed"
  make $JFLAGS || error "gcc final stage1 build failed"
  make install || error "gcc final stage1 install failed"

  PATH="${origpath}"
}

#
# Now that the stage 1 mini-environment is available, we can do the first
# real bootstrap environment. This differs from the stage 1 environment in
# that it will be compiled with a known compiler (the stage 1 compiler)
# and tool chain, and it will be a native hosted compiler not a cross-
# compiler. It will, however, be rooted in the staging area. Once again
# the environment we create here is a minimal one to ensure we have a
# base compiler that was built with a known set of good tools and compiler.
#
# The important thing to know about how things are configured here is that
# the RTLD for glibc will be configured to be located in the staging
# area not in /lib or /lib64, so that when we use the compilers in the
# final stage, we are actually using the stuff we just built and nothing
# from the system.
#

# Remove the system toolchain, so we can't use it any more.
apt-get purge -y $3
apt-get autoremove -y --purge
if which cc || which ld; then
    error "system toolchain still installed"
fi

[ -z "${SKIP_STAGE2}" ] && {
  PATH="${STAGE1ROOT}/root/bin:${origpath}"
  STAGE1CC64="${STAGE1ROOT}/root/bin/${arch64}-gcc"
  STAGE1CXX64="${STAGE1ROOT}/root/bin/${arch64}-g++"
  STAGE1LD="${STAGE1ROOT}/root/bin/${arch64}-ld"
  STAGE1AS="${STAGE1ROOT}/root/bin/${arch64}-as"
  STAGE1AR="${STAGE1ROOT}/root/bin/${arch64}-ar"
  STAGE1NM="${STAGE1ROOT}/root/bin/${arch64}-nm"
  STAGE1OBJDUMP="${STAGE1ROOT}/root/bin/${arch64}-objdump"
  STAGE1RANLIB="${STAGE1ROOT}/root/bin/${arch64}-ranlib"

  rm -fr "${STAGE2ROOT}"
  mkdir -p "${STAGE2ROOT}"
  cd "${STAGE2ROOT}"
  mkdir root

  #
  # First up is a fresh set of kernel headers.
  cd "${STAGE2ROOT}/root"
  rm -fr include
  mkdir include
  cd "${SRC}/linux-libc-headers-${kernel_headers_version}/include"
  cp -r * "${STAGE2ROOT}/root/include"
  cd "${STAGE2ROOT}/root/include"
  mkdir sys
  cp linux/capability.h sys

  #
  # The next thing we build is a new binutils. This will be compiled
  # in 64-bit mode and installed into a temporary location. When we
  # compile glibc below, we will tell it to use this temporary location
  # and then rebuild binutils to use the new libc once it's done.
  #
  cd "${STAGE2ROOT}"
  rm -fr binutils-build bnu
  mkdir binutils-build bnu
  cd binutils-build
  CC="${STAGE1CC64}" \
  CXX="${STAGE1CXX64}" \
  LD="${STAGE1LD}" \
  AS="${STAGE1AS}" \
  NM="${STAGE1NM}" \
  AR="${STAGE1AR}" \
  OBJDUMP="${STAGE1OBJDUMP}" \
  RANLIB="${STAGE1RANLIB}" \
  "${SRC}/binutils-${binutils_version}/configure" \
    --prefix="${STAGE2ROOT}/bnu" \
    --host="${arch64}" \
    --target="${arch64}" \
    --build="${arch64}" \
    --disable-nls \
    --disable-shared \
    --enable-64-bit-bfd \
    --enable-deterministic-archives \
    || error "binutils stage2 configuration failed"
  make $JFLAGS || error "binutils stage2 build failed"
  make install || error "binutils stage2 install failed"

  #
  # Put the new binutils first in the path for when we configure glibc.
  #
  PATH="${STAGE2ROOT}/bnu/bin:${PATH}"

  #
  # Now we build glibc.
  #
  # Some of the bits created here survive into the binaries built during
  # the final build stage, so we map filename prefixes in the debug info.
  #
  cd "${STAGE2ROOT}"
  rm -fr glibc-build64
  mkdir glibc-build64
  cd glibc-build64
  echo "slibdir=${STAGE2ROOT}/root/lib64" > configparms
  CC="${STAGE1CC64} ${DEBUG_PREFIX_MAP_GCC_FLAGS}" \
  LD="${STAGE1LD}" \
  AS="${STAGE1AS} ${DEBUG_PREFIX_MAP_GAS_FLAGS}" \
  NM="${STAGE1NM}" \
  AR="${STAGE1AR}" \
  OBJDUMP="${STAGE1OBJDUMP}" \
  RANLIB="${STAGE1RANLIB}" \
  MAKEINFO=: \
  "${SRC}/glibc-${glibc_version}/configure" \
    --build="${arch64}" \
    --host="${arch64}" \
    --target="${arch64}" \
    --prefix="${STAGE2ROOT}/root" \
    --libdir="\${prefix}/lib64" \
    --with-headers="${STAGE2ROOT}/root/include" \
    --without-cvs \
    --disable-profile \
    --disable-debug \
    --disable-build-nscd \
    --disable-nscd \
    --without-gd \
    --with-tls \
    --with-__thread \
    --disable-werror \
    --enable-add-ons= \
    || error "glibc 64-bit stage2 configure failed"
  make AR="${STAGE1AR}" RANLIB="${STAGE1RANLIB}" PARALLELMFLAGS="${JFLAGS}" \
    || error "glibc 64-bit stage2 build failed"
  make AR="${STAGE1AR}" RANLIB="${STAGE1RANLIB}" install \
    || error "glibc 64-bit stage2 install failed"

  #
  # Now build binutils again, this time using the glibc we just created.
  #
  cd "${STAGE2ROOT}"
  rm -fr binutils-rebuild
  mkdir binutils-rebuild
  cd binutils-rebuild
  CC="${STAGE1CC64} -isystem ${STAGE2ROOT}/root/include -L${STAGE2ROOT}/root/lib64" \
  CXX="${STAGE1CXX64} -isystem ${STAGE2ROOT}/root/include -L${STAGE2ROOT}/root/lib64" \
  LD="${STAGE1LD}" \
  AS="${STAGE1AS}" \
  NM="${STAGE1NM}" \
  AR="${STAGE1AR}" \
  LDFLAGS="-Wl,-I,${STAGE2ROOT}/root/lib64/ld-linux-x86-64.so.2" \
  OBJDUMP="${STAGE1OBJDUMP}" \
  RANLIB="${STAGE1RANLIB}" \
  "${SRC}/binutils-${binutils_version}/configure" \
    --prefix="${STAGE2ROOT}/root" \
    --host="${arch64}" \
    --target="${arch64}" \
    --build="${arch64}" \
    --disable-nls \
    --disable-shared \
    --enable-64-bit-bfd \
    --enable-deterministic-archives \
    || error "binutils stage2 rebuild configuration failed"
  make $JFLAGS || error "binutils stage2 rebuild build failed"
  make install || error "binutils stage2 rebuild install failed"

  #
  # We now have glibc and binutils, which uses that glibc, compiled and
  # ready to go. We can now build gcc. We build both C and C++ so that
  # when we do the final stage build next, we can build the various
  # support libraries such a MPFR correctly.
  #
  # Some of the bits created here survive into the binaries built during
  # the final build stage, so we map filename prefixes in the debug info.
  #
  # Note that this is a bootstrap build, so we need to set BOOT_CFLAGS
  # in the 'make' environment so that debug prefixes in the post-stage1
  # builds are mapped properly.
  #
  PATH="${STAGE2ROOT}/root/bin:${STAGE1ROOT}/root/bin:${origpath}"
  cd "${STAGE2ROOT}"
  rm -fr gcc-build
  mkdir gcc-build
  cd gcc-build

  # with-startfile-prefix-1 is unsupported anymore, so we have to
  # patch the Makefile.in
  sed -e "s:^DRIVER_DEFINES = :DRIVER_DEFINES = -DSTANDARD_STARTFILE_PREFIX_1=\\\\\\\"${STAGE2ROOT}/root/lib64/\\\\\\\" -DSTANDARD_STARTFILE_PREFIX_2=\\\\\\\"${STAGE2ROOT}/root/lib/\\\\\\\" :" ${SRC}/gcc-Makefile.in.orig > ${SRC}/gcc-${gcc_version}/gcc/Makefile.in
  CC="${STAGE1CC64} -isystem ${STAGE2ROOT}/root/include -L${STAGE2ROOT}/root/lib64" \
  CXX="${STAGE1CXX64} -isystem ${STAGE2ROOT}/root/include -L${STAGE2ROOT}/root/lib64" \
  CFLAGS="-isystem ${STAGE2ROOT}/root/include -L${STAGE2ROOT}/root/lib64 -DSTANDARD_INCLUDE_DIR=\\\\\\\"\"${STAGE2ROOT}/root/include\\\\\\\"\"" \
  AR="${STAGE2AR}" \
  RANLIB="${STAGE2RANLIB}" \
  AR_FOR_TARGET="${STAGE2AR}" \
  RANLIB_FOR_TARGET="${STAGE2RANLIB}" \
  "${SRC}/gcc-${gcc_version}/configure" \
    --prefix="${STAGE2ROOT}/root" \
    --build="${arch64}" \
    --host="${arch64}" \
    --target="${arch64}" \
    --enable-languages=c,c++ \
    --disable-nls \
    --enable-shared \
    --enable-__cxa_atexit \
    --with-native-system-header-dir="${STAGE2ROOT}/root/include" \
    --with-local-prefix="${DRTEROOT}/local" \
    --with-debug-prefix-map="${DEBUG_PREFIX_MAPPINGS}" \
    --with-stage1-ldflags="-static-libstdc++ -static-libgcc -Wl,-I,${STAGE2ROOT}/root/lib64/ld-linux-x86-64.so.2" \
    --with-boot-ldflags="-static-libstdc++ -static-libgcc -Wl,-I,${STAGE2ROOT}/root/lib64/ld-linux-x86-64.so.2" \
    --disable-libssp \
    ${xtra_gcc_cfg} \
    || error "gcc stage2 configuration failed"
  make $JFLAGS \
    BOOT_CFLAGS="-g -O2 ${DEBUG_PREFIX_MAP_GCC_FLAGS}" \
    || error "gcc stage2 build failed"
  make install || error "gcc stage2 install failed"

  PATH="${origpath}"
}

#
# Now for the final stage. This is where we build and package the entire
# thing. Note that the build order is a little different here because we
# do not need to concern ourselves with avoiding the underlying system
# as all the tools created in stage 2 are crafted to only look in the
# right places.
#
# Please note that $FINALROOT is where we do the build and packaging,
# it is not where we install things. That is the first argument to this
# script, and is $DRTEROOT. We remove the entire DRTEROOT during this
# build.
#
[ -z "${SKIP_FINAL}" ] && {
  PATH="${STAGE2ROOT}/root/bin:${origpath}"
  STAGE2CC64="${STAGE2ROOT}/root/bin/gcc ${DEBUG_PREFIX_MAP_GCC_FLAGS}"
  STAGE2CXX64="${STAGE2ROOT}/root/bin/g++ ${DEBUG_PREFIX_MAP_GCC_FLAGS}"
  STAGE2LD="${STAGE2ROOT}/root/bin/ld"
  STAGE2AS="${STAGE2ROOT}/root/bin/as ${DEBUG_PREFIX_MAP_GAS_FLAGS}"
  STAGE2AR="${STAGE2ROOT}/root/bin/ar"
  STAGE2NM="${STAGE2ROOT}/root/bin/nm"
  STAGE2OBJDUMP="${STAGE2ROOT}/root/bin/objdump"
  STAGE2RANLIB="${STAGE2ROOT}/root/bin/ranlib"
  SUPPORTED_LOCALES="en_US.UTF-8/UTF-8"

  rm -fr "${FINALROOT}" "${DRTEROOT}"
  mkdir -p "${FINALROOT}/packaging/root" "${DRTEROOT}"
  idir="${FINALROOT}/packaging/root"

  rm -fr "${DRTEROOT}/include"
  mkdir "${DRTEROOT}/include"
  cd "${SRC}/linux-libc-headers-${kernel_headers_version}/include"
  cp -r * "${DRTEROOT}/include"

  cd "${FINALROOT}"
  rm -fr kernel-headers "${idir}/${DRTEROOT}/include"
  mkdir -p kernel-headers "${idir}/${DRTEROOT}/include"

  cd "${SRC}/linux-libc-headers-${kernel_headers_version}/include"
  cp -r * "${FINALROOT}/kernel-headers"
  cp -r * "${idir}/${DRTEROOT}/include"
  cd "${FINALROOT}/kernel-headers"

  #
  # Now we can begin the construction of glibc for the final builds.

  cd "${FINALROOT}"
  rm -fr glibc64-build
  mkdir glibc64-build
  cd glibc64-build
  echo "slibdir=${DRTEROOT}/lib64" > configparms
  CC="${STAGE2CC64}" \
  LD="${STAGE2LD}" \
  AS="${STAGE2AS}" \
  NM="${STAGE2NM}" \
  AR="${STAGE2AR}" \
  OBJDUMP="${STAGE2OBJDUMP}" \
  RANLIB="${STAGE2RANLIB}" \
  CFLAGS="-O3 -g" \
  MAKEINFO=: \
  "${SRC}/glibc-${glibc_version}/configure" \
    --build="${arch64}" \
    --host="${arch64}" \
    --target="${arch64}" \
    --with-pkgversion="$PKGVERSION" \
    --prefix="${DRTEROOT}" \
    --libdir="\${prefix}/lib64" \
    --with-headers="${DRTEROOT}/include" \
    --without-cvs \
    --without-gd \
    --enable-add-ons=libidn \
    --enable-static-nss \
    --disable-build-nscd \
    --disable-nscd \
    --with-tls \
    --with-__thread \
    --disable-werror \
    || error "glibc 64-bit final configure failed"
  make AR="${STAGE2AR}" RANLIB="${STAGE2RANLIB}" PARALLELMFLAGS="${JFLAGS}" \
    || error "glibc 64-bit final build failed"
  make AR="${STAGE2AR}" RANLIB="${STAGE2RANLIB}" install \
    install_root="${idir}" \
    || error "glibc 64-bit final install failed"
  make localedata/install-locales install_root="${idir}" \
    SUPPORTED-LOCALES="${SUPPORTED_LOCALES}" \
    || error "glibc 64-bit final localedata install failed"
  make AR="${STAGE2AR}" RANLIB="${STAGE2RANLIB}" install \
    || error "glibc 64-bit final in-situ install failed"
  make localedata/install-locales \
    SUPPORTED-LOCALES="${SUPPORTED_LOCALES}" \
    || error "glibc 64-bit final in-situ localedata install failed"

  #
  # Now the final compile of binutils
  #
  cd "${FINALROOT}"
  rm -fr binutils-build
  mkdir binutils-build
  cd binutils-build
  CC="${STAGE2CC64} -isystem ${DRTEROOT}/include -L${DRTEROOT}/lib64" \
  CXX="${STAGE2CXX64} -isystem ${DRTEROOT}/include -L${DRTEROOT}/lib64" \
  LD="${STAGE2LD}" \
  AS="${STAGE2AS}" \
  NM="${STAGE2NM}" \
  AR="${STAGE2AR}" \
  OBJDUMP="${STAGE2OBJDUMP}" \
  RANLIB="${STAGE2RANLIB}" \
  LDFLAGS="-Wl,-I,${DRTEROOT}/lib64/ld-linux-x86-64.so.2" \
  CFLAGS="-O3 -g" \
  "${SRC}/binutils-${binutils_version}/configure" \
    --prefix="${DRTEROOT}" \
    --host="${arch64}" \
    --build="${arch64}" \
    --target="${arch64}" \
    --with-pkgversion="$PKGVERSION" \
    --libdir="${DRTEROOT}/lib64" \
    --disable-nls \
    --disable-install-libbfd \
    --enable-gold \
    --enable-threads \
    --enable-plugins \
    --enable-64-bit-bfd \
    --with-native-lib-dirs="${DRTEROOT}/lib ${DRTEROOT}/local/lib" \
    --enable-deterministic-archives \
    || error "binutils final configuration failed"
  make $JFLAGS || error "binutils final build failed"
  make install DESTDIR="${idir}" \
    || error "binutils final install failed"
  make install || error "binutils final in-situ install failed"

  #
  # Do the final full-scale gcc build
  #
  # Note that this is a bootstrap build, so we need to set BOOT_CFLAGS
  # in the 'make' environment so that debug prefixes in the post-stage1
  # builds are mapped properly.  We need to set FCFLAGS similarly, to
  # make sure the mapping apply to the fortran libraries.
  #
  PATH="${DRTEROOT}/bin:${STAGE2ROOT}/root/bin:${origpath}"
  cd "${FINALROOT}"
  rm -fr gcc-build
  mkdir gcc-build
  cd gcc-build
  # Make sure gcc can find the start files.
  sed -e "s:^DRIVER_DEFINES = :DRIVER_DEFINES = -DSTANDARD_STARTFILE_PREFIX_1=\\\\\\\"${DRTEROOT}/lib64/\\\\\\\" -DSTANDARD_STARTFILE_PREFIX_2=\\\\\\\"${DRTEROOT}/lib/\\\\\\\" :" ${SRC}/gcc-Makefile.in.orig > ${SRC}/gcc-${gcc_version}/gcc/Makefile.in
  CC="${STAGE2CC64} -isystem ${DRTEROOT}/include -L${DRTEROOT}/lib64" \
  CXX="${STAGE2CXX64} -isystem ${DRTEROOT}/include -L${DRTEROOT}/lib64" \
  CFLAGS="-g -isystem ${DRTEROOT}/include -L${DRTEROOT}/lib64 -DSTANDARD_INCLUDE_DIR=\\\\\\\"\"${DRTEROOT}/include\\\\\\\"\"" \
  AR="${STAGE2AR}" \
  RANLIB="${STAGE2RANLIB}" \
  AR_FOR_TARGET="${STAGE2AR}" \
  RANLIB_FOR_TARGET="${STAGE2RANLIB}" \
  "${SRC}/gcc-${gcc_version}/configure" \
    --prefix="${DRTEROOT}" \
    --build="${arch64}" \
    --host="${arch64}" \
    --target="${arch64}" \
    --with-pkgversion="$PKGVERSION" \
    --enable-languages="${gcc_languages}" \
    --enable-shared \
    --enable-__cxa_atexit \
    --with-native-system-header-dir="${DRTEROOT}/include" \
    --with-local-prefix="${DRTEROOT}/local" \
    --with-debug-prefix-map="${DEBUG_PREFIX_MAPPINGS}" \
    --with-stage1-ldflags="-static-libstdc++ -static-libgcc -Wl,-I,${DRTEROOT}/lib64/ld-linux-x86-64.so.2" \
    --with-boot-ldflags="-static-libstdc++ -static-libgcc -Wl,-I,${DRTEROOT}/lib64/ld-linux-x86-64.so.2" \
    --disable-libssp \
    ${xtra_gcc_cfg} \
    || error "gcc final configuration failed"
  make $JFLAGS \
    BOOT_CFLAGS="-g -O2 ${DEBUG_PREFIX_MAP_GCC_FLAGS}" \
    FCFLAGS="-g -O2 ${DEBUG_PREFIX_MAP_GCC_FLAGS}" \
    || error "gcc final build failed"
  make install DESTDIR="${idir}" \
    || error "gcc final install failed"
  make install || error "gcc final in-situ install failed"


  #
  # Copy appropriate files to debug-src directory
  #
  idir="${FINALROOT}/packaging/debug-src"
  rm -fr "${idir}"
  mkdir -p "${idir}"

  echo "Copying pristine sources to debug-src/src."
  mkdir -p "${idir}/${DRTEROOT}/debug-src/src"
  cd "${OSRC}"
  find . \( -type d -name 'examples*' -prune \) -o \
         \( -type d -name '*java*' -prune \) -o \
         \( -type d -name 'test*' -prune \) -o \
         \( -type d -name 'docs' -prune \) -o \
         \( -type d -name 'linux-${kernel_headers_version}' -prune \) -o \
         -print |
    cpio -pdm "${idir}/${DRTEROOT}/debug-src/src"

  echo "Copying stage2 generated sources to debug-src/stage2."
  mkdir -p "${idir}/${DRTEROOT}/debug-src/stage2"
  build_directories="
    gcc-build
    glibc-build64
    root
  "
  cd "${STAGE2ROOT}"
  find $build_directories \
       \( -type d -name .libs \) -prune -o \
       \( -name "*.la" \) -prune -o \
       \( -name "*.a" \) -prune -o \
       \( -name "*.so" \) -prune -o \
       \( -name "*.so.*" \) -prune -o \
       \( -type f -name "*.c" \) -print -o \
       \( -type f -name "*.h" \) -print -o \
       \( -type f -name "*.cc" \) -print -o \
       \( -type f -name "*.tcc" \) -print -o \
       \( -type f -name "*.inc" \) -print -o \
       \( -type f -iname "*.s" \) -print -o \
       \( -type d -name gcc \) -print -o \
       \( -type d -name libgcc \) -print | \
    cpio -pdLm "${idir}/${DRTEROOT}/debug-src/stage2"
  # We need to copy all files under the stage2 compiler root, too.
  find root/include \
    -type f -print | \
    cpio -pdLmm "${idir}/${DRTEROOT}/debug-src/stage2"

  echo "Copying final generated sources to debug-src/final."
  mkdir -p "${idir}/${DRTEROOT}/debug-src/final"
  build_directories="
    binutils-build
    gcc-build
    glibc64-build
    kernel-headers
  "
  cd "${FINALROOT}"
  find $build_directories \
       \( -type d -name .libs \) -prune -o \
       \( -name "*.la" \) -prune -o \
       \( -name "*.a" \) -prune -o \
       \( -name "*.so" \) -prune -o \
       \( -name "*.so.*" \) -prune -o \
       \( -type f -name "*.c" \) -print -o \
       \( -type f -name "*.h" \) -print -o \
       \( -type f -name "*.cc" \) -print -o \
       \( -type f -name "*.tcc" \) -print -o \
       \( -type f -name "*.inc" \) -print -o \
       \( -type f -iname "*.s" \) -print -o \
       \( -type d -name gcc \) -print -o \
       \( -type d -name libgcc \) -print  | \
    cpio -pdLm "${idir}/${DRTEROOT}/debug-src/final"

  echo "Fixing permissions on debug-src."
  chmod -R u=rwX,go=rX "${idir}"
}
