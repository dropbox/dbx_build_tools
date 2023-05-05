#!/bin/sh
# This is a small wrapper around rustc to allow building crates under setuptools_rust.
# We expect RUST_TC to be set by the caller, and VPIP_EXECROOT to be set by vpip.
arch=x86_64-unknown-linux-gnu

RUST_ROOT=$VPIP_EXECROOT/$RUST_TC

$RUST_ROOT/rustc/bin/rustc -L $RUST_ROOT/rustc/lib \
    -L $RUST_ROOT/rust-std-$arch/lib/rustlib/$arch/lib \
    -C linker=$CC \
    -C link-args=-Wl,-I/usr/drte/v5/lib64/ld-linux-x86-64.so.2 \
    "$@"
