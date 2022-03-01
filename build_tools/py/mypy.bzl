"""Aspect for running mypy.

This defines a new rule for defining test targets, dbx_mypy_test.
Usage example:

    dbx_mypy_test(
        name = 'foo_mypy',
        deps = ['foo'],
    )

Running the test completes immediately; but building it runs mypy over
all its (transitive) dependencies (which must be dbx_py_library,
dbx_py_binary or dbx_py_test targets).  If mypy complains about any
file in any dependency the test can't be built.

Most of the work is done through aspects; docs are at:
https://docs.bazel.build/versions/master/skylark/aspects.html
"""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load("//build_tools/bazel:runfiles.bzl", "runfiles_attrs", "write_runfiles_tmpl")
load(
    "//build_tools/py:py.bzl",
    "dbx_py_binary_attrs",
    "dbx_py_binary_base_impl",
    "dbx_py_pytest_test",
    "dbx_py_test_attrs",
    "extract_pytest_args",
)
load("//build_tools/py:common.bzl", "DbxPyVersionCompatibility")
load("//build_tools/bazel:quarantine.bzl", "process_quarantine_attr")
load("//build_tools/services:svc.bzl", "dbx_services_test")
load("@dbx_build_tools//build_tools/py:toolchain.bzl", "BUILD_TAG_TO_TOOLCHAIN_MAP")
load("@dbx_build_tools//build_tools/py:cfg.bzl", "ALL_ABIS")

ALL_PY3_TOOLCHAIN_NAMES = [BUILD_TAG_TO_TOOLCHAIN_MAP[abi.build_tag] for abi in ALL_ABIS if abi.major_python_version == 3]

_mypy_provider_fields = [
    "trans_srcs",
    "trans_roots",
    "trans_outs",
    "trans_cache_map",
    "trans_junits",
    # mypyc stuff
    "trans_group",
    "trans_ext_modules",
    "compilation_context",
]

MypyProvider = provider(fields = _mypy_provider_fields)
MypycProvider = provider(fields = _mypy_provider_fields)

def _null_result(mypy_provider):
    return mypy_provider(
        trans_outs = depset(),
        trans_srcs = depset(),
        trans_roots = depset(),
        trans_cache_map = depset(),
        trans_junits = depset(),
        trans_group = depset(),
        trans_ext_modules = depset(),
        compilation_context = None,
    )

def _get_stub_roots(stub_srcs):
    """
    Helper to add extra roots for stub files in typeshed.

    Paths are of the form:
      <prefix>/<path>
      <prefix>/.../stdlib/<path>
      <prefix>/... /@python2/<path>
    where:
      <prefix> is mypy-stubs or thirdparty/typeshed
      <path> is the actual filename we care about, e.g. sys.pyi
    """
    roots = []
    for src in stub_srcs:
        parts = src.path.split("/")
        prefix = []
        for part in parts:
            prefix.append(part)
            if part == "@python2" or part == "stdlib":
                roots.append("/".join(prefix))
    return roots

def _get_trans_roots(target, srcs, stub_srcs, deps, mypy_provider, ctx):
    direct = [src.root.path for src in srcs]
    if not target:
        direct += _get_stub_roots(stub_srcs)
        if str(ctx.label).startswith("//mypy-stubs:mypy-stubs"):
            direct += ["mypy-stubs"]
    transitive = [
        dep[mypy_provider].trans_roots
        for dep in deps
    ]
    if target:
        transitive.append(target.extra_pythonpath)
    return depset(direct = direct, transitive = transitive)

def _get_trans_field(outs, deps, field, mypy_provider):
    return depset(
        direct = outs,
        transitive = [getattr(dep[mypy_provider], "trans_" + field) for dep in deps],
    )

def _format_group(group):
    srcs, name = group
    return "%s:%s" % (name, ",".join([src.path for src in srcs]))

# Rules into which we descend.  Other rules are ignored.  Edit to taste.
_supported_rules = [
    "_dbx_mypy_bootstrap",
    "dbx_py_library",
    "dbx_py_binary",
    "dbx_py_compiled_binary",
    "dbx_py_test",
    "services_internal_test",
]

def _dbx_mypy_common_code(target, ctx, deps, srcs, stub_srcs, python_version, use_mypyc, compile_target = False):
    """
    Code shared between aspect and bootstrap rule.

    target: rule name for aspect, None for bootstrap
    ctx: original context
    deps, srcs, stub_srcs: rule attributes
    python_version: '2.7' or '3.8'
    """
    mypy_provider = MypycProvider if use_mypyc else MypyProvider

    if python_version == "2.7" or not use_mypyc:
        compile_target = False

    pyver_dash = python_version.replace(".", "-")
    pyver_under = python_version.replace(".", "_")

    # Except for the bootstrap rule, add typeshed and mypy-stubs to the dependencies.
    is_typeshed = False
    if target:
        typeshed = getattr(ctx.attr, "_typeshed_" + pyver_under)
        mypy_stubs = getattr(ctx.attr, "_mypy_stubs_" + pyver_under)
        deps = deps + [typeshed, mypy_stubs]
    elif str(ctx.label).startswith("//mypy-stubs:mypy-stubs"):
        # Two-stage bootstrap, mypy-stubs depend on typeshed, but not vice versa.
        deps = deps + [getattr(ctx.attr, "_typeshed_" + pyver_under)]
    else:
        is_typeshed = True

    trans_roots = _get_trans_roots(target, srcs, stub_srcs, deps, mypy_provider, ctx)

    trans_caches = _get_trans_field([], deps, "outs", mypy_provider)

    # Merge srcs and stub_srcs -- when foo.py and foo.pyi are both present,
    # only keep the latter.
    stub_paths = {stub.path: None for stub in stub_srcs}  # Used as a set
    srcs = [src for src in srcs if src.path + "i" not in stub_paths] + stub_srcs

    # Get transitive dependencies
    trans_srcs = _get_trans_field(srcs, deps, "srcs", mypy_provider)
    if not trans_srcs:
        return [_null_result(mypy_provider)]

    outs = []
    cache_map = []  # Items for cache_map file.

    ext_modules = []
    compilation_contexts = [
        dep[mypy_provider].compilation_context
        for dep in deps
        if dep[mypy_provider].compilation_context
    ]
    if compile_target:
        # If we are using mypyc, mypy will generate C source as part of its output.
        # Create a C extension module using that source.
        shim_template = ctx.attr._module_shim_template[DefaultInfo].files.to_list()[0]
        group_name = str(target.label).lstrip("/").replace("/", ".").replace(":", ".")
        group_libname = group_name + "__mypyc"
        short_name = group_name.split(".")[-1]

        group_files = [
            ctx.actions.declare_file(template % short_name)
            for template in ["__native_internal_%s.h", "__native_%s.h", "__native_%s.c"]
        ]
        outs.extend(group_files)

        internal_header, external_header, group_src = group_files
        ext_module, compilation_context = _build_mypyc_ext_module(
            ctx,
            short_name + "__mypyc",
            group_src,
            [external_header],
            [internal_header],
            compilation_contexts,
        )
        ext_modules.append(ext_module)

        group = (tuple(srcs), group_name)
    else:
        # If we aren't using mypyc, we still need to create a
        # compilation context that merges our deps' contexts.
        compilation_context = _merge_compilation_contexts(compilation_contexts)
        group = None

    if use_mypyc and not compile_target and not is_typeshed:
        # If we are in mypyc mode but aren't compiling this (and it isn't typeshed),
        # just skip everything and return only the transitive dependencies.
        return [
            mypy_provider(
                trans_srcs = _get_trans_field([], deps, "srcs", mypy_provider),
                trans_roots = trans_roots,
                trans_outs = _get_trans_field([], deps, "outs", mypy_provider),
                trans_cache_map = _get_trans_field([], deps, "cache_map", mypy_provider),
                trans_junits = _get_trans_field([], deps, "junits", mypy_provider),
                trans_group = _get_trans_field([], deps, "group", mypy_provider),
                trans_ext_modules = _get_trans_field([], deps, "ext_modules", mypy_provider),
                compilation_context = compilation_context,
            ),
        ]

    mypyc_part = "-mypyc" if use_mypyc else ""
    junit_xml = "%s-%s%s-junit.xml" % (ctx.label.name.replace("/", "-"), pyver_dash, mypyc_part)
    junit_xml_file = ctx.actions.declare_file(junit_xml)

    for src in srcs:
        # Every test ends up with this file, so multiple tests in
        # a directory will create conflicting json files
        if src.path.endswith("pip/pytest/main.py"):
            continue
        cache_map.append(src)
        path = src.path
        path_base = path[:path.rindex(".")]  # Strip .py or .pyi suffix
        kinds = ["meta", "data"] + (["ir"] if compile_target else [])
        for kind in kinds:
            mypyc_part = ".mypyc" if use_mypyc else ""
            path = "%s.%s%s.%s.json" % (path_base, python_version, mypyc_part, kind)
            file = ctx.actions.declare_file(path)

            outs.append(file)
            if kind != "ir":
                cache_map.append(file)

        # If we are using mypyc, generate a shim extension module for each module
        if compile_target:
            full_modname = path_base.replace("/", ".")
            modname = full_modname.split(".")[-1]
            file = ctx.actions.declare_file(modname + ".c")

            ctx.actions.expand_template(
                template = shim_template,
                output = file,
                substitutions = {
                    "{modname}": modname,
                    "{libname}": group_libname,
                    "{full_modname}": _mypyc_exported_name(full_modname),
                },
            )

            ext_modules.append(_build_mypyc_ext_module(ctx, modname, file)[0])

    trans_outs = _get_trans_field(outs, deps, "outs", mypy_provider)
    trans_cache_map = _get_trans_field(cache_map, deps, "cache_map", mypy_provider)
    trans_group = _get_trans_field([group] if group else [], deps, "group", mypy_provider)

    inputs = depset(transitive = [
        trans_srcs,
        trans_caches,
        ctx.attr._edgestore_plugin.files,
        ctx.attr._sqlalchemy_plugin.files,
        ctx.attr._py3safe_plugin.files,
        ctx.attr._mypy_ini.files,
        ctx.attr._versions.files,
    ])
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")

    if compile_target:
        args.add("--mypyc")
        args.add_joined(trans_group, join_with = ";", map_each = _format_group)
        args.add(junit_xml_file.root.path)

    if use_mypyc:
        # In mypyc mode we skip everything that we don't depend on!!
        args.add("--follow-imports=skip")
        args.add("--ignore-missing-imports")

    args.add("--bazel")
    if python_version != "2.7":
        # For some reason, explicitly passing --python-version 2.7 fails.
        args.add("--python-version", python_version)
    args.add_all(trans_roots, before_each = "--package-root")
    args.add("--no-error-summary")
    args.add("--incremental")
    args.add("--junit-xml", junit_xml_file)
    args.add("--custom-typeshed-dir", "thirdparty/typeshed")
    args.add("--cache-map")
    args.add_all(trans_cache_map)
    args.add("--")
    args.add_all(trans_srcs)
    ctx.actions.run(
        executable = ctx.executable._mypy,
        arguments = [args],
        inputs = inputs,
        outputs = outs + [junit_xml_file],
        mnemonic = "mypyc" if use_mypyc else "mypy",
        tools = [],
    )

    return [
        mypy_provider(
            trans_srcs = trans_srcs,
            trans_roots = trans_roots,
            trans_outs = trans_outs,
            trans_cache_map = trans_cache_map,
            trans_junits = _get_trans_field([junit_xml_file], deps, "junits", mypy_provider),
            trans_group = trans_group,
            trans_ext_modules = _get_trans_field(ext_modules, deps, "ext_modules", mypy_provider),
            compilation_context = compilation_context,
        ),
    ]

def _mypyc_exported_name(fullname):
    return fullname.replace("___", "___3_").replace(".", "___")

def _build_mypyc_ext_module(
        ctx,
        group_name,
        c_source,
        public_hdrs = [],
        private_hdrs = [],
        compilation_contexts = []):
    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features + ["thin_lto"],
    )

    # TODO: broken assumption of single abi
    so_name = "%s.cpython-38-x86_64-linux-gnu.so" % group_name
    so_file = ctx.actions.declare_file(so_name)

    mypyc_runtime = ctx.attr._mypyc_runtime

    compilation_context, compilation_outputs = cc_common.compile(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        srcs = [c_source],
        includes = [c_source.root.path],
        public_hdrs = public_hdrs,
        private_hdrs = private_hdrs,
        name = group_name,
        user_compile_flags = [
            "-Wno-unused-function",
            "-Wno-unused-label",
            "-Wno-unreachable-code",
            "-Wno-unused-variable",
            "-Wno-unused-but-set-variable",
        ],
        compilation_contexts = [mypyc_runtime[CcInfo].compilation_context] + compilation_contexts,
    )
    linking_outputs = cc_common.link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        compilation_outputs = compilation_outputs,
        output_type = "dynamic_library",
        name = so_name,
        linking_contexts = [mypyc_runtime[CcInfo].linking_context],
    )

    # Copy the file into place, since link generates it with "lib" in front
    args = ctx.actions.args()
    args.add(linking_outputs.library_to_link.dynamic_library)
    args.add(so_file)
    ctx.actions.run(
        executable = "cp",
        arguments = [args],
        inputs = [linking_outputs.library_to_link.dynamic_library],
        outputs = [so_file],
        tools = [],
    )

    return so_file, compilation_context

def _merge_compilation_contexts(ctxs):
    return cc_common.merge_cc_infos(
        cc_infos = [CcInfo(compilation_context = ctx) for ctx in ctxs],
    ).compilation_context

# Attributes shared between aspect and bootstrap.

_dbx_mypy_common_attrs = {
    "_mypy": attr.label(
        default = Label("//dropbox/mypy:mypy"),
        allow_files = True,
        executable = True,
        cfg = "host",
    ),
    "_mypy_ini": attr.label(
        default = Label("//:mypy.ini"),
        allow_files = True,
    ),
    "_versions": attr.label(
        default = Label("//thirdparty/typeshed:stdlib/VERSIONS"),
        allow_files = True,
    ),
    # TODO: Move list of plugins to a separate target
    "_edgestore_plugin": attr.label(
        default = Label("//dropbox/mypy:edgestore_plugin.py"),
        allow_files = True,
    ),
    "_sqlalchemy_plugin": attr.label(
        default = Label("//dropbox/mypy:sqlmypy.py"),
        allow_files = True,
    ),
    "_py3safe_plugin": attr.label(
        default = Label("//dropbox/mypy:py3safe.py"),
        allow_files = True,
    ),
}

# Aspect definition.

def _dbx_mypy_aspect_impl(target, ctx):
    rule = ctx.rule

    mypy_provider = MypycProvider if ctx.attr._use_mypyc else MypyProvider

    if rule.kind not in _supported_rules:
        return [_null_result(mypy_provider)]
    if not hasattr(rule.attr, "deps") and hasattr(rule.attr, "bin"):
        if rule.kind != "services_internal_test":
            fail("Expected rule kind services_internal_test, got %s" % rule.kind)

        # Special case for tests that specify services=...
        # This happens when user specifies a services_internal_test inside a dbx_mypy_test,
        # e.g.
        #
        # dbx_py_pytest_test(
        #     name = "foo_test",
        #     services = [...],
        # )
        #
        # dbx_mypy_test(
        #     name = "foo_test_mypy_test",
        #     # The actual python binary is :foo_test_bin, but this is invisible to users
        #     deps = [":foo_test"],
        # )
        return _dbx_mypy_common_code(
            None,
            ctx,
            [rule.attr.bin],
            [],
            [],
            ctx.attr.python_version,
            use_mypyc = False,
        )
    return _dbx_mypy_common_code(
        target,
        ctx,
        rule.attr.deps,
        rule.files.srcs,
        rule.files.stub_srcs,
        ctx.attr.python_version,
        use_mypyc = ctx.attr._use_mypyc,
        compile_target = getattr(rule.attr, "compiled", False),
    )

_dbx_mypy_typeshed_attrs = {
    "_typeshed_2_7": attr.label(default = Label("//thirdparty/typeshed:typeshed-2.7")),
    "_typeshed_3_8": attr.label(default = Label("//thirdparty/typeshed:typeshed-3.8")),
}

_dbx_mypy_aspect_attrs = {
    "python_version": attr.string(values = ["2.7", "3.8"]),
    "_use_mypyc": attr.bool(default = False),
    "_mypy_stubs_2_7": attr.label(default = Label("//mypy-stubs:mypy-stubs-2.7")),
    "_mypy_stubs_3_8": attr.label(default = Label("//mypy-stubs:mypy-stubs-3.8")),
    "_cc_toolchain": attr.label(default = Label("@bazel_tools//tools/cpp:current_cc_toolchain")),
    "_mypyc_runtime": attr.label(default = Label("//thirdparty/mypy:mypyc_runtime")),
    "_module_shim_template": attr.label(default = Label("//thirdparty/mypy:module_shim_template")),
}
_dbx_mypy_aspect_attrs.update(_dbx_mypy_common_attrs)
_dbx_mypy_aspect_attrs.update(_dbx_mypy_typeshed_attrs)

dbx_mypy_aspect = aspect(
    implementation = _dbx_mypy_aspect_impl,
    attr_aspects = ["deps", "bin"],
    attrs = _dbx_mypy_aspect_attrs,
    fragments = ["cpp"],
    provides = [MypyProvider],
)

_dbx_mypyc_aspect_attrs = dict(_dbx_mypy_aspect_attrs)
_dbx_mypyc_aspect_attrs["_use_mypyc"] = attr.bool(default = True)

dbx_mypyc_aspect = aspect(
    implementation = _dbx_mypy_aspect_impl,
    attr_aspects = ["deps", "bin"],
    attrs = _dbx_mypyc_aspect_attrs,
    fragments = ["cpp"],
    provides = [MypycProvider],
)

# Test rule used to trigger mypy via a test target.
# It is actually a macro so we can expand it to one or two
# rule invocations depending on Python version compatibility;
# we also set size = 'small'.

_dbx_mypy_test_attrs = {
    "deps": attr.label_list(aspects = [dbx_mypy_aspect]),
    "python_version": attr.string(),
    "_mypy_test": attr.label(
        default = Label("//dropbox/mypy:mypy_test"),
        allow_files = True,
        executable = True,
        cfg = "host",
    ),
}
_dbx_mypy_test_attrs.update(runfiles_attrs)

_test_template = """
$RUNFILES/{program} --label {label} {files} >$XML_OUTPUT_FILE
"""

def _dbx_mypy_test_impl(ctx):
    out = ctx.outputs.out
    mypy_test = ctx.executable._mypy_test
    junits = depset(transitive = [dep[MypyProvider].trans_junits for dep in ctx.attr.deps])
    template = _test_template.format(
        program = mypy_test.short_path,
        label = ctx.label,
        files = " ".join([j.short_path for j in junits.to_list()]),
    )
    write_runfiles_tmpl(ctx, out, template)

    runfiles = ctx.runfiles(transitive_files = junits)
    runfiles = runfiles.merge(ctx.attr._mypy_test.default_runfiles)
    return [DefaultInfo(executable = out, runfiles = runfiles)]

_dbx_mypy_test = rule(
    implementation = _dbx_mypy_test_impl,
    attrs = _dbx_mypy_test_attrs,
    outputs = {"out": "%{name}.out"},
    test = True,
)

def dbx_mypy_test(
        name,
        deps,
        size = "small",
        tags = [],
        **kwds):
    # TODO: Don't hard code abi, use ALTERNATIVE_TEST_ABIS
    things = []
    things.append(("", "3.8"))
    for suffix, python_version in things:
        _dbx_mypy_test(
            name = name + suffix,
            deps = deps,
            size = size,
            tags = tags + ["mypy"],
            python_version = python_version,
            **kwds
        )

# Bootstrap rule to build typeshed.
# This is parameterized by python_version.

def _dbx_mypy_bootstrap_impl(ctx):
    return _dbx_mypy_common_code(
        None,
        ctx,
        [],
        [],
        ctx.files.stub_srcs,
        ctx.attr.python_version,
        use_mypyc = False,
    ) + _dbx_mypy_common_code(
        None,
        ctx,
        [],
        [],
        ctx.files.stub_srcs,
        ctx.attr.python_version,
        use_mypyc = True,
    )

_dbx_mypy_bootstrap_attrs = {
    "python_version": attr.string(default = "2.7"),
    "stub_srcs": attr.label_list(allow_files = [".pyi"]),
}
_dbx_mypy_bootstrap_attrs.update(_dbx_mypy_common_attrs)

dbx_mypy_bootstrap = rule(
    implementation = _dbx_mypy_bootstrap_impl,
    attrs = _dbx_mypy_bootstrap_attrs,
)

# Second bootstrap rule to build mypy-stubs.
# This depends on typeshed is parameterized by python_version.

_dbx_mypy_bootstrap_stubs_attrs = {
    "python_version": attr.string(default = "2.7"),
    "stub_srcs": attr.label_list(allow_files = [".pyi"]),
}
_dbx_mypy_bootstrap_stubs_attrs.update(_dbx_mypy_common_attrs)
_dbx_mypy_bootstrap_stubs_attrs.update(_dbx_mypy_typeshed_attrs)

dbx_mypy_bootstrap_stubs = rule(
    implementation = _dbx_mypy_bootstrap_impl,
    attrs = _dbx_mypy_bootstrap_stubs_attrs,
)

# mypyc rules

_mypyc_attrs = {
    "deps": attr.label_list(
        providers = [[PyInfo], [DbxPyVersionCompatibility]],
        aspects = [dbx_mypyc_aspect],
    ),
    "python_version": attr.string(default = "3.8"),
}

_dbx_py_compiled_binary_attrs = dict(dbx_py_binary_attrs)
_dbx_py_compiled_binary_attrs.update(_mypyc_attrs)

def _dbx_py_compiled_binary_impl(ctx):
    ext_modules = depset(
        transitive = [dep[MypycProvider].trans_ext_modules for dep in ctx.attr.deps],
    )
    return dbx_py_binary_base_impl(ctx, internal_bootstrap = False, ext_modules = ext_modules)

dbx_py_compiled_binary = rule(
    implementation = _dbx_py_compiled_binary_impl,
    attrs = _dbx_py_compiled_binary_attrs,
    toolchains = ALL_PY3_TOOLCHAIN_NAMES,
    executable = True,
)

_compiled_test_attrs = dict(dbx_py_test_attrs)
_compiled_test_attrs.update(_mypyc_attrs)
dbx_py_compiled_test = rule(
    implementation = _dbx_py_compiled_binary_impl,
    toolchains = ALL_PY3_TOOLCHAIN_NAMES,
    test = True,
    attrs = _compiled_test_attrs,
)

def dbx_py_compiled_dbx_test(
        name,
        quarantine = {},
        tags = [],
        **kwargs):
    tags = (tags or []) + process_quarantine_attr(quarantine)
    dbx_py_compiled_test(
        name = name,
        quarantine = quarantine,
        tags = tags,
        **kwargs
    )

def _dbx_py_compiled_only_pytest_test(
        name,
        deps = [],
        args = [],
        size = "small",
        services = [],
        start_services = True,
        tags = [],
        test_root = None,
        local = 0,
        flaky = 0,
        quarantine = {},
        # TODO: use default
        python = "cpython-38",
        compiled = False,
        plugins = [],
        visibility = None,
        **kwargs):
    pytest_args, pytest_deps = extract_pytest_args(args, test_root, plugins, **kwargs)

    tags = tags + process_quarantine_attr(quarantine)

    all_deps = deps + pytest_deps

    if len(services) > 0:
        dbx_py_compiled_dbx_test(
            name = name + "_bin",
            pip_main = "@dbx_build_tools//pip/pytest",
            extra_args = pytest_args,
            deps = all_deps,
            size = size,
            tags = tags + ["manual"],
            local = local,
            quarantine = quarantine,
            python = python,
            visibility = ["//visibility:private"],
            **kwargs
        )
        dbx_services_test(
            name = name,
            test = name + "_bin",
            services = services,
            start_services = start_services,
            local = local,
            size = size,
            tags = tags,
            flaky = flaky,
            quarantine = quarantine,
            visibility = visibility,
        )
    else:
        dbx_py_compiled_dbx_test(
            name = name,
            pip_main = "@dbx_build_tools//pip/pytest",
            extra_args = pytest_args,
            deps = all_deps,
            size = size,
            tags = tags,
            local = local,
            flaky = flaky,
            python = python,
            quarantine = quarantine,
            visibility = visibility,
            **kwargs
        )

def dbx_py_compiled_pytest_test(name, compiled_only = False, **kwargs):
    if compiled_only:
        suffix = ""
    else:
        dbx_py_pytest_test(name, **kwargs)
        suffix = "-compiled"
    _dbx_py_compiled_only_pytest_test(name + suffix, **kwargs)
