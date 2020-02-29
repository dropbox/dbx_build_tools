# mypy: skip-file

"""Create a wheel of PIP installed dependencies.

A new virtualenv is created and the wheels passed in as --build-dep
are installed and then pip creates a wheel of of this pypi dependency.
"""

import argparse
import errno
import glob
import os
import shutil
import subprocess
import sys
import tempfile

ARGS = None


def run_silently(cmd, env=None, cwd=None):
    "Run a subprocess and swallow its output unless it fails."
    try:
        subprocess.check_output(cmd, env=env, cwd=cwd, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as e:
        sys.stderr.buffer.write(e.output)
        raise


def index_url_flags_if_required():
    if ARGS.index_url:
        return ["--index-url", ARGS.index_url]
    return []


def asan_options():
    return "detect_leaks=0:suppressions=" + os.path.abspath(
        os.path.join(os.path.dirname(__file__), "asan-suppressions.txt")
    )


def get_unix_pip_env(venv, venv_source, execroot):
    env = {}

    # Some scripts like to look for your home if you haven't specified
    # it which can let someone else's ~/.pydistutils.cfg mangle your
    # build. Note this may be overridden by the package.
    env["HOME"] = "/dev/null"
    env["PATH"] = "/usr/bin:/bin"

    # Ignore known ASAN failures.
    env["ASAN_OPTIONS"] = asan_options()

    # Add environment from the package.
    for k in os.environ:
        env[k] = os.environ[k].replace(ARGS.root_placeholder, execroot)
    if ARGS.fortran_compiler:
        env["F77"] = env["F90"] = os.path.join(os.getcwd(), ARGS.fortran_compiler)
    env["AR"] = os.path.join(os.getcwd(), ARGS.archiver)
    env["CC"] = os.path.join(os.getcwd(), ARGS.compiler_executable)
    env["LD"] = env["CC"]
    env["LDSHARED"] = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "ldshared-wrapper")
    )
    env["LDSHARED_WRAPPER_IGNORE_MISSING_STATIC_LIBRARIES"] = (
        "1" if ARGS.ignore_missing_static_libraries else "0"
    )

    # Add 'D' (deterministic) flag for ar.
    env["ARFLAGS"] = "Drc"

    # Use the same wrapper for C++ links as for normal links. We always try to link with
    # libstdc++.
    env["CXX"] = env["LDSHARED"]

    # Environment variables seem much more reliable than forcing global options.
    if ARGS.include_paths:
        env["CFLAGS"] = " ".join(
            "-I%s" % os.path.join(execroot, path) for path in ARGS.include_paths
        )
    else:
        env["CFLAGS"] = ""

    env["CFLAGS"] += " -pthread"

    if not ARGS.no_debug_prefix_map:
        # Prevent the absolute execroot path from being hardcoded in debug info. (Recall that the
        # toolchain lives in the execroot rather than the system.)
        env["CFLAGS"] += " -fdebug-prefix-map=%s/=" % os.getcwd()
        # Similarly, map the "venv", which is living in a temporary directory into its source.
        env["CFLAGS"] += " -fdebug-prefix-map=%s/=%s/" % (venv, venv_source)

    ensure_absolute = False
    for compile_flag in ARGS.compile_flags:
        compile_flag = compile_flag.replace(ARGS.root_placeholder, execroot)
        # If flag is like '-isystem foo', expand 'foo' to an absolute path
        if compile_flag.startswith("-isystem "):
            relpath = compile_flag.split("-isystem ")[1]
            env["CFLAGS"] += " -isystem " + os.path.join(execroot, relpath)
        # If flag is like '-iquote bar', expand 'bar' to an absolute path
        elif compile_flag.startswith("-iquote "):
            relpath = compile_flag.split("-iquote ")[1]
            env["CFLAGS"] += " -iquote " + os.path.join(execroot, relpath)
        elif compile_flag.startswith("-I "):
            relpath = compile_flag.split("-I ")[1]
            env["CFLAGS"] += " -I " + os.path.join(execroot, relpath)
        # Pass all other flags in as is.
        else:
            if ensure_absolute and not compile_flag.startswith("/"):
                compile_flag = os.path.join(execroot, compile_flag)
            ensure_absolute = compile_flag == "-idirafter"
            # Escape quotes just right so both distutils and autoconf (no
            # kidding) pass them correctly.
            env["CFLAGS"] += " " + compile_flag.replace('"', r"\"")

    env["LDFLAGS"] = ""
    if ARGS.extra_ldflags:
        env["LDFLAGS"] += " " + " ".join(ARGS.extra_ldflags)
    env["LDFLAGS"] += " -pthread"

    # Prevent symbols from dependent archives from being dynamically exported by extension
    # modules. This keeps libraries linked to the python executable and other extension modules from
    # interfering with this extension module. We could achieve similar ends with -Bsymbolic; hiding
    # symbols is cleaner, though.
    if ARGS.linux_exclude_libs:
        env["LDFLAGS"] += " -Wl,--exclude-libs=ALL"

    if ARGS.extra_path:
        env["PATH"] += ":" + ":".join(
            os.path.join(execroot, path) for path in ARGS.extra_path
        )

    return env


def get_windows_pip_env(execroot):
    env = {}

    # Add environment from the package.
    for k in os.environ:
        env[k] = os.environ[k].replace(ARGS.root_placeholder, execroot)

    # See the analogous comment for non-Windows environments. Some
    # pip packages require HOME to be set.
    env["HOME"] = "C:\\Users\\null"

    # Indicate to distutils that it does not need to go looking for the compiler.
    env["MSSdk"] = "1"
    env["DISTUTILS_USE_SDK"] = "1"

    if ARGS.include_paths:
        env["INCLUDE"] = ";".join(
            os.path.join(execroot, path) for path in ARGS.include_paths
        )

    env["CL"] = ""
    env["LINK"] = ""

    # Some compile flags are include paths, which will either be in the form
    # of "-I foo", "-isystem foo", or "-iquote foo". All other flags can just
    # be passed wholesale.
    for compile_flag in ARGS.compile_flags:
        compile_flag = compile_flag.replace(ARGS.root_placeholder, execroot)
        if compile_flag.startswith("-isystem "):
            relpath = compile_flag.split("-isystem ")[1]
            env["INCLUDE"] += os.pathsep + os.path.join(execroot, relpath)
        elif compile_flag.startswith("-iquote "):
            relpath = compile_flag.split("-iquote ")[1]
            env["INCLUDE"] += os.pathsep + os.path.join(execroot, relpath)
        elif compile_flag.startswith("-I "):
            relpath = compile_flag.split("-I ")[1]
            env["INCLUDE"] += os.pathsep + os.path.join(execroot, relpath)
        # Pass the rest of the flags as is to the compiler.
        else:
            env["CL"] += " " + compile_flag

    # Just pass the linker flags wholesale to the linker.
    for linker_flag in ARGS.extra_ldflags:
        env["LINK"] += " " + linker_flag

    if ARGS.extra_path:
        env["PATH"] += ";" + ";".join(
            os.path.join(execroot, path) for path in ARGS.extra_path
        )

    return env


# Perform an installation via PIP, compile any dependencies,
def build_pip_archive(workdir):
    wheelhouse_dir = os.path.join(workdir, "wheelhouse")

    # Make a "virtualenv" by copying the Python prefix. We expect ARGS.python to be in the
    # execroot in a "bin" directory.
    venv = os.path.join(workdir, "env")
    assert not ARGS.python.startswith("/"), "expecting execroot-relative python"
    venv_source = os.path.dirname(os.path.dirname(ARGS.python))
    shutil.copytree(venv_source, venv, symlinks=False)
    venv_python = os.path.join(
        venv,
        os.path.basename(os.path.dirname(ARGS.python)),
        os.path.basename(ARGS.python),
    )

    # Bootstrap the Python toolchain from wheels.
    external_dir = os.path.join(os.path.dirname(__file__), "..", "..", "..")

    # On Windows, we may get paths prepended with \\?\ (indicating a long path).
    # These do not work in commands, so trim the prefix if we see it.
    if ARGS.msvc_toolchain and external_dir.startswith("\\\\?\\"):
        external_dir = external_dir[4:]

    pip_wheel = os.path.join(
        external_dir, "io_pypa_pip_whl", "file", "pip-9.0.1-py2.py3-none-any.whl"
    )
    # If you change the setuptools version, please update the //pip/setuptools target.
    st_wheel = os.path.join(
        external_dir,
        "io_pypa_setuptools_whl",
        "file",
        "setuptools-41.0.1-py2.py3-none-any.whl",
    )
    wheel_wheel = os.path.join(
        external_dir, "io_pypa_wheel_whl", "file", "wheel-0.33.4-py2.py3-none-any.whl"
    )

    install_env = {"PYTHONPATH": pip_wheel}

    if ARGS.msvc_toolchain:
        # If we do not set the SYSTEMROOT, Python fails to get
        # random numbers to initialize on Windows.
        install_env["SYSTEMROOT"] = os.environ["SYSTEMROOT"]
    else:
        install_env["ASAN_OPTIONS"] = asan_options()

    run_silently(
        [
            venv_python,
            "-m",
            "pip",
            "install",
            "--no-index",
            pip_wheel,
            st_wheel,
            wheel_wheel,
        ],
        env=install_env,
    )

    execroot = os.getcwd()
    # Symlink the execroot to a deterministic place, so that we can refer to it with absolute paths
    # reproducibly.
    # TODO: This currently does not work on Windows. Because there is no sandbox, there's a very
    #       high probability that this symlink already exists (left over from a previous run).
    #       This should be fixed.
    if not ARGS.msvc_toolchain:
        deterministic_execroot = "/tmp/vpip-execroot-".format(
            ARGS.wheel.replace("/", "_")
        )
        try:
            os.symlink(os.getcwd(), deterministic_execroot)
        except OSError as e:
            # Not in the sandbox? Too bad for you.
            if e.errno != errno.EEXIST:
                raise
        else:
            execroot = deterministic_execroot

    if ARGS.msvc_toolchain:
        env = get_windows_pip_env(execroot=execroot)
    else:
        env = get_unix_pip_env(venv=venv, venv_source=venv_source, execroot=execroot)

    # Force wheel zip file entries have a constant modified timestamp.
    env["SOURCE_DATE_EPOCH"] = "1541963471"

    # Inhibit pyc creation during installation. It's not very useful and inhibits some packages from
    # writing (non-deterministic) pycs into the build product.
    env["PYTHONDONTWRITEBYTECODE"] = "1"

    def pip_cmd(cmd, *args):
        return (
            [
                venv_python,
                "-m",
                "pip",
                "--disable-pip-version-check",
                "--no-cache-dir",
                cmd,
                "--no-binary=:all:",
                "--only-binary=tensorboard",  # There are no source packages for //pip/tensorboard .
            ]
            + index_url_flags_if_required()
            + list(args)
        )

    def run_pip(cmd):
        # Some packages leak their absolute build directories into the final
        # wheel. Thus, to be deterministic, the build directory must be
        # deterministic. We select one in /tmp. This works fine in the
        # sandbox. However, in standalone mode, multiple bazel instances could
        # try to use the same build directory (perhaps on the YAPS
        # buildbox). It's tempting to address this by putting the build
        # directory within the execroot, but then we lose consistency
        # across workspace locations. Thus, we try to create the deterministic
        # build directory--this should always work in the sandbox--but fallback
        # to pip's random build directory if the deterministic one already
        # exists. Essentially, we trade determinism outside the sandbox for
        # determinism within it.

        # For Windows, we default to the system-specified TEMP dir. Note that this
        # will have the user embedded, like `C:\Users\username\AppData\Local\Temp`,
        # and currently is not deterministic.
        if ARGS.msvc_toolchain:
            build_dir_prefix = os.environ["TEMP"]
        else:
            build_dir_prefix = "/tmp"

        build_dir = os.path.join(build_dir_prefix, "vpip-build-{}".format(os.path.basename(ARGS.wheel)))
        made_build_dir = False
        try:
            os.mkdir(build_dir)
        except OSError as e:
            if e.errno != errno.EEXIST:
                raise
        else:
            made_build_dir = True
            cmd.extend(["--build-dir", build_dir])
        try:
            run_silently(cmd, env)
        finally:
            # An unfortunate side-effect of passing --build-dir is that pip
            # doesn't clean up after itself.
            if made_build_dir:
                shutil.rmtree(build_dir, ignore_errors=True)

    # Install the build dependencies
    for wheel_path in ARGS.build_dep:
        cmd = pip_cmd("install", "--prefix", venv, "--no-deps", "-vvv", wheel_path)
        run_pip(cmd)

    cmd = pip_cmd("wheel")
    cmd.append("-vvv")
    if ARGS.no_deps:
        cmd.append("--no-deps")
    for op in ARGS.global_options:
        op = op.replace(ARGS.root_placeholder, deterministic_execroot)
        cmd.append("--global-option=%s" % op)
    for op in ARGS.build_options:
        cmd.append("--build-option=" + op)
    cmd.extend(["--wheel-dir", wheelhouse_dir])

    if ARGS.extra_libs or ARGS.extra_dynamic_libs:
        cmd.append("--global-option=build_ext")

        library_dirs = set()
        libraries = []
        link_objs = []
        for lib in ARGS.extra_libs:
            if lib.startswith("-l"):
                libraries.append(lib[2:])
            else:
                # NOTE: Normally we want to use the `--link-objects` option for
                #       but it doesn't appear to do anything for MSVC, so
                #       add the libraries to libraries/library_dirs instead.
                # pip will change the working directory, so use absolute paths.
                if ARGS.msvc_toolchain:
                    libraries.append(os.path.basename(lib)[:-len(".lib")])
                    library_dirs.add(os.path.dirname(os.path.abspath(lib)))
                else:
                    link_objs.append(os.path.abspath(lib))
        for dyn_lib in ARGS.extra_dynamic_libs:
            library_dirs.add(os.path.abspath(os.path.dirname(dyn_lib)))
            dyn_lib_name = os.path.basename(dyn_lib)
            dyn_lib_name = dyn_lib_name[: -len(ARGS.dynamic_lib_suffix)]
            # If the library is prefixed with "lib", remove it. Libraries
            # on Windows are not prefixed by "lib".
            if not ARGS.msvc_toolchain and dyn_lib_name.startswith("lib"):
                dyn_lib_name = dyn_lib_name[len("lib") :]
            libraries.append(dyn_lib_name)
        if library_dirs:
            cmd.append("--global-option=--library-dirs=%s" % os.pathsep.join(library_dirs))
        if libraries:
            cmd.append("--global-option=--libraries=%s" % " ".join(libraries))
        if link_objs:
            cmd.append("--global-option=--link-objects=%s" % " ".join(link_objs))

    for framework in ARGS.extra_frameworks:
        name, _ = os.path.splitext(os.path.basename(framework))
        # For each framework, link using `-framework` and pass the search path using -F.
        # distutils does not provide a way to pass link arguments via command line. There seems to be either
        # `extra_link_args` in the extension setup, or adding them to LDFLAGS.
        env["LDFLAGS"] += " -F{} -framework {}".format(
            os.path.abspath(os.path.dirname(framework)), name
        )

    if ARGS.local_module_base:
        sdist = os.path.join(os.getcwd(), ARGS.local_module_base)
        # Inform pip of the distribution name contained in the sdist by adding
        # an "#egg=" fragment to the sdist URL. We shouldn't need to do this as
        # pip has the ability infer the distribution name after unpacking the
        # sdist. Weirdly and unfortunately, that functionality causes it to
        # ignore --build-dir, which we require for determinism. See
        # https://github.com/pypa/pip/issues/4242.
        cmd.append("file://{}#egg={}".format(sdist, ARGS.dist_name))
    else:
        cmd.extend(ARGS.package_names)

    run_pip(cmd)

    if ARGS.wheel:
        whl_file = glob.glob(os.path.join(wheelhouse_dir, "*.whl"))[0]
        shutil.copy(whl_file, ARGS.wheel)


def main():
    global ARGS
    p = argparse.ArgumentParser(usage=__doc__)
    p.add_argument("-o", "--wheel", help="The location for the whl output file")
    p.add_argument(
        "--python", required=True, help="Path of the python binary to build with"
    )
    p.add_argument("--build-tag", help="Interpreter ABI")
    p.add_argument(
        "--build-dep",
        default=[],
        action="append",
        help="Path to a wheel file required at build time",
    )
    p.add_argument("--toolchain-root", default="/usr")
    p.add_argument("--archiver", help="path to unix ar tool")
    p.add_argument("--compiler-executable", help="C++ compiler")
    p.add_argument("--fortran-compiler", help="the fortran compiler")
    p.add_argument(
        "--include-path",
        dest="include_paths",
        default=[],
        action="append",
        help="Extra C include paths",
    )
    p.add_argument(
        "--compile-flags",
        dest="compile_flags",
        default=[],
        action="append",
        help="Extra GCC compile flags",
    )
    p.add_argument(
        "--extra-path", help="Additional PATH to set", default=[], action="append"
    )
    p.add_argument(
        "--extra-ldflags",
        dest="extra_ldflags",
        default=[],
        action="append",
        help="Extra LDFLAG entries required to install a module",
    )
    p.add_argument(
        "--extra-lib",
        dest="extra_libs",
        default=[],
        action="append",
        help="Extra library to link into the extension module",
    )
    p.add_argument(
        "--extra-dynamic-lib",
        dest="extra_dynamic_libs",
        default=[],
        action="append",
        help="Extra dynamic library to link into the extension module",
    )
    p.add_argument(
        "--target-dynamic-lib-suffix",
        dest="dynamic_lib_suffix",
        required=True,
        help="The suffix (with a period) used by the target platform for dynamic libraries (.so on Linux, .dylib on macOS),",
    )
    p.add_argument(
        "--extra-framework",
        dest="extra_frameworks",
        default=[],
        action="append",
        help="(macOS ONLY) Extra frameworks to link into the extension module",
    )
    p.add_argument(
        "--msvc-toolchain",
        action="store_true",
        help="Specifies that we're working with the MSVC toolchain.",
    )
    p.add_argument(
        "--linux-exclude-libs",
        action="store_true",
        help="""Add Linux specific flags to the linker to prevent extensions
        from exporting symbols from dependent archives.""",
    )
    p.add_argument(
        "--no-debug-prefix-map",
        action="store_true",
        help="Skip adding -fdebug-prefix-map. Used when the compiler does not support the switch.",
    )
    p.add_argument(
        "--no-deps",
        action="store_true",
        help="Prevent PIP from automatically pulling dependencies.",
    )
    p.add_argument(
        "--local-module-base", help="Location of an sdist tar file to be installed."
    )
    p.add_argument(
        "--dist-name",
        help="Name of the distribution. Required if using --local-module-base",
    )
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("--index-url")
    p.add_argument(
        "--global-option", dest="global_options", default=[], action="append"
    )
    p.add_argument("--build-option", dest="build_options", default=[], action="append")
    p.add_argument(
        "--root-placeholder",
        default="____root____",
        help="Placeholder text to be replaced with absolute path to CWD in command and env vars",
    )
    p.add_argument(
        "--ignore-missing-static-libraries",
        action="store_true",
        help="Ignore library if it can't be linked statically.",
    )
    p.add_argument("package_names", nargs="*", help="packages to install")
    ARGS = p.parse_args()

    if not ARGS.local_module_base and len(ARGS.package_names) == 0:
        sys.exit(
            "Must either specify a local module (using --local-module-base) "
            "or a list of pip dependencies to be installed"
        )

    for name in ARGS.package_names:
        parts = name.split("==")
        if len(parts) != 2 or not parts[1]:
            sys.exit(
                "must specify exact version for package %(name)s with %(name)s==x.y.z"
                % vars()
            )

    workdir = tempfile.mkdtemp()
    build_pip_archive(workdir)
    shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
