# coding: utf-8

# mypy: allow-untyped-defs, no-check-untyped-defs

# We implement two custom behaviors on top of normal Python import:
#
# 1. We have our own pyc format that uses a hash of the source file for invalidation rather than the
# source timestamp. This makes pycs a deterministic function of the source file content. That
# property lets us build and cache pycs with Bazel.
#
# 2. We cache directory listings of directories on sys.path and arrange to search the cache instead
# of the filesystem when scanning for top-level modules. This obviates a myriad stat(2) calls when
# sys.path is long. We only cache the directory listings of directories directly on sys.path. The
# search path of packages is usually only one directory, so we would save nothing by caching.
#
# In Python 3, importlib does caching internally, and deteministic pycs may be had with PEP
# 552. Therefore, none of this file should be used on Python 3.

from __future__ import print_function

import ast
import errno
import hashlib
import imp
import marshal
import os
import pkgutil
import sys

DBX_MAGIC = b"dbx" + imp.get_magic()

# Unfortunately, it is critical that DBXImporter subclasses pkgutil.ImpImporter. pkg_resources
# inspects of the MRO of path importer while building its global distribution working
# set. Technically, we could register our importer with pkg_resources.register_finder(), but I don't
# want to pull in pkg_resources if we don't have to—building the aforementioned global working set
# is not cheap.
class DBXImporter(pkgutil.ImpImporter):
    def __init__(self, d, cache=False):
        # type: (str, bool) -> None
        pkgutil.ImpImporter.__init__(self, d)
        self._dir_ents = os.listdir(d) if cache else None

    def find_module(self, fullname, path=None):
        name = fullname.rpartition(".")[2]
        if path is None:
            path = [self.path]
        if self._dir_ents is not None:
            ext = name + ".so"
            py = name + ".py"
            d = os.path.join(self.path, name)
            if (
                ext not in self._dir_ents
                and py not in self._dir_ents
                and (
                    name not in self._dir_ents
                    or not os.path.exists(os.path.join(d, "__init__.py"))
                )
            ):
                # Can't possibly be in this directory.
                return None

        # It would be nice to not catch any ImportError from imp.find_module. Normally, when we
        # reach this spot, we're sure the module we're searching for, if it exists, must be in our
        # path directory. Not catching the ImportError would be a nice assertion of
        # that. Unfortunately, this property isn't true in two cases: 1) For namespace packages, we
        # have to let import delegate to the next entry in the package's __path__. 2) Code that
        # manually invokes import finders expects .find_module() to return None not raise an
        # ImportError if a module isn't found.
        try:
            mod_data = imp.find_module(name, path)
        except ImportError:
            return None
        return DBXLoader(fullname, *mod_data)


class DBXLoader(pkgutil.ImpLoader):
    HASH_LEN = hashlib.md5().digest_size

    def load_module(self, fullname):
        assert fullname == self.fullname
        try:
            if fullname in sys.modules:
                return sys.modules[fullname]
            kind = self.etc[2]
            if kind == imp.PKG_DIRECTORY:
                filename = os.path.join(self.filename, "__init__.py")
                self.file = open(filename, "rb")
                if sys.path_importer_cache.get(self.filename) is None:
                    sys.path_importer_cache[self.filename] = DBXImporter(self.filename)
                mod = self._attempt_dbxpyc_import(fullname, filename, self.file, True)
                if mod is not None:
                    for p in mod.__path__:
                        if sys.path_importer_cache.get(p) is None:
                            sys.path_importer_cache[p] = DBXImporter(p)
                    return mod
            elif kind == imp.PY_SOURCE:
                mod = self._attempt_dbxpyc_import(
                    fullname, self.filename, self.file, False
                )
                if mod is not None:
                    return mod
            mod = imp.load_module(fullname, self.file, self.filename, self.etc)
        finally:
            if self.file is not None:
                self.file.close()
                self.file = None
        return mod

    def _attempt_dbxpyc_import(self, fullname, filename, fp, pkg):
        co = None
        try:
            with open(filename + "dbxc", "rb") as dbxc_fd:
                magic = dbxc_fd.read(len(DBX_MAGIC))
                if magic != DBX_MAGIC:
                    return None
                dbxc_hash = dbxc_fd.read(self.HASH_LEN)
                co = marshal.load(dbxc_fd)
        except IOError as e:
            if e.errno != errno.ENOENT:
                raise
            # Handle empty sources files without dbxpyc files. This case is quite common because
            # Bazel-generated __init__.py files don't have dbxpycs.
            if os.fstat(fp.fileno()).st_size != 0:
                return None
        else:
            hasher = hashlib.md5(fp.read())
            if dbxc_hash != hasher.digest():
                # Rewind, so imp.load_module can process the file.
                fp.seek(0)
                return None

        try:
            mod = sys.modules[fullname] = imp.new_module(fullname)
            if pkg:
                mod.__path__ = [os.path.dirname(filename)]
                mod.__package__ = fullname
            else:
                mod.__package__ = fullname.rpartition(".")[0]
            # We have relative paths inside the code objects for determinism. At runtime, we set
            # __file__ to a full path so os.path.dirname(__file__) and the like still return the
            # paths our users expect. We are also not using dropbox.runfiles to keep the
            # dbx_py_binary required dependencies as small as possible.
            if co is not None:
                mod.__file__ = os.path.join(os.environ["RUNFILES"], co.co_filename)
                exec(co, mod.__dict__)
            else:
                mod.__file__ = filename
            return sys.modules[fullname]
        except:
            if fullname in sys.modules:
                del sys.modules[fullname]
            raise


def install():
    # type: () -> None
    for p in sys.path:
        if os.path.isdir(p):
            sys.path_importer_cache[p] = DBXImporter(p, True)


DOCSTRING_STRIP_EXCEPTIONS = [
    "capirca",
    "statsmodel",
    # scikit-image relies on docstrings to be present
    # https://github.com/scikit-image/scikit-image/blob/master/skimage/measure/_regionprops.py#L977
    "scikit-image",
    # seaborn relies on docstrings internally
    # https://github.com/mwaskom/seaborn/blob/master/seaborn/_docstrings.py
    "seaborn",
    "stone",
]


def dbx_compile(src_path, dest_path, compiled_path, allow_failure):
    # type: (str, str, str, bool) -> bool
    try:
        with open(src_path, "U") as f:
            src = f.read()

        root = ast.parse(src)

        if not any(lib in src_path for lib in DOCSTRING_STRIP_EXCEPTIONS):
            # Strip the docstrings to reduce binary size and memory usage.
            for node in ast.walk(root):
                # See https://github.com/python/cpython/blob/2.7/Lib/ast.py#L187
                if isinstance(node, (ast.FunctionDef, ast.ClassDef, ast.Module)):
                    if (
                        node.body
                        and isinstance(node.body[0], ast.Expr)
                        and isinstance(node.body[0].value, ast.Str)
                    ):
                        # These libraries assume the existence of docstrings on their own methods
                        # and provide decorators that deprecate methods by munging their docstring.
                        # TODO(zbarsky): remove these exceptions after sending patches upstream
                        if (
                            "pylons" in src_path
                            or "paste" in src_path
                            or "weberror" in src_path
                            or "notebook" in src_path
                        ):
                            node.body[0].value.s = " "
                        elif "scipy" in src_path:
                            # TODO(zbarsky) remove if https://github.com/scipy/scipy/pull/10848 is merged
                            node.body[0].value.s = "Parameters\n%s"
                        else:
                            node.body[0].value.s = ""

        h = hashlib.md5(src)
        co = compile(root, compiled_path, "exec", dont_inherit=True)

        with open(dest_path, "wb") as f:
            f.write(DBX_MAGIC)
            f.write(h.digest())
            marshal.dump(co, f)
    except Exception:
        if allow_failure:
            open(dest_path, "wb").close()
            return False
        else:
            print(src_path, "->", dest_path)
            raise
    return True
