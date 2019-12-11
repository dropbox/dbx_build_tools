# A script that prints out the names of Python standard library modules. This is used to generate
# gen_build_py.py's list. The script makes some assumptions about the interpreter installation. For
# example, the stdlib can't be a zip file.
from __future__ import print_function

import os
import sys

IGNORE = frozenset(("sitecustomize", "test", "xxlimited", "xxsubtype"))

IGNORE_DIRS = ("dist-packages", "lib-tk", "sites-packages", "sitecustomize")

mods = list(sys.builtin_module_names)
for path in sys.path[1:]:
    if not os.path.isdir(path) or os.path.basename(path) in IGNORE_DIRS:
        continue
    for ent in os.listdir(path):
        fullpath = os.path.join(path, ent)
        if ent.endswith(".py"):
            mods.append(ent[:-3])
        elif ent.endswith(".so"):
            mods.append(ent.partition(".")[0])
        elif os.path.isdir(fullpath) and os.path.isfile(
            os.path.join(fullpath, "__init__.py")
        ):
            mods.append(ent)
for mod in mods:
    if "." not in mod and (not mod.startswith("_") or mod.startswith("__")):
        print("    {!r},".format(mod))
