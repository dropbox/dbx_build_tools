load("//build_tools/py:common.bzl", "DbxPyVersionCompatibility")

_DbxPyProvidesModulesInfo = provider(fields = [
    "provides_prefix_modules",
    "provides_exact_modules",
])

validate_imports_tmpl = '''#!/bin/bash -eu
{import_validation_bin_path} "$@" && echo success > {out}
'''

def _modules_from_srcs(srcs, pythonpath = None):
    external_pypath = False
    pythonpath_len = 0
    if pythonpath:
        # Pythonpath starting with ../ indicicates a external repo, in this case
        # the file sources will look something like "external/<external repo name>"
        if pythonpath.startswith("../"):
            external_pypath = True
            pythonpath = pythonpath[3:]

        # support either e.g. paper/bin/ or paper/bin as pythonpath.
        pythonpath_len = len(pythonpath)
        if not pythonpath.endswith("/"):
            pythonpath_len += 1

        if external_pypath:
            pythonpath_len += len("external/")

    ms = []
    for src in srcs:
        if external_pypath:
            path = src.path
            if not src.path.startswith("external/"):
                fail("If pythonpath is ../ then presumably the paths should be an external workspace")
        else:
            path = src.short_path
        m = path.replace("/", ".")[:-3]
        if m.endswith("__init__"):
            m = m[:-9]
        m = m[pythonpath_len:]
        ms.append(m)
    return ms

def _dbx_py_validate_imports_impl(target, ctx):
    rule = ctx.rule
    if rule.kind not in ["dbx_py_library", "dbx_py_binary", "dbx_py_pypi_piplib_internal", "dbx_py_local_piplib_internal", "py_library", "dbx_py_local_piplib"]:
        return []

    kinds_to_check = ["dbx_py_library", "dbx_py_binary"]

    # Don't check anything with no sources. (This is usually pip tools)
    run_check_action = rule.kind in kinds_to_check and rule.attr.validate in ["strict", "allow-unused"] and len(rule.files.srcs) > 0
    if rule.kind == "dbx_py_binary" and not run_check_action:
        # No need to do anything for binaries if we aren't actually running the action,
        # since we don't generate any providers for them.
        return []

    providers = []
    pythonpath = None
    if rule.kind in ["py_library", "dbx_py_library", "dbx_py_binary"]:
        if rule.kind != "py_library":
            pythonpath = rule.attr.pythonpath

        prefix_modules = []
        if rule.kind == "dbx_py_library":
            prefix_modules = rule.attr.provides

        self_provides = _DbxPyProvidesModulesInfo(
            provides_exact_modules = _modules_from_srcs(rule.files.srcs, pythonpath = pythonpath),
            provides_prefix_modules = prefix_modules,
        )
    elif rule.kind in ["dbx_py_pypi_piplib_internal", "dbx_py_local_piplib_internal"]:
        self_provides = _DbxPyProvidesModulesInfo(
            provides_exact_modules = [],
            provides_prefix_modules = rule.attr.provides,
        )
    else:
        fail("Invalid rule; unable to compute provides modules info")

    if rule.kind != "dbx_py_binary":
        providers.append(self_provides)

    if run_check_action:
        args = ctx.actions.args()
        # TODO: cleanup
        args.add("--py3-compatible")
        if rule.attr.python2_compatible:
            args.add("--py2-compatible")

        if rule.attr.validate == "allow-unused":
            args.add("--allow-unused-targets")

        if pythonpath:
            args.add("--pythonpath={}".format(pythonpath))

        for dep in rule.attr.deps:
            args.add_all(dep[_DbxPyProvidesModulesInfo].provides_prefix_modules, format_each = "--target-provides-prefix={}=%s".format(dep.label))
            args.add_all(dep[_DbxPyProvidesModulesInfo].provides_exact_modules, format_each = "--target-provides={}=%s".format(dep.label))

        args.add_all(self_provides.provides_prefix_modules, format_each = "--target-provides-prefix={}=%s".format(target.label))
        args.add_all(self_provides.provides_exact_modules, format_each = "--target-provides={}=%s".format(target.label))

        args.add_all(rule.files.srcs, before_each = "--src")
        args.add_all(rule.files.stub_srcs, before_each = "--src")
        args.add("--target={}".format(target.label))

        outfile = ctx.actions.declare_file(target.label.name + ".validate_imports.out")
        shell_content = validate_imports_tmpl.format(out = outfile.path, import_validation_bin_path = ctx.executable._test_bin.path)

        ctx.actions.run_shell(
            inputs = rule.files.srcs + rule.files.stub_srcs,
            tools = [ctx.executable._test_bin],
            outputs = [outfile],
            mnemonic = "CheckPyImports",
            command = shell_content,
            arguments = [args],
        )

        providers.append(
            OutputGroupInfo(
                py_import_validation_files = depset([outfile]),
            ),
        )

    return providers

dbx_py_validate_imports = aspect(
    attrs = {
        "_test_bin": attr.label(default = "//build_tools/py/bazel_validation:check_bazel_deps", executable = True, cfg = "host"),
    },
    attr_aspects = ["deps"],
    implementation = _dbx_py_validate_imports_impl,
)
