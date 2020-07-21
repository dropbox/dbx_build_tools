# for defining common interfaces used between starlark files
load("//build_tools/bazel:config.bzl", "DbxStringValue")
load(
    "@dbx_build_tools//build_tools/py:toolchain.bzl",
    "BUILD_TAG_TO_TOOLCHAIN_MAP",
    "DbxPyInterpreter",
    "get_py_toolchain_name",
)
load("//build_tools/bazel:runfiles.bzl", "write_runfiles_tmpl")
load("//build_tools/py:cfg.bzl", "ALL_ABIS")
load("//build_tools/windows:windows.bzl", "is_windows")

DbxPyVersionCompatibility = provider(fields = [
    "python2_compatible",
    "python3_compatible",
])

ALL_TOOLCHAIN_NAMES = [BUILD_TAG_TO_TOOLCHAIN_MAP[abi.build_tag] for abi in ALL_ABIS]

ALLOWED_DRTE_VERSIONS = ["v3"]

# The minimum attributes needed to be able to emit py binaries (see emit_py_binary below).
py_binary_attrs = {
    "_stamp_pypi": attr.bool(default = True),
    "_check_conflicts": attr.label(default = Label("//build_tools/py:check_conflicts"), executable = True, cfg = "host"),
    "_sanitizer_extra_runfiles": attr.label(default = Label("//build_tools/py:sanitizer-extra-runfiles")),
    "_sanitizer": attr.label(
        default = Label("//build_tools:sanitizer"),
        cfg = "host",
    ),
    "_blank_py_binary": attr.label(
        default = Label("//build_tools/py:blank_py_binary"),
        cfg = "host",
    ),
    "_py_link_dynamic_libs": attr.label(default = Label("//build_tools:py_link_dynamic_libs")),
}

py_file_types = [".py"]
pyi_file_types = [".pyi"]

# The main script in dbx_py_binary is wrapped with two layers of scripts. The first
# one is a shell script that computes the location of the runfiles tree and
# execs the appropriate python interpreter with the appropriate dynamic library
# path and PYTHONPATH. Inside, we have a Python wrapper that sets the process
# title and finally executes the user's script.
_asan_environment = """
export ASAN_OPTIONS="detect_leaks=0:suppressions=$RUNFILES/build_tools/py/asan-suppressions.txt:$ASAN_OPTIONS"
"""

_shared_libraries_windows_tmpl = """
set PATH={library_search_path};%PATH%
"""

_shared_libraries_tmpl = """
DBX_LIBRARY_PATH="{library_search_path}"
if [[ "$OSTYPE" == "darwin"* ]]; then
    for path in ${{DBX_LIBRARY_PATH//:/ }}
    do
        export DYLD_LIBRARY_PATH="${{DYLD_LIBRARY_PATH:-}}:$RUNFILES/$path"
    done

    DBX_FRAMEWORK_PATH="{framework_search_path}"
    for path in ${{DBX_FRAMEWORK_PATH//:/ }}
    do
        export DYLD_FRAMEWORK_PATH="${{DYLD_FRAMEWORK_PATH:-}}:$RUNFILES/$path"
    done
else
    for path in ${{DBX_LIBRARY_PATH//:/ }}
    do
        export LD_LIBRARY_PATH="${{LD_LIBRARY_PATH:-}}:$RUNFILES/$path"
    done
fi

"""

_runfile_tmpl = """
{shared_library_path_setup}exec {python_bin} {python_flags} ${{PYTHONARGS:-}} $RUNFILES/{inner_wrapper} $RUNFILES {default_args}
"""

_runfile_windows_tmpl = """
{shared_library_path_setup}
{python_bin} {python_flags} %PYTHONARGS% "%RUNFILES%\\{inner_wrapper}" "%RUNFILES%" {default_args}
"""

_inner_wrapper = """
import sys
runfiles = sys.argv[1]
sys.argv = sys.argv[0:1] + sys.argv[2:]

# Insert user runfiles python paths after the script dir and before the stdlib
# paths. We also remove sys.path[0], which is the directory the executable is
# in. We need to do this before importing os to prevent conflicts with the
# types module. 3rdparty libraries go at the very end.
sys.path[:1] = [
    runfiles + {path_sep} + p
    for p in ({relative_user_python_path},)
]
sys.path.extend([
    runfiles + {path_sep} + p
    for p in ({relative_piplib_python_path})
])
{dbx_importer}
import os
try:
    fd = os.open('/proc/self/comm', os.O_WRONLY)
    try:
         os.write(fd, {proc_title})
    finally:
         os.close(fd)
except Exception:
    # too bad
    pass

# Run the script as __main__.
script_dir = os.path.join(runfiles, {main_package})
filepath = os.path.join(script_dir, {main})
sys.argv[0] = filepath

import types
module = types.ModuleType('__main__')
module.__dict__['__file__'] = filepath
sys.modules['__main__'] = module

with open(filepath, 'rb') as f:
    code = compile(f.read(), filepath, "exec")
exec(code, module.__dict__)
"""

_setup_dbx_importer = """
sys.path.insert(0, runfiles + '/../{workspace}')
from build_tools.py import dbx_importer
del sys.path[0]
dbx_importer.install()
"""

def allow_dynamic_links(ctx):
    return ctx.attr._py_link_dynamic_libs[DbxStringValue].value == "allowed"

def workspace_root_to_pythonpath(workspace_root):
    if workspace_root.startswith("external/"):
        return "../" + workspace_root.partition("/")[2]
    else:
        return workspace_root

def _binary_wrapper_template(ctx, internal_bootstrap):
    if is_windows(ctx):
        return _runfile_windows_tmpl

    if internal_bootstrap:
        sanitize = None
    else:
        sanitize = ctx.attr._sanitizer[DbxStringValue].value
    if sanitize == "define-asan":
        return _asan_environment + _runfile_tmpl
    return _runfile_tmpl

def collect_transitive_srcs_and_libs(
        ctx,
        deps,
        data,
        python2_compatible,
        python3_compatible,
        pip_version,
        is_local_piplib):
    pyc_files_by_build_tag_trans = {}
    for abi in ALL_ABIS:
        pyc_files_by_build_tag_trans[abi.build_tag] = []

    piplib_contents_trans = {}
    for abi in ALL_ABIS:
        piplib_contents_trans[abi.build_tag] = []
    extra_pythonpath_trans = []
    versioned_deps_direct = []
    versioned_deps_trans = []
    dynamic_libraries_trans = []
    frameworks_trans = []

    if not python2_compatible and not python3_compatible:
        fail("Neither compatible with Python 2 or Python 3.")

    if pip_version:
        if not is_local_piplib:
            type = "pypi"
        else:
            type = "thirdparty"
        versioned_deps_direct.append(struct(type = type, name = ctx.label.name, version = pip_version).to_json())

    if data:
        for x in data:
            if hasattr(x, "piplib_contents"):
                fail("pip dependencies should not be passed in via `data`, use `deps` instead => (%s, %s)" % (ctx.label, x.label))
            if hasattr(x, "versioned_deps"):
                versioned_deps_trans.append(x.versioned_deps)

    for x in deps:
        paths = getattr(x, "extra_pythonpath", None)
        if paths:
            extra_pythonpath_trans.append(paths)

        if DbxPyVersionCompatibility in x:
            versions = x[DbxPyVersionCompatibility]
            if python2_compatible and not versions.python2_compatible:
                fail("%s is not compatible with Python 2." % (x.label,))
            if python3_compatible and not versions.python3_compatible:
                fail("%s is not compatible with Python 3." % (x.label,))

        if hasattr(x, "versioned_deps"):
            versioned_deps_trans.append(x.versioned_deps)

        if hasattr(x, "piplib_contents"):
            # Likely to be a dbx_py_library
            for build_tag in x.piplib_contents:
                piplib_contents_trans[build_tag].append(x.piplib_contents[build_tag])

            files_by_build_tag = getattr(x, "pyc_files_by_build_tag", None)
            if files_by_build_tag:
                for abi in ALL_ABIS:
                    pyc_files_by_build_tag_trans[abi.build_tag].append(files_by_build_tag[abi.build_tag])

            dynamic_libraries_trans.append(x.dynamic_libraries)
            frameworks_trans.append(x.frameworks)

    pyc_files_by_build_tag = {
        abi.build_tag: depset(transitive = pyc_files_by_build_tag_trans[abi.build_tag])
        for abi in ALL_ABIS
    }

    versioned_deps = depset(
        direct = versioned_deps_direct,
        transitive = versioned_deps_trans,
    )
    extra_pythonpath = depset(transitive = extra_pythonpath_trans)

    piplib_contents = {
        abi.build_tag: depset(transitive = piplib_contents_trans[abi.build_tag])
        for abi in ALL_ABIS
    }

    dylibs = depset(transitive = dynamic_libraries_trans)
    frameworks = depset(transitive = frameworks_trans)

    return pyc_files_by_build_tag, piplib_contents, extra_pythonpath, versioned_deps, dylibs, frameworks

def _produce_versioned_deps_output(ctx, base_out_file, versioned_deps):
    content = ctx.actions.args()
    content.set_param_file_format("multiline")
    content.add_joined(versioned_deps, join_with = ",", format_joined = "[%s]")

    stamp_file = ctx.actions.declare_file(base_out_file.basename + ".dep_versions", sibling = base_out_file)
    ctx.actions.write(
        output = stamp_file,
        content = content,
        is_executable = False,
    )
    return stamp_file

_PIPLIB_SEPARATOR = "=" * 10

def _piplib_conflict_check(piplib, expander):
    cut_len = len(piplib.extracted_dir.path) + 1
    res = [_PIPLIB_SEPARATOR + str(piplib.label) + _PIPLIB_SEPARATOR]
    for f in expander.expand(piplib.extracted_dir):
        relative_path = f.path[cut_len:]
        if f.path.endswith("/__init__.py") and relative_path[:-12].replace("/", ".") in piplib.namespace_pkgs:
            continue
        res.append(relative_path)
    return res

def collect_required_piplibs(deps):
    required_piplibs_trans = []
    for dep in deps:
        required_piplibs = getattr(dep, "required_piplibs", None)
        if required_piplibs != None:
            required_piplibs_trans.append(required_piplibs)
    return depset(transitive = required_piplibs_trans)

def _pyc_path(src, build_tag):
    return "__pycache__/" + src.basename[:-2] + build_tag + ".pyc"

def _short_path(src):
    return src.short_path

def compile_pycs(ctx, srcs, python):
    # For CPython 2, we build custom pydbxc files that us the md5 of the source instead of the mtime
    # for the py file for invalidation. This allows the files to be remotely cached. We need to
    # disable hash randomization to the generated files have deterministic ordering of sets and dict
    # in the code objects.
    if len(srcs) == 0:
        return []

    toolchain = ctx.toolchains[get_py_toolchain_name(python.build_tag)]
    python = toolchain.interpreter[DbxPyInterpreter]

    if not toolchain.pyc_compilation_enabled:
        return []

    if python.major_python_version == 2:
        new_pyc_files = [ctx.actions.declare_file(src.basename + "dbxc", sibling = src) for src in srcs]
    else:
        new_pyc_files = [ctx.actions.declare_file(_pyc_path(src, python.build_tag), sibling = src) for src in srcs]

    lib_args = ctx.actions.args()
    lib_args.add("--noallow-failures")
    lib_args.add_all(srcs)
    lib_args.add_all(srcs, map_each = _short_path)
    lib_args.add_all(new_pyc_files)

    ctx.actions.run(
        outputs = new_pyc_files,
        inputs = depset(direct = srcs, transitive = [python.runtime]),
        executable = toolchain.pyc_compile_files_to_run,
        arguments = [lib_args],
        mnemonic = "PyCompile",
        env = {
            "PYTHONHASHSEED": "4",
            "DBX_PYTHON": python.path,
        },
    )

    return new_pyc_files

def emit_py_binary(
        ctx,
        main,
        srcs,
        out_file,
        pythonpath,
        deps,
        data,
        ext_modules,
        python,
        internal_bootstrap,
        python2_compatible,
        python3_compatible):
    if internal_bootstrap:
        if python:
            fail("`python` arg must be None when internal_bootstrap is True")
    elif not python:
        fail("`python` arg must be truthy when internal_bootstrap is False")
    if internal_bootstrap:
        py_toolchain = None
    else:
        py_toolchain = ctx.toolchains[get_py_toolchain_name(python.build_tag)]

    if python:
        # Only check python compatibility for non-bootstrap py
        # binaries, since we don't have access to the python toolchain
        # for bootstrap binaries.
        #
        # TODO: Check compatibility when a non-bootstrap py binary
        # actually uses a bootstrapped binary.
        if python.major_python_version == 2:
            if not python2_compatible:
                fail("Python 2 interpreter selected but binary is not compatible with Python 2.")
        elif python.major_python_version == 3:
            if not python3_compatible:
                fail("Python 3 interpreter selected but binary is not compatible with Python 3.")

    if not pythonpath:
        pythonpath = workspace_root_to_pythonpath(ctx.label.workspace_root)

    runfiles_direct = [main] + srcs
    runfiles_trans = []
    piplib_paths = []
    library_search_entries = {}
    framework_search_entries = {}

    # hidden_output contains files that should be output by the rule,
    # but done so in a way that other rules can't depend on those
    # files.
    hidden_output = []

    if internal_bootstrap:
        extra_pythonpath = depset(direct = [pythonpath])
        dbx_importer = ""
    else:
        # Only collect dependencies from dbx_py_library and
        # dbx_py_pypi* rules for non-bootstrap binaries. Those
        # dependencies can't be added to bootstrap rules.
        build_tag = python.build_tag
        (
            pyc_files_by_build_tag,
            piplib_contents,
            extra_pythonpath,
            versioned_deps,
            dynamic_libraries,
            frameworks_trans,
        ) = collect_transitive_srcs_and_libs(
            ctx,
            deps = deps,
            data = data,
            pip_version = None,
            python2_compatible = python2_compatible,
            python3_compatible = python3_compatible,
            is_local_piplib = False,
        )
        if py_toolchain.dbx_importer:
            # The importer is only used on py2 non-bootstrap builds
            # (bootstrap builds don't read dropbox's pyc).
            extra_pythonpath = depset(transitive = [extra_pythonpath], direct = [pythonpath, workspace_root_to_pythonpath(py_toolchain.dbx_importer.label.workspace_root)])
            dbx_importer = _setup_dbx_importer.format(
                workspace = py_toolchain.dbx_importer.label.workspace_name,
            )
        else:
            extra_pythonpath = depset(transitive = [extra_pythonpath], direct = [pythonpath])
            dbx_importer = ""

        piplib_contents_set = piplib_contents[build_tag]
        all_piplib_contents = piplib_contents_set.to_list()
        runfiles_trans.append(pyc_files_by_build_tag[build_tag])

        if not internal_bootstrap and allow_dynamic_links(ctx):
            runfiles_trans.append(dynamic_libraries)
            for f in dynamic_libraries.to_list():
                library_search_entries[f.short_path.rpartition("/")[0]] = True
            for f in frameworks_trans.to_list():
                runfiles_trans.append(f.framework_files)
                for dir in f.framework_dirs.to_list():
                    # framework_dirs are full paths to the .framework including
                    # the execution root.  The search path needs the dirname of
                    # the .framework dir, and relative to the execution root as
                    # it will be prefixed with the runfiles path.
                    # +1 to remove the leading '/'.
                    dir_basename_short_path = dir.rpartition("/")[0][len(ctx.bin_dir.path) + 1:]
                    framework_search_entries[dir_basename_short_path] = True

        # Scan through transitive piplibs. Collect namespace packages and check for conflicts.
        installed = {}
        namespace_pkgs = {}
        if internal_bootstrap and all_piplib_contents:
            fail("python internal bootstrap binaries can't contain pip dependencies")

        for piplib in all_piplib_contents:
            runfiles_direct.append(piplib.extracted_dir)
            extracted_dir = piplib.extracted_dir.short_path
            if is_windows(ctx):
                extracted_dir = extracted_dir.replace("/", "\\")
            label = piplib.label
            piplib_paths.append(repr(extracted_dir) + ", ")
            installed[label.name] = None

            for ns in piplib.namespace_pkgs:
                namespace_pkgs.setdefault(ns, []).append(extracted_dir)

        if not internal_bootstrap:
            # Only non-internal bootstrap binaries can depend on pip
            # attributes, so we only need to check for conflicts for them.
            conflict_out = ctx.actions.declare_file(out_file.basename + "_conflicts", sibling = out_file)
            conflict_args = ctx.actions.args()
            conflict_args.set_param_file_format("multiline")
            conflict_args.use_param_file("@%s", use_always = True)
            conflict_args.add("--output-file", conflict_out)
            conflict_args.add_all(namespace_pkgs.keys(), before_each = "--namespace_pkg")
            conflict_args.add_all(piplib_contents_set, map_each = _piplib_conflict_check)

            ctx.actions.run(
                inputs = [p.extracted_dir for p in all_piplib_contents],
                tools = [],
                outputs = [conflict_out],
                mnemonic = "PiplibCheckConflict",
                executable = ctx.executable._check_conflicts,
                arguments = [conflict_args],
                use_default_shell_env = True,
            )

            hidden_output.append(conflict_out)

        required_piplibs = sorted(collect_required_piplibs(deps).to_list())
        if sorted(installed) != required_piplibs:
            for i in installed:
                required_piplibs.remove(i)
            fail("required piplibs not found for build_tag: {}. {}".format(
                build_tag,
                required_piplibs,
            ))

        # For each transitive namespace package, make wrapper packages that will set up the right
        # package __path__.
        if namespace_pkgs:
            dispatch_dirname = out_file.basename + "-namespace-dispatch"
            ws = ctx.label.workspace_root + "/" if ctx.label.workspace_root else ""
            piplib_paths.insert(0, repr(ws + out_file.short_path + "-namespace-dispatch") + ", ")
            namespace_inits = []
            for namespace_pkg, impl_dirs in namespace_pkgs.items():
                namespace_dir = namespace_pkg.replace(".", "/")
                impl_dirs = [repr(impl_dir + "/" + namespace_dir) for impl_dir in impl_dirs]
                namespace_init = ctx.actions.declare_file(
                    dispatch_dirname + "/" + namespace_dir + "/__init__.py",
                    sibling = out_file,
                )
                namespace_inits.append(namespace_init)
                ctx.actions.write(namespace_init, """
import os
__path__.extend([os.path.join(os.environ['RUNFILES'], d) for d in (%s,)])
""" % ", ".join(impl_dirs))
            runfiles_direct.extend(namespace_inits)
            runfiles_direct.extend(compile_pycs(ctx, namespace_inits, python))

        runfiles_trans.append(python.runtime)
        runfiles_trans.append(ctx.attr._sanitizer_extra_runfiles.files)

        if ext_modules:
            runfiles_trans.append(ext_modules)

        if ctx.attr._stamp_pypi:
            runfiles_direct.append(_produce_versioned_deps_output(ctx, out_file, versioned_deps))

    python_paths = [repr(p) for p in extra_pythonpath.to_list()]
    user_python_path = ", ".join(python_paths)
    piplib_python_path = "".join(piplib_paths)

    extra_args = []
    if hasattr(ctx.attr, "extra_args"):
        extra_args = ctx.attr.extra_args

    if is_windows(ctx):
        default_args = " ".join(extra_args + ["%*"])
    else:
        default_args = " ".join(extra_args + ['"$@"'])

    inner_wrapper = ctx.actions.declare_file(out_file.basename + "-wrapper.py", sibling = out_file)
    runfiles_direct.append(inner_wrapper)

    ctx.actions.write(
        inner_wrapper,
        _inner_wrapper.format(
            main = repr(main.basename),
            main_package = repr(main.short_path.rpartition("/")[0]),
            # 15 is the maximum length of a process title.
            proc_title = repr(ctx.label.name[:15]),
            relative_user_python_path = user_python_path,
            relative_piplib_python_path = piplib_python_path,
            dbx_importer = dbx_importer,
            path_sep = repr("\\" if is_windows(ctx) else "/"),
        ),
    )

    if internal_bootstrap:
        # Don't ignore environment variables in bootstrap so we can set PYTHONHASHSEED to 1.
        python_flags = "-Ss"

        # The python binary is an env var for internal bootstrap
        # binaries because they can't depend on the python toolchain.
        # Rules that use bootstrap binaries need to set DBX_PYTHON to
        # run bootstrap binaries.
        if is_windows(ctx):
            python_bin = "%DBX_PYTHON%"
        else:
            python_bin = "$DBX_PYTHON"
    else:
        python_flags = "-ESs"
        python_bin = python.runfiles_path

    # Handle dynamic libraries.
    shared_library_path_setup = ""
    if library_search_entries or framework_search_entries:
        if is_windows(ctx):
            entries = [
                "%RUNFILES%\\{}".format(e.replace("/", "\\"))
                for e in library_search_entries.keys()
            ]
            shared_library_path_setup = _shared_libraries_windows_tmpl.format(
                library_search_path = ";".join(entries),
            )
        else:
            shared_library_path_setup = _shared_libraries_tmpl.format(
                library_search_path = ":".join(library_search_entries.keys()),
                framework_search_path = ":".join(framework_search_entries.keys()),
            )

    if is_windows(ctx):
        wrapper_path = inner_wrapper.short_path.replace("/", "\\")
        python_bin_path = python_bin.replace("/", "\\")
    else:
        wrapper_path = inner_wrapper.short_path
        python_bin_path = python_bin

    # Copy-through the runfiles so we get all transitive dependencies.
    runfiles = ctx.runfiles(
        transitive_files = depset(direct = runfiles_direct, transitive = runfiles_trans),
        # do NOT collect_default, it is up to the caller to create another runfiles with collect_default=True
        # and merge, as the py binary may not be the main binary of this ctx and thus does not need the runfiles
        # of every dependency of ctx
    )

    # manually merge runfiles of dependencies, as earlier we did not create runfiles
    # with collect_default=True
    for dep in deps:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)

    for d in data:
        runfiles = runfiles.merge(d[DefaultInfo].default_runfiles)

    if py_toolchain and py_toolchain.dbx_importer:
        # Manually add dbx_import.py. This also implicitly picks up Bazel's magically automatic
        # __init__.py insertion behavior, which is why we add it unconditionally.
        runfiles = runfiles.merge(py_toolchain.dbx_importer[DefaultInfo].default_runfiles)
    else:
        # Add blank_py_binary to trigger Bazel's automatic __init__.py insertion behavior.
        runfiles = runfiles.merge(ctx.attr._blank_py_binary[DefaultInfo].default_runfiles)

    write_runfiles_tmpl(
        ctx,
        out_file,
        _binary_wrapper_template(ctx, internal_bootstrap).format(
            python_flags = python_flags,
            python_bin = python_bin,
            inner_wrapper = inner_wrapper.short_path,
            default_args = default_args,
            shared_library_path_setup = shared_library_path_setup,
        ),
    )

    return runfiles, extra_pythonpath, depset(direct = hidden_output)
