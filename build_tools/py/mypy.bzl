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

load("//build_tools/bazel:runfiles.bzl", "runfiles_attrs", "write_runfiles_tmpl")

MypyProvider = provider(fields = [
    "trans_srcs",
    "trans_roots",
    "trans_outs",
    "trans_cache_map",
    "trans_junits",
])

_null_result = MypyProvider(
    trans_outs = depset(),
    trans_srcs = depset(),
    trans_roots = depset(),
    trans_cache_map = depset(),
    trans_junits = depset(),
)

def _get_stub_roots(stub_srcs):
    """
    Helper to add extra roots for stub files in typeshed.

    Paths are of the form:
      <prefix>/{stdlib,third_party}/<version>/<path>
    where:
      <prefix> is external/org_python_typeshed
      <version> can be 2, 3, 2and3, 2.7, 3.3, 3.4 etc.
      <path> is the actual filename we care about, e.g. sys.pyi
    """
    roots = []
    for src in stub_srcs:
        parts = src.path.split("/")
        prefix = []
        for part in parts:
            prefix.append(part)
            if part and part[0].isdigit():
                roots.append("/".join(prefix))
                break
    return roots

def _get_trans_roots(target, srcs, stub_srcs, deps):
    direct = [src.root.path for src in srcs]
    if not target:
        direct += _get_stub_roots(stub_srcs)
    transitive = [
        dep[MypyProvider].trans_roots
        for dep in deps
    ]
    if target:
        transitive.append(target.extra_pythonpath)
    return depset(direct = direct, transitive = transitive)

def _get_trans_outs(outs, deps):
    return depset(
        direct = outs,
        transitive = [dep[MypyProvider].trans_outs for dep in deps],
    )

def _get_trans_srcs(srcs, deps):
    return depset(
        direct = srcs,
        transitive = [dep[MypyProvider].trans_srcs for dep in deps],
    )

def _get_trans_cache_map(cache_map, deps):
    return depset(
        direct = cache_map,
        transitive = [dep[MypyProvider].trans_cache_map for dep in deps],
    )

# Rules into which we descend.  Other rules are ignored.  Edit to taste.
_supported_rules = [
    "dbx_mypy_bootstrap",
    "dbx_py_library",
    "dbx_py_binary",
    "dbx_py_test",
    "services_internal_test",
]

def _dbx_mypy_common_code(target, ctx, deps, srcs, stub_srcs, python_version):
    """
    Code shared between aspect and bootstrap rule.

    target: rule name for aspect, None for bootstrap
    ctx: original context
    deps, srcs, stub_srcs: rule attributes
    python_version: '2.7' or '3.7'
    """
    pyver_dash = python_version.replace(".", "-")
    pyver_under = python_version.replace(".", "_")

    # Except for the bootstrap rule, add typeshed to the dependencies.
    if target:
        typeshed = getattr(ctx.attr, "_typeshed_" + pyver_under)
        deps = deps + [typeshed]

    trans_roots = _get_trans_roots(target, srcs, stub_srcs, deps)

    trans_caches = _get_trans_outs([], deps)

    # Merge srcs and stub_srcs -- when foo.py and foo.pyi are both present,
    # only keep the latter.
    stub_paths = {stub.path: None for stub in stub_srcs}  # Used as a set
    srcs = [src for src in srcs if src.path + "i" not in stub_paths] + stub_srcs

    trans_srcs = _get_trans_srcs(srcs, deps)
    if not trans_srcs:
        return [_null_result]

    outs = []
    junit_xml = "%s-%s-junit.xml" % (ctx.label.name.replace("/", "-"), pyver_dash)
    junit_xml_file = ctx.actions.declare_file(junit_xml)
    cache_map = []  # Items for cache_map file.
    for src in srcs:
        cache_map.append(src)
        path = src.path
        path_base = path[:path.rindex(".")]  # Strip .py or .pyi suffix
        for kind in ("meta", "data"):
            path = "%s.%s.%s.json" % (path_base, python_version, kind)
            file = ctx.actions.declare_file(path)
            outs.append(file)
            cache_map.append(file)
    trans_outs = _get_trans_outs(outs, deps)
    trans_cache_map = _get_trans_cache_map(cache_map, deps)

    inputs = depset(transitive = [
        trans_srcs,
        trans_caches,
        ctx.attr._edgestore_plugin.files,
        ctx.attr._sqlalchemy_plugin.files,
        ctx.attr._py3safe_plugin.files,
        ctx.attr._mypy_ini.files,
    ])
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add("--bazel")
    if python_version != "2.7":
        # For some reason, explicitly passing --python-version 2.7 fails.
        args.add("--python-version", python_version)
    args.add_all(trans_roots, before_each = "--package-root")
    args.add("--no-error-summary")
    args.add("--incremental")
    args.add("--junit-xml", junit_xml_file)
    args.add("--cache-map")
    args.add_all(trans_cache_map)
    args.add("--")
    args.add_all(trans_srcs)
    ctx.actions.run(
        executable = ctx.executable._mypy,
        arguments = [args],
        inputs = inputs,
        outputs = outs + [junit_xml_file],
        mnemonic = "mypy",
        progress_message = "Type-checking %s" % ctx.label,
        tools = [],
    )

    return [
        MypyProvider(
            trans_srcs = trans_srcs,
            trans_roots = trans_roots,
            trans_outs = trans_outs,
            trans_cache_map = trans_cache_map,
            trans_junits = depset(
                direct = [junit_xml_file],
                transitive = [dep[MypyProvider].trans_junits for dep in deps],
            ),
        ),
    ]

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
    if rule.kind not in _supported_rules:
        return [_null_result]
    if not hasattr(rule.attr, "deps") and hasattr(rule.attr, "bin"):
        if rule.kind != "services_internal_test":
            fail("Expected rule kind services_internal_test, got %s" % rule.kind)

        # Special case for tests that specify services=...
        return _dbx_mypy_common_code(
            None,
            ctx,
            [rule.attr.bin],
            [],
            [],
            ctx.attr.python_version,
        )
    return _dbx_mypy_common_code(
        target,
        ctx,
        rule.attr.deps,
        rule.files.srcs,
        rule.files.stub_srcs,
        ctx.attr.python_version,
    )

_dbx_mypy_aspect_attrs = {
    "python_version": attr.string(values = ["2.7", "3.7"]),
    "_typeshed_2_7": attr.label(default = Label("//thirdparty/typeshed:typeshed-2.7")),
    "_typeshed_3_7": attr.label(default = Label("//thirdparty/typeshed:typeshed-3.7")),
}
_dbx_mypy_aspect_attrs.update(_dbx_mypy_common_attrs)

dbx_mypy_aspect = aspect(
    implementation = _dbx_mypy_aspect_impl,
    attr_aspects = ["deps", "bin"],
    attrs = _dbx_mypy_aspect_attrs,
    provides = [MypyProvider],
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
        python2_compatible = True,
        python3_compatible = True,
        **kwds):
    things = []
    if python2_compatible:
        if python3_compatible:
            suffix = "-python2"
        else:
            suffix = ""
        things.append((suffix, "2.7"))
    if python3_compatible:
        things.append(("", "3.7"))
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
    return _dbx_mypy_common_code(None, ctx, [], [], ctx.files.stub_srcs, ctx.attr.python_version)

_dbx_mypy_bootstrap_attrs = {
    "python_version": attr.string(default = "2.7"),
    "stub_srcs": attr.label_list(allow_files = [".pyi"]),
}
_dbx_mypy_bootstrap_attrs.update(_dbx_mypy_common_attrs)

dbx_mypy_bootstrap = rule(
    implementation = _dbx_mypy_bootstrap_impl,
    attrs = _dbx_mypy_bootstrap_attrs,
)
