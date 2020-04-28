# mypy: allow-untyped-defs

from __future__ import print_function

import glob
import os
import os.path

from typing import Dict, List, Optional, Text

import build_tools.bazel_utils as bazel_utils
import build_tools.build_parser as build_parser

from build_tools.bzl_lib.cfg import (
    ALT_BUILD,
    BUILD_INPUT,
    DEFAULT_BUILD,
    EXTERNAL_PIP_MODULE_TARGETS,
    PIP_RULE_TYPES,
    PY_EXTENSION_RULE_TYPES,
    PY_LIBRARY_RULE_TYPES,
    PY_LOAD_STATEMENT,
    PY_RULE_TYPES,
    WELL_KNOWN_PIP_DIRS,
    WELL_KNOWN_PY_EXTENSION_DIRS,
)
from build_tools.bzl_lib.parse_py_imports import parse_imports

BUILD_OUTPUT = "BUILD.gen_build_py~"

PY_BIN_RULE_TYPES = [
    r for r in PY_RULE_TYPES if r.endswith(("_binary", "_test", "_plugin"))
]

# A unified list of Python 2.7 and 3.7 standard library modules. Generated with:
# sort -u <(python2 build_tools/py/stdlib_modules.py) <(python3.7 build_tools/py/stdlib_modules.py)
STDLIB_MODULES = frozenset(
    (
        "abc",
        "aifc",
        "antigravity",
        "anydbm",
        "argparse",
        "array",
        "ast",
        "asynchat",
        "asyncio",
        "asyncore",
        "atexit",
        "audiodev",
        "audioop",
        "base64",
        "BaseHTTPServer",
        "Bastion",
        "bdb",
        "binascii",
        "binhex",
        "bisect",
        "bsddb",
        "__builtin__",
        "builtins",
        "bz2",
        "calendar",
        "CDROM",
        "cgi",
        "CGIHTTPServer",
        "cgitb",
        "chunk",
        "cmath",
        "cmd",
        "code",
        "codecs",
        "codeop",
        "collections",
        "colorsys",
        "commands",
        "compileall",
        "compiler",
        "concurrent",
        "configparser",
        "ConfigParser",
        "contextlib",
        "contextvars",
        "Cookie",
        "cookielib",
        "copy",
        "copy_reg",
        "copyreg",
        "cPickle",
        "cProfile",
        "crypt",
        "cStringIO",
        "csv",
        "ctypes",
        "curses",
        "dataclasses",
        "datetime",
        "dbhash",
        "dbm",
        "decimal",
        "difflib",
        "dircache",
        "dis",
        "distutils",
        "DLFCN",
        "doctest",
        "DocXMLRPCServer",
        "dumbdbm",
        "dummy_thread",
        "dummy_threading",
        "email",
        "encodings",
        "ensurepip",
        "enum",
        "errno",
        "exceptions",
        "faulthandler",
        "fcntl",
        "filecmp",
        "fileinput",
        "fnmatch",
        "formatter",
        "fpformat",
        "fractions",
        "ftplib",
        "functools",
        "__future__",
        "future_builtins",
        "gc",
        "genericpath",
        "getopt",
        "getpass",
        "gettext",
        "glob",
        "grp",
        "gzip",
        "hashlib",
        "heapq",
        "hmac",
        "hotshot",
        "html",
        "htmlentitydefs",
        "htmllib",
        "HTMLParser",
        "http",
        "httplib",
        "ihooks",
        "imaplib",
        "imghdr",
        "imp",
        "importlib",
        "imputil",
        "IN",
        "inspect",
        "io",
        "ipaddress",
        "itertools",
        "json",
        "keyword",
        "lib2to3",
        "linecache",
        "linuxaudiodev",
        "locale",
        "logging",
        "lzma",
        "macpath",
        "macurl2path",
        "mailbox",
        "mailcap",
        "__main__",
        "markupbase",
        "marshal",
        "math",
        "md5",
        "mhlib",
        "mimetools",
        "mimetypes",
        "MimeWriter",
        "mimify",
        "mmap",
        "modulefinder",
        "multifile",
        "multiprocessing",
        "mutex",
        "netrc",
        "new",
        "nis",
        "nntplib",
        "ntpath",
        "nturl2path",
        "numbers",
        "opcode",
        "operator",
        "optparse",
        "os",
        "os2emxpath",
        "ossaudiodev",
        "parser",
        "pathlib",
        "pdb",
        "pickle",
        "pickletools",
        "pipes",
        "pkgutil",
        "platform",
        "plistlib",
        "popen2",
        "poplib",
        "posix",
        "posixfile",
        "posixpath",
        "pprint",
        "profile",
        "pstats",
        "pty",
        "pwd",
        "pyclbr",
        "py_compile",
        "pydoc",
        "pydoc_data",
        "pyexpat",
        "queue",
        "Queue",
        "quopri",
        "random",
        "re",
        "readline",
        "repr",
        "reprlib",
        "resource",
        "rexec",
        "rfc822",
        "rlcompleter",
        "robotparser",
        "runpy",
        "sched",
        "secrets",
        "select",
        "selectors",
        "sets",
        "sgmllib",
        "sha",
        "shelve",
        "shlex",
        "shutil",
        "signal",
        "SimpleHTTPServer",
        "SimpleXMLRPCServer",
        "site",
        "sitecustomize",
        "smtpd",
        "smtplib",
        "sndhdr",
        "socket",
        "socketserver",
        "SocketServer",
        "spwd",
        "sqlite3",
        "sre",
        "sre_compile",
        "sre_constants",
        "sre_parse",
        "ssl",
        "stat",
        "statistics",
        "statvfs",
        "string",
        "StringIO",
        "stringold",
        "stringprep",
        "strop",
        "struct",
        "subprocess",
        "sunau",
        "sunaudio",
        "symbol",
        "symtable",
        "sys",
        "sysconfig",
        "syslog",
        "tabnanny",
        "tarfile",
        "telnetlib",
        "tempfile",
        "termios",
        "test",
        "textwrap",
        "this",
        "thread",
        "threading",
        "time",
        "timeit",
        "toaiff",
        "token",
        "tokenize",
        "trace",
        "traceback",
        "tracemalloc",
        "tty",
        "turtle",
        "types",
        "TYPES",
        "typing",
        "unicodedata",
        "unittest",
        "urllib",
        "urllib2",
        "urlparse",
        "user",
        "UserDict",
        "UserList",
        "UserString",
        "uu",
        "uuid",
        "venv",
        "warnings",
        "wave",
        "weakref",
        "webbrowser",
        "whichdb",
        "wsgiref",
        "xdrlib",
        "xml",
        "xmllib",
        "xmlrpc",
        "xmlrpclib",
        "xxlimited",
        "xxsubtype",
        "zipapp",
        "zipfile",
        "zipimport",
        "zlib",
    )
)


class ParsedBuildFileCache(object):
    """keeps track of parsed BUILD and BUILD.in files"""

    def __init__(self, workspace_dir):
        self.workspace_dir = os.path.realpath(workspace_dir) + os.path.sep

        # (real or symlink) dir path -> parsed entry
        self.parsed_builds = {}
        self.parsed_bzls = {}

        # dir paths without BUILD(.bzl)
        self.empty_build_dirs = set()
        self.empty_bzl_dirs = set()

    def get_build(self, directory):
        if directory in self.parsed_builds:
            return self.parsed_builds[directory]

        if directory in self.empty_build_dirs:
            return "", None

        build_file = os.path.join(directory, DEFAULT_BUILD)
        assert directory.startswith(
            self.workspace_dir
        ), "Trying to read {} outside of workspace: {}".format(DEFAULT_BUILD, directory)

        if not os.path.isfile(build_file):
            build_file = os.path.join(directory, ALT_BUILD)
            if not os.path.isfile(build_file):
                self.empty_build_dirs.add(directory)
                return "", None

        real_build_file = os.path.realpath(build_file)

        if build_file != real_build_file:  # symlink
            _, entry = self.get_build(os.path.dirname(real_build_file))
        else:
            entry = build_parser.parse_file(real_build_file)

        if entry:
            self.parsed_builds[directory] = (real_build_file, entry)
        else:
            self.empty_build_dirs.add(directory)

        return real_build_file, entry

    def get_bzl(self, directory):
        if not directory.endswith(os.path.sep):
            directory += os.path.sep

        if directory in self.parsed_bzls:
            return self.parsed_bzls[directory]

        if directory in self.empty_bzl_dirs:
            return "", None

        bzl_file = os.path.join(directory, BUILD_INPUT)
        assert directory.startswith(
            self.workspace_dir
        ), "Trying to read {} outside of workspace: {}".format(BUILD_INPUT, directory)

        if not os.path.isfile(bzl_file):
            self.empty_bzl_dirs.add(directory)
            return "", None

        real_bzl_file = os.path.realpath(bzl_file)

        if bzl_file != real_bzl_file:  # symlink
            _, entry = self.get_bzl(os.path.dirname(real_bzl_file))
        else:
            entry = build_parser.parse_file(real_bzl_file)

        if entry:
            self.parsed_bzls[directory] = (real_bzl_file, entry)
        else:
            self.empty_bzl_dirs.add(directory)

        return real_bzl_file, entry

    def get_bzl_or_build(self, directory):
        filename, parsed = self.get_bzl(directory)
        if filename:
            return filename, parsed

        return self.get_build(directory)


class AbstractPythonPath(object):
    def compute_self_modules(self, pkg, srcs):
        """Returns a set of modules"""
        raise NotImplementedError

    def find_closest_bzl_or_build(self, module):
        """Returns (filename, parsed BUILD / BUILD.in)"""
        raise NotImplementedError

    def find_import_targets(self, src_pkg, self_modules, import_modules):
        """Returns (set of deps, set of unknown imports"""
        raise NotImplementedError

    def find_from_targets(self, src_pkg, self_modules, import_modules):
        """Returns (set of deps, set of unknown imports"""
        raise NotImplementedError


class SystemPythonPathMapping(AbstractPythonPath):
    """Keeps track of python system modules"""

    def _is_system_module(self, module):
        # Assumption: checking root module is sufficient to verify the module
        # is a python system module or not.
        module = module.partition(".")[0]
        return module in STDLIB_MODULES

    def compute_self_modules(self, pkg, srcs):
        return set()

    def find_closest_bzl_or_build(self, module):
        return "", None

    def _find_targets(self, modules):
        unknown = set()
        for module in modules:
            if self._is_system_module(module):
                continue
            unknown.add(module)

        return set(), unknown

    def find_import_targets(self, src_pkg, self_modules, import_modules):
        return self._find_targets(import_modules)

    def find_from_targets(self, src_pkg, self_modules, from_modules):
        return self._find_targets(from_modules)


class PythonPathMapping(AbstractPythonPath):
    def __init__(
        self,
        workspace_dir,
        python_path,  # relative to workspace_dir
        parsed_file_cache,
        pip_directories,
        extension_directories=None,
    ):

        self.workspace_dir = os.path.realpath(workspace_dir)
        self.python_path = python_path

        self.python_path_dir = os.path.abspath(os.path.join(workspace_dir, python_path))
        assert self.python_path_dir.startswith(
            self.workspace_dir
        ), "Programming error: %s %s" % (self.workspace_dir, python_path)

        self.parsed_file_cache = parsed_file_cache

        self.pip_directories = pip_directories
        self.extension_directories = extension_directories
        # If you want pip module targets, use get_pip_module_targets.
        self._pip_module_targets = None  # type: Optional[Dict[str, List[str]]]

        self.processed_local_build_dirs = set()
        # python module -> (bazel target, target's srcs size)
        self.local_module_targets = {}

        self.invalid_modules = set()

    def _to_pkg(self, directory):
        # type: (Text) -> Text
        directory = os.path.realpath(directory)
        assert directory.startswith(self.workspace_dir), (
            "Programming error: " + directory
        )
        directory = directory.replace(self.workspace_dir, "/")
        return bazel_utils.normalize_os_path_to_target(directory)

    def get_pip_module_targets(self):
        # type: () -> Dict[str, List[str]]
        if self._pip_module_targets is None:
            pip_module_targets = {}  # type: Dict[str, List[str]]
            self._collect_pips(self.pip_directories, pip_module_targets)
            self._collect_extensions(
                self.extension_directories or [], pip_module_targets
            )
            self._pip_module_targets = pip_module_targets
        return self._pip_module_targets

    def _collect_pips(self, pip_directories, pip_module_targets):
        # type: (List[str], Dict[str, List[str]]) -> None
        if not self.python_path:
            pip_module_targets.update(EXTERNAL_PIP_MODULE_TARGETS)

        for pip_dir in pip_directories:
            for bzl_file in glob.glob(
                os.path.join(self.workspace_dir, pip_dir, "*", BUILD_INPUT)
            ) + glob.glob(os.path.join(self.workspace_dir, pip_dir, BUILD_INPUT)):
                root = os.path.dirname(bzl_file)

                _, parsed = self.parsed_file_cache.get_bzl(root)
                assert parsed, "programming error " + root

                for rule in parsed.get_rules_by_types(PIP_RULE_TYPES):
                    pkg = self._to_pkg(root)
                    name = rule.attr_map["name"]
                    target = pkg + ":" + name

                    provides = rule.attr_map.get("provides", [name])
                    for module in provides:
                        assert (
                            module not in pip_module_targets
                        ), "Found pip module %s in %s and %s" % (
                            module,
                            target,
                            pip_module_targets[module],
                        )
                        pip_module_targets[module] = [target]

    def _collect_extensions(self, extension_directories, pip_module_targets):
        # type: (List[str], Dict[str, List[str]]) -> None
        for ext in extension_directories:
            for root, _, _ in os.walk(os.path.join(self.workspace_dir, ext)):
                _, parsed = self.parsed_file_cache.get_bzl_or_build(root)
                if not parsed:
                    continue

                for rule in parsed.get_rules_by_types(PY_EXTENSION_RULE_TYPES):
                    pkg = self._to_pkg(root)
                    name = rule.attr_map["name"]
                    target = pkg + ":" + name

                    assert (
                        name not in pip_module_targets
                    ), "Extension module %s (%s) conflicts with %s" % (
                        name,
                        target,
                        pip_module_targets[name],
                    )

                    pip_module_targets[name] = [target]

    def _collect_local_targets(self, pkg, parsed):
        path_prefix = pkg[2:]
        if self.python_path:
            if path_prefix == self.python_path:
                path_prefix = path_prefix[len(self.python_path) :]
            elif path_prefix.startswith(self.python_path + "/"):
                path_prefix = path_prefix[len(self.python_path) + 1 :]

        pkg_path = bazel_utils.normalize_relative_target_to_os_path(path_prefix)

        # NOTE: We purposely ignore dbx_py_binary targets, even through it's
        # technically allowed to use dbx_py_binary as deps.
        for lib in parsed.get_rules_by_types(PY_LIBRARY_RULE_TYPES):
            name = lib.attr_map["name"]
            target = pkg + ":" + name

            srcs = lib.attr_map.get("srcs", [])

            for src in srcs:
                assert src.endswith(".py"), "Invalid python src %s in %s" % (src, pkg)

                file_path = os.path.join(pkg_path, src)
                module_path = PythonPathMapping.convert_from_file_path_to_module(
                    file_path
                )

                if module_path in self.local_module_targets:
                    other, other_size = self.local_module_targets[module_path]
                    other_pkg, _, other_name = other.partition(":")
                    if not other_name:
                        other_name = os.path.basename(other_pkg)

                    # Use the target with the more specific pkg path, or the
                    # target with the least srcs
                    overwrite = False
                    if len(other_pkg) < len(pkg):
                        overwrite = True
                    elif other_pkg == pkg:
                        if other_size > len(srcs):
                            overwrite = True
                        elif (
                            other_size == len(srcs)
                            and os.path.basename(other_pkg) == other_name
                        ):
                            overwrite = True  # use the most specific target name

                    if overwrite:
                        self.local_module_targets[module_path] = (target, len(srcs))

                    print(
                        (
                            "WARNING: Module %s specified in multiple targets: "
                            "%s vs %s (autogen_deps may pick the incorrect "
                            "target)"
                        )
                        % (module_path, other, target)
                    )
                    continue

                self.local_module_targets[module_path] = (target, len(srcs))

    def compute_self_modules(self, pkg, srcs):
        target_dir = pkg[2:]

        trim_prefix = 0
        if self.python_path and target_dir.startswith(self.python_path):
            trim_prefix = len(self.python_path) + 1

        self_modules = set()
        for src in srcs:
            file_path = os.path.join(target_dir, src)
            module_path = PythonPathMapping.convert_from_file_path_to_module(file_path)
            self_modules.add(module_path[trim_prefix:])

        return self_modules

    def _get_bzl_or_build(self, build_dir):
        filename, parsed = self.parsed_file_cache.get_bzl_or_build(build_dir)
        if not filename:
            return "", None

        # use real path instead of symlink
        build_dir = os.path.dirname(filename)

        if build_dir not in self.processed_local_build_dirs:
            self.processed_local_build_dirs.add(build_dir)

            pkg = build_dir.replace(self.workspace_dir, "/")
            pkg = bazel_utils.normalize_os_path_to_target(pkg)

            self._collect_local_targets(pkg, parsed)

        return filename, parsed

    def find_closest_bzl_or_build(self, module_path):
        file_path = PythonPathMapping.convert_from_module_to_file_path(module_path)
        path = os.path.join(self.python_path_dir, file_path)
        if os.path.isfile(path + ".py"):
            build_dir = os.path.dirname(path)
        elif os.path.isdir(path):
            build_dir = path
        else:
            return "", None

        while True:
            filename, parsed = self._get_bzl_or_build(build_dir)
            if filename:
                return filename, parsed

            build_dir = os.path.dirname(build_dir)
            if build_dir == self.workspace_dir:
                return "", None

        assert False, "Should never reach here ..."

    def _find_targets(self, module):
        # type: (str) -> List[str]
        if module in self.invalid_modules:
            return []

        self.find_closest_bzl_or_build(module)
        if module in self.local_module_targets:
            return [self.local_module_targets[module][0]]

        orig_module = module
        pip_module_targets = self.get_pip_module_targets()
        while True:
            if module in pip_module_targets:
                return pip_module_targets[module]

            module, _, rest = module.rpartition(".")
            if not rest:
                self.invalid_modules.add(orig_module)
                return []

        assert False, "Should never reach here: " + orig_module

    def find_import_targets(self, src_pkg, self_modules, import_modules):
        all_targets = set()
        unknown = set()
        for module in import_modules:
            if module in self_modules:
                continue
            targets = self._find_targets(module)
            if targets:
                all_targets.update(targets)
            else:
                unknown.add(module)

        return all_targets, unknown

    def find_from_targets(self, src_pkg, self_modules, import_modules):
        all_targets = set()
        unknown = set()
        for module in import_modules:
            if module in self_modules:
                continue
            targets = self._find_targets(module)
            if targets:
                all_targets.update(targets)
                continue

            chunks = module.split(".")
            assert len(chunks) > 1, "Invalid import from module: " + module
            parent_module = ".".join(chunks[:-1])

            if parent_module in self_modules:
                continue

            targets = self._find_targets(parent_module)
            if targets:
                all_targets.update(targets)
            else:
                unknown.add(module)

        return all_targets, unknown

    @classmethod
    # convert from /a/b/c.stoneg.py -> a.b.c\.stoneg
    def convert_from_file_path_to_module(cls, file_path):
        assert file_path.endswith((".py", ".pyi")), "Invalid src: " + file_path
        path_without_extension = file_path.rsplit(".", 1)[0]
        if path_without_extension.endswith("__init__"):
            path_without_extension = os.path.dirname(path_without_extension)
        return path_without_extension.replace(os.path.sep, ".")

    @classmethod
    # convert from a.b.c -> a/b/c (note lack of .py)
    def convert_from_module_to_file_path(cls, module_path):
        return module_path.replace(".", os.path.sep)


class CompositePythonPathMapping(AbstractPythonPath):
    def __init__(self, python_paths):
        self.python_paths = python_paths

    def compute_self_modules(self, pkg, srcs):
        results = set()  # type: ignore[var-annotated]
        for pp in self.python_paths:
            results.update(pp.compute_self_modules(pkg, srcs))

        return results

    def find_closest_bzl_or_build(self, module):
        for pp in self.python_paths:
            filename, parsed = pp.find_closest_bzl_or_build(module)
            if filename:
                return filename, parsed

        return "", None

    def find_import_targets(self, src_pkg, self_modules, import_modules):
        all_targets = set()  # type: ignore[var-annotated]
        unknown_imports = import_modules

        for pp in self.python_paths:
            targets, unknown_imports = pp.find_import_targets(
                src_pkg, self_modules, unknown_imports
            )
            all_targets.update(targets)

        return all_targets, unknown_imports

    def find_from_targets(self, src_pkg, self_modules, from_modules):
        all_targets = set()  # type: ignore[var-annotated]
        unknown_froms = from_modules
        for pp in self.python_paths:
            targets, unknown_froms = pp.find_from_targets(
                src_pkg, self_modules, unknown_froms
            )
            all_targets.update(targets)

        return all_targets, unknown_froms


class PythonPathMappingCache(object):
    def __init__(self, workspace_dir, parsed_file_cache):
        self.workspace_dir = workspace_dir
        self.parsed_file_cache = parsed_file_cache

        self.workspace_python_path = CompositePythonPathMapping(
            [
                PythonPathMapping(
                    workspace_dir,
                    "",
                    parsed_file_cache,
                    WELL_KNOWN_PIP_DIRS,
                    extension_directories=WELL_KNOWN_PY_EXTENSION_DIRS,
                ),
                SystemPythonPathMapping(),
            ]
        )

        self.python_paths = {}

    def get(self, python_path=""):
        if not python_path:
            return self.workspace_python_path

        if python_path in self.python_paths:
            return self.python_paths[python_path]

        local_pp = PythonPathMapping(
            self.workspace_dir, python_path, self.parsed_file_cache, []
        )

        entry = CompositePythonPathMapping([local_pp, self.workspace_python_path])
        self.python_paths[python_path] = entry

        return entry


class PyBuildGenerator(object):
    """This creates intermediate BUILD.gen_build_py files which contains
    dbx_py targets.  The targets' deps are auto-populated if the target
    has autogen_deps set to True.  bzl gen will consume the intermediate
    files to generate the fully merged BUILD files."""

    def __init__(
        self,
        workspace_dir,
        generated_files,
        verbose,
        skip_deps_generation,
        dry_run,
        use_magic_mirror,
    ):
        self.workspace_dir = workspace_dir
        self.generated_files = generated_files
        self.verbose = verbose
        self.skip_deps_generation = skip_deps_generation
        self.dry_run = dry_run

        # Set of visited directory with BUILD.in
        self.visited_bzl_dirs = set()

        # Set of targets in directories without BUILD.in which has been
        # traversed
        self.visited_non_bzl_targets = set()

        self.parsed_cache = ParsedBuildFileCache(workspace_dir)

        self.python_path_mappings = PythonPathMappingCache(
            workspace_dir, self.parsed_cache
        )

    def maybe_traverse_non_bzl(self, expanded_target):
        if self.skip_deps_generation:
            return

        pkg, _, name = expanded_target.partition(":")
        if not name:
            name = os.path.basename(pkg)
            expanded_target = pkg + ":" + name

        if expanded_target in self.visited_non_bzl_targets:
            return
        self.visited_non_bzl_targets.add(expanded_target)

        # Note that expanded_target is guaranteed to be an absolute target.
        pkg_path = bazel_utils.normalize_relative_target_to_os_path(pkg[2:])
        _, parsed = self.parsed_cache.get_build(
            os.path.join(self.workspace_dir, pkg_path)
        )
        if parsed is None:
            return

        try:
            rule = parsed.get_rule(name)
        except KeyError:
            return

        self.regenerate(
            rule.attr_map.get("deps", []),
            cwd=os.path.join(self.workspace_dir, pkg_path),
        )

    def regenerate(self, bazel_targets, cwd="."):
        targets = bazel_utils.expand_bazel_targets(
            self.workspace_dir,
            [t for t in bazel_targets if not t.startswith("@")],
            require_build_file=False,
            cwd=cwd,
        )

        for target in targets:
            assert target.startswith("//"), "Target must be absolute: " + target
            pkg, _, _ = target.partition(":")
            target_dir = bazel_utils.normalize_relative_target_to_os_path(pkg[2:])

            _, parsed = self.parsed_cache.get_bzl(
                os.path.join(self.workspace_dir, target_dir)
            )

            if not parsed:
                self.maybe_traverse_non_bzl(target)
                continue

            if pkg in self.visited_bzl_dirs:
                continue
            self.visited_bzl_dirs.add(pkg)

            py_rules = parsed.get_rules_by_types(PY_RULE_TYPES)

            if not py_rules:
                if self.verbose:
                    print("No py targets found in %s:%s" % (pkg, BUILD_INPUT))
                continue

            if self.verbose:
                head = "(dry run) " if self.dry_run else ""
                print(
                    head
                    + "Processing py targets in %s: %s"
                    % (pkg, [rule.attr_map["name"] for rule in py_rules])
                )

            if self.dry_run:
                continue

            self.generate_build_file(pkg, py_rules)

    def generate_build_file(self, pkg, py_rules):
        to_traverse = []  # type: ignore[var-annotated]
        output = [PY_LOAD_STATEMENT, ""]

        # XXX(patrick): maybe verify that the py_rules is a covering set
        # of all py files in the directory.
        for rule in py_rules:
            assert "name" in rule.attr_map, "Invalid rule %s in %s" % (
                rule.rule_type,
                pkg,
            )
            name = rule.attr_map["name"]
            main = rule.attr_map.get("main", None)
            pip_main = rule.attr_map.get("pip_main", None)
            srcs = rule.attr_map.get("srcs", None)
            stub_srcs = rule.attr_map.get("stub_srcs", None)
            autogen_deps = rule.attr_map.get("autogen_deps", True)
            deps = rule.attr_map.get("deps", [])
            validate = "strict" in rule.attr_map.get("validate", "strict")
            python_path = rule.attr_map.get("pythonpath", "")
            is_py2_compat = rule.attr_map.get("python2_compatible", True)
            is_py3_compat = rule.attr_map.get("python3_compatible", True)
            assert (
                is_py2_compat or is_py3_compat
            ), "Python target must be either python-2 or python-3 compatible"

            unknown_imports, unknown_froms = None, None
            if autogen_deps:
                assert (
                    not deps
                ), "deps should be empty when autogen_deps is " + "enabled: %s:%s" % (
                    pkg,
                    name,
                )

                deps, unknown_imports, unknown_froms = self.compute_deps(
                    python_path,
                    pkg,
                    rule.rule_type,
                    name,
                    srcs,
                    stub_srcs,
                    main,
                    pip_main,
                    validate,
                    is_py3_compat,
                )

            to_traverse.extend(deps)

            if unknown_imports or unknown_froms:
                output.append("# WARNING: autogen_deps may not be correct!!!")
                print("WARNING: autogen_deps may not be correct!!!")
                for i in sorted(unknown_imports):  # type: ignore[arg-type]
                    output.append("#   Unable to locate module: %s" % i)
                    print("   Unable to locate module: %s" % i)
                for i in sorted(unknown_froms):  # type: ignore[arg-type]
                    output.append("#   Unable to locate module/variable: %s" % i)
                    print("   Unable to locate module/variable: %s" % i)
            output.append("%s(" % rule.rule_type)
            output.append("    name = '%s'," % name)
            if pip_main:
                output.append("    pip_main = '%s'," % pip_main)
            if main:
                output.append("    main = '%s'," % main)
            if srcs is None:
                if main:
                    assert rule.rule_type in PY_BIN_RULE_TYPES, (
                        "Programming Error " + rule.rule_type
                    )
                    output.append("    srcs = ['%s']," % main)
                elif pip_main:
                    assert rule.rule_type in PY_BIN_RULE_TYPES, (
                        "Programming Error " + rule.rule_type
                    )
                    output.append("    srcs = [],")
            else:
                output.append("    srcs = [],")
            if deps:
                output.append("    deps = [")
                for dep in deps:
                    output.append("        '%s'," % dep)
                output.append("    ],")
            if rule.rule_type == "dbx_py_library":
                output.append("    validate = 'strict',")
                if python_path:
                    # XXX(patrick): Fix py.bzl to accept pythonpath on all
                    # py targets ...
                    output.append("    pythonpath = '%s'," % python_path)
            output.append(")")
            output.append("")

        build_outdir = os.path.join(self.workspace_dir, pkg[2:])
        build_output = os.path.join(build_outdir, BUILD_OUTPUT)

        with open(build_output, "w") as f:
            f.write("\n".join(output))

        self.generated_files[build_outdir].append(build_output)

        if not self.skip_deps_generation:
            self.regenerate(
                set(to_traverse), cwd=os.path.join(self.workspace_dir, pkg[2:])
            )

    def compute_deps(
        self,
        python_path,
        pkg,
        rule_type,
        name,
        srcs,
        stub_srcs,
        main,
        pip_main,
        validate,
        is_py3_compatible,
    ):
        srcs = (srcs or []) + (stub_srcs or [])
        if main:
            srcs = srcs + [main]

        mapping = self.python_path_mappings.get(python_path)
        self_modules = mapping.compute_self_modules(pkg, srcs)

        target_dir = bazel_utils.normalize_relative_target_to_os_path(pkg[2:])

        all_deps = set()  # type: ignore[var-annotated]
        all_unknown_imports = set()  # type: ignore[var-annotated]
        all_unknown_froms = set()  # type: ignore[var-annotated]

        for src in set(srcs):
            src = os.path.join(target_dir, src)

            module_path = PythonPathMapping.convert_from_file_path_to_module(src)

            filename, parsed = mapping.find_closest_bzl_or_build(module_path)
            if not filename:
                raise bazel_utils.BazelError(
                    "Cannot locate %s:%s's source (or its closest BUILD / "
                    "BUILD.in file): %s/%s" % (pkg, name, target_dir, src)
                )

            pkg_path = os.path.dirname(filename).replace(self.workspace_dir, "/")
            src_pkg = bazel_utils.normalize_os_path_to_target(pkg_path)

            if src_pkg != pkg:
                print(
                    (
                        "WARNING: Skipping %s from %s:%s deps computation "
                        "since it belongs to %s"
                    )
                    % (src, pkg, name, src_pkg)
                )
                continue

            import_set, from_set = parse_imports(
                self.workspace_dir,
                src,
                py3_compatible=is_py3_compatible or src.endswith(".pyi"),
            )

            import_deps, unknown_imports = mapping.find_import_targets(
                src_pkg, self_modules, import_set
            )
            all_deps.update(import_deps)
            all_unknown_imports.update(unknown_imports)

            if validate:
                assert not unknown_imports, (
                    "Unable to locate modules %s (imported by %s) in any "
                    "library target (NOTE: bin and test targets are "
                    "ignored)"
                ) % (unknown_imports, src)

            from_deps, unknown_froms = mapping.find_from_targets(
                src_pkg, self_modules, from_set
            )
            all_deps.update(from_deps)
            all_unknown_froms.update(unknown_froms)

            if validate:
                assert not unknown_froms, (
                    "Unable to locate modules %s (imported by %s) in any "
                    "library target (NOTE: bin and test targets are "
                    "ignored)"
                ) % (unknown_froms, src)

        import_deps, unknown_imports = mapping.find_import_targets(
            pkg, self_modules, []
        )
        all_deps.update(import_deps)
        all_unknown_imports.update(unknown_imports)

        if pip_main:
            all_deps.add(pip_main)

        all_deps.discard("%s:%s" % (pkg, name))
        if name == os.path.basename(target_dir):
            all_deps.discard("%s" % pkg)

        return sort_deps(pkg, all_deps), all_unknown_imports, all_unknown_froms


def sort_deps(curr_pkg_dir, deps):
    targets = []

    for target in deps:
        pkg, _, rule = target.partition(":")
        if pkg == curr_pkg_dir:
            target = ":%s" % (rule or os.path.basename(pkg))
        elif os.path.basename(pkg) == rule:
            target = pkg

        targets.append(target)

    targets.sort(key=lambda x: x.lower().partition(":"))
    return targets
