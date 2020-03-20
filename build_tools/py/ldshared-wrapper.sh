#!/bin/bash -e

# This script wraps the linker in order to pass -shared to it. In theory, we
# could just set LDSHARED="$LD -shared" but some packages get cranky if they
# can't stat $LDSHARED.
#
# We also want to remove all -l flags except for libraries in DRTE. This is
# because vpip directly injects native dependencies as static libraries rather
# than using the linker search path. This is complicated by the fact that Python
# extensions can make their own internal C libraries, which distutils then links
# using -l. We address this by resolving -l arguments manually to static
# libraries if possible.

# Find relative -L arguments. These directories are where the internal libraries
# will be placed by distutils.
declare -a libdirs
for flag in "$@"; do
    if [[ "$flag" == -L* ]]; then
        libdirs+=("${flag#-L}")
    fi
done

declare -a opts
for flag in "$@"; do
    if [[ "$flag" == -l* ]]; then
        lib="${flag#-l}"
        if [[ ! "$lib" =~ ^(dl|gfortran|m|rt)$ ]]; then
            for libdir in "${libdirs[@]}"; do
                staticlib="$libdir/lib"$lib".a"
                if [[ -f "$staticlib" ]]; then
                    flag="$staticlib"
                fi
            done
            if [[ "$LDSHARED_WRAPPER_IGNORE_MISSING_STATIC_LIBRARIES" == "1" ]]; then
                # Drop the flag if we didn't find a static library matching it.
                if [[ "$flag" == -l* ]]; then
                    continue
                fi
            fi
        fi
    fi
    if [[ -n "$flag" ]]; then
        opts+=("$flag")
    fi
done
# Add libstdc++ if needed. Not supported on macOS!
if [[ "$OSTYPE" != "darwin"* ]]; then
    opts+=(-Wl,--as-needed,-lstdc++,--no-as-needed)
fi
# Append additional object files/libraries passed from vpip to the end of command line options.
opts+=($LDSHARED_WRAPPER_ADDITIONAL_LIBS)


$CC -shared "${opts[@]}"
