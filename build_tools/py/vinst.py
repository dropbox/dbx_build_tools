# mypy: allow-untyped-defs

import argparse
import os
import shutil
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


def should_include_file(filename):
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
        return True


def wheel_contents(wheel):
    contents = []
    for filename in wheel.namelist():
        if should_include_file(filename):
            contents.append(short_name(filename))
    return contents


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


def install(wheel, target, outputs):
    for name in wheel.namelist():
        install_name = short_name(name)
        if install_name in outputs:
            assert should_include_file(
                name
            ), "Unexpected output file requested: {}".format(name)
            install_path = os.path.join(target, install_name)
            dirname = os.path.dirname(install_path)
            if not os.path.exists(dirname):
                os.makedirs(dirname)

            with open(install_path, "wb") as out:
                shutil.copyfileobj(wheel.open(name), out)


def main(args):
    with zipfile.ZipFile(args.wheel) as wheel:
        if args.cmd == "install":
            install(wheel, args.target, args.outputs)
        elif args.cmd == "script":
            create_script(wheel, args.script, args.out)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Install a wheel")
    subparsers = parser.add_subparsers(dest="cmd")
    install_parser = subparsers.add_parser("install", help="install a wheel")
    install_parser.add_argument("wheel", help="wheel to install")
    install_parser.add_argument("target", help="base install path")
    install_parser.add_argument("outputs", nargs="*", help="files to extract")

    script_parser = subparsers.add_parser("script", help="write a console script")
    script_parser.add_argument("wheel", help="wheel to install")
    script_parser.add_argument("script", help="script to create")
    script_parser.add_argument("out", help="where to put the script")

    sys.exit(main(parser.parse_args()))
