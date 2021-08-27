from dataclasses import dataclass, field
from typing import Tuple

VERSION = "1.1.1l"


@dataclass(frozen=True)
class Platform:
    bzl_os: str
    bzl_cpu: str
    openssl_moniker: str
    compile_def_flag: str = '-D'
    asm_copts: Tuple[str] = field(default_factory=tuple)
    copts: Tuple[str] = field(default_factory=tuple)
    defines: Tuple[str] = field(default_factory=tuple)

    def __str__(self):
        return "_".join((self.bzl_os, self.bzl_cpu))

POSIX_ASM_COPTS = (
    '# As described in https://github.com/openssl/openssl/issues/4575.',
    '# OpenSSL doesnt mark its assembly as not needing an executable stack.',
    '# Pass --noexecstack to the assembler to do this.',
    '"-Wa,--noexecstack"',
)

POSIX_COPTS = (
    '"-iquote"',
    '"$(GENDIR)/external/org_openssl/crypto"',
    '"-I"',
    '"external/org_openssl"',
    '"-I"',
    '"external/org_openssl/include"',
    '"-I"',
    '"external/org_openssl/crypto/modes"',
    '"-I"',
    '"external/org_openssl/crypto/include"',
    '"-iquote"',
    '"external/org_openssl/crypto/ec/curve448/arch_32"',
    '"-iquote"',
    '"external/org_openssl/crypto/ec/curve448"',
    '"-I"',
    '"$(GENDIR)/external/org_openssl/crypto/include"',
)

POSIX_DEFINES = (
    '# This hardcoded path into the system mean we will find the system certs. Note Debian sets',
    '# OPENSSLDIR=/usr/lib/ssl, but /usr/lib/ssl mostly consists of symlinks into /etc/ssl. We',
    '# must set /etc/ssl here because some environments (e.g., YSS root filesystems) dont have',
    '# /usr/lib/ssl at all.',
    r'"-DOPENSSLDIR=\\\"/etc/ssl\\\""',
    '# This is basically a no-op, since we have disabled dynamic loading of engines.',
    r'"-DENGINESDIR=\\\"/usr/lib/engines-1.1\\\""',
    '"-DL_ENDIAN"',
    '"-DOPENSSL_USE_NODELETE"',
)

# Mapping from what the bazel rules will call a platform to the openssl rules
PLATFORMS = [
    Platform(
        bzl_os='linux',
        bzl_cpu='x86_64',
        openssl_moniker='linux-x86_64',
        asm_copts=POSIX_ASM_COPTS, # typing: None
        copts=POSIX_COPTS, # typing: None
        defines=POSIX_DEFINES, #typing: None
    ),
    Platform(
        bzl_os='macos',
        bzl_cpu='x86_64',
        openssl_moniker='darwin64-x86_64-cc',
        asm_copts=POSIX_ASM_COPTS, # typing: None
        copts=POSIX_COPTS, # typing: None
        defines=POSIX_DEFINES, #typing: None
    ),
    Platform(
        bzl_os='macos',
        bzl_cpu='aarch64',
        openssl_moniker='darwin64-arm64-cc',
        asm_copts=POSIX_ASM_COPTS, # typing: None
        copts=POSIX_COPTS, # typing: None
        defines=POSIX_DEFINES, #typing: None
    ),
]

# Files that we care about to compile
INCLUDES = [
    "include/crypto/bn_conf.h", "include/crypto/dso_conf.h", "include/openssl/opensslconf.h",
    "apps/progs.h"
]
