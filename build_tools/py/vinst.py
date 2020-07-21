# mypy: allow-untyped-defs

import argparse
import os
import shutil
import subprocess
import sys
import zipfile

if sys.version_info[0] == 2:
    from ConfigParser import RawConfigParser
    from StringIO import StringIO
else:
    from configparser import RawConfigParser
    from io import StringIO


SCRIPT = """
import sys
import {mod}

sys.exit({mod}.{func}())
"""


class ConsoleScriptMissingError(Exception):
    pass


def short_name(filename):
    parts = filename.split("/")
    if parts[0].endswith(".data") and parts[1] in ("purelib", "platlib"):
        filename = "/".join(parts[2:])
    return filename


def should_include_file(filename, excludes):
    # If you change this function all pip rules need to be regenerated
    if " " in filename:
        return False
    parts = filename.split("/")
    if parts[0].endswith(".data") and parts[1] in ("purelib", "platlib"):
        return True
    elif parts[0].endswith(".data"):
        return False
    elif filename.endswith((".pyc", ".pyo")):
        return False
    elif filename.endswith("/"):
        return False
    else:
        if filename in excludes:
            return False
        for name in parts:
            if name in excludes:
                return False
        return True


def get_console_scripts(wheel):
    for name in wheel.namelist():
        if name.endswith("dist-info/entry_points.txt"):
            config = RawConfigParser()
            # No clue some entry_points.txt files have leading space
            data = [l.decode("utf-8").strip() for l in wheel.open(name)]
            config.readfp(StringIO("\n".join(data)))
            if config.has_section("console_scripts"):
                return dict(config.items("console_scripts"))
            else:
                return {}
    return {}


def create_script_from_entrypoint(wheel, script, out_path):
    console_scripts = get_console_scripts(wheel)
    try:
        entry = console_scripts[script]
    except KeyError:
        raise ConsoleScriptMissingError(
            "Could not find a console script for %r" % script
        )
    entry = get_console_scripts(wheel)[script]
    mod_name, func_name = entry.split(":")
    with open(out_path, "w") as out:
        out.write(SCRIPT.format(mod=mod_name, func=func_name))


def extract_script(wheel, script, out_path):
    for name in wheel.namelist():
        if name.endswith("/scripts/" + script):
            with open(out_path, "wb") as out:
                shutil.copyfileobj(wheel.open(name), out)


def create_script(wheel, script, out_path):
    try:
        create_script_from_entrypoint(wheel, script, out_path)
    except ConsoleScriptMissingError:
        extract_script(wheel, script, out_path)


def install(
    wheel,
    target,
    target_short_path,
    excludes,
    namespace_pkgs,
    pyc_compiler,
    pyc_build_tag,
    pyc_python,
):
    to_compile = []
    namespace_pkg_inits = {
        os.path.join(*(pkg.split(".") + ["__init__.py"])) for pkg in namespace_pkgs
    }
    for init in namespace_pkg_inits:
        install_path = os.path.join(target, init)
        os.makedirs(os.path.dirname(install_path), exist_ok=True)  # type: ignore[call-arg]
        open(install_path, "wb").close()
        to_compile.append(init)
    for name in wheel.namelist():
        if not should_include_file(name, excludes):
            continue
        install_name = short_name(name)
        if install_name in namespace_pkg_inits:
            continue
        install_path = os.path.join(target, install_name)
        dirname = os.path.dirname(install_path)
        os.makedirs(dirname, exist_ok=True)  # type: ignore[call-arg]

        with open(install_path, "wb") as out:
            shutil.copyfileobj(wheel.open(name), out)
        if install_name.endswith(".py"):
            to_compile.append(install_name)
    if pyc_compiler and to_compile:
        args = [
            pyc_compiler,
            # Thirdparty .py files can contain all manner of brokenness.
            "--allow-failures",
        ]
        for py in to_compile:
            args.append(os.path.join(target, py))
        for py in to_compile:
            args.append(os.path.join(target_short_path, py))
        for py in to_compile:
            if pyc_build_tag:
                dirname, basename = os.path.split(py)
                args.append(
                    os.path.join(
                        target,
                        dirname,
                        "__pycache__",
                        basename[:-2] + pyc_build_tag + ".pyc",
                    )
                )
            else:
                args.append(os.path.join(target, py + "dbxc"))
        subprocess.check_call(
            args, env={"PYTHONHASHSEED": "4", "DBX_PYTHON": pyc_python}
        )


def main(args):
    with zipfile.ZipFile(args.wheel) as wheel:
        if args.cmd == "install":
            install(
                wheel,
                args.target,
                args.target_short_path,
                args.exclude,
                args.namespace_pkg,
                args.pyc_compiler,
                args.pyc_build_tag,
                args.pyc_python,
            )
        elif args.cmd == "script":
            create_script(wheel, args.script, args.out)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Install a wheel")
    subparsers = parser.add_subparsers(dest="cmd")
    install_parser = subparsers.add_parser("install", help="install a wheel")
    install_parser.add_argument(
        "--namespace_pkg",
        help="add namespace package that the wheel participates in",
        action="append",
        default=[],
    )
    install_parser.add_argument(
        "--exclude",
        help="patterns to exclude from extraction",
        action="append",
        default=[],
    )
    install_parser.add_argument(
        "--pyc_compiler", help="executable to use to compile pycs"
    )
    install_parser.add_argument("--pyc_build_tag", help="tag to put in pyc filenames")
    install_parser.add_argument("--pyc_python", help="python to compile pycs with")
    install_parser.add_argument("wheel", help="wheel to install")
    install_parser.add_argument("target", help="base install path")
    install_parser.add_argument("target_short_path", help="runfiles path of target")

    script_parser = subparsers.add_parser("script", help="write a console script")
    script_parser.add_argument("wheel", help="wheel to install")
    script_parser.add_argument("script", help="script to create")
    script_parser.add_argument("out", help="where to put the script")

    sys.exit(main(parser.parse_args()))
