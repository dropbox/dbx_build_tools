load("//build_tools/bazel:runfiles.bzl", "runfiles_attrs", "write_runfiles_tmpl")

assert_no_dependency_tmpl = """#!/bin/bash -eux
if [ -s {query_file} ]; then
    {stdin_to_junit} {test_class} {test_name} < {error_message_file}
    exit 1
fi
# create an empty junit file in the passing case
{stdin_to_junit} {test_class} {test_name}
"""

def dbx_assert_no_dependency_test_impl(ctx):
    error_message = "A forbidden dependency exists. Run `bazel query --output=graph 'somepath({}, {})'` to figure out the dependency and remove it.".format(" + ".join(ctx.attr.from_targets), " + ".join(ctx.attr.to_targets))
    if ctx.attr.recommended_fix:
        error_message += "\nRecommended fix:\n" + ctx.attr.recommended_fix
    error_message_file = ctx.actions.declare_file(ctx.label.name + "_error_message")
    ctx.actions.write(
        output = error_message_file,
        content = error_message,
    )
    ctx.actions.write(
        output = ctx.outputs.executable,
        content = assert_no_dependency_tmpl.format(
            query_file = ctx.file.query.short_path,
            stdin_to_junit = ctx.executable._stdin_to_junit.short_path,
            test_class = ctx.label.package,
            test_name = ctx.label.name,
            error_message_file = error_message_file.short_path,
        ),
    )
    runfiles = ctx.runfiles(
        files = ctx.files.query + ctx.files._stdin_to_junit + [error_message_file],
        collect_default = True,
    )
    runfiles = runfiles.merge(ctx.attr._stdin_to_junit.default_runfiles)
    runfiles = runfiles.merge(ctx.attr._stdin_to_junit.data_runfiles)
    return struct(
        runfiles = runfiles,
    )

dbx_assert_no_dependency_internal_test = rule(
    implementation = dbx_assert_no_dependency_test_impl,
    attrs = {
        "query": attr.label(allow_single_file = True),
        "from_targets": attr.string_list(),
        "to_targets": attr.string_list(),
        "recommended_fix": attr.string(mandatory = False),
        "_stdin_to_junit": attr.label(
            executable = True,
            default = Label("//build_tools:stdin_to_junit"),
            cfg = "target",
        ),
    },
    test = True,
)

def dbx_assert_no_dependency_test(
        name,
        from_targets = [],
        to_targets = [],
        whitelisted_direct_rdeps = [],
        recommended_fix = None,
        visibility = None):
    """
    Assert that no path from from_targets to to_targets exist.
    """
    for t in from_targets + to_targets:
        if not t.startswith(("//", "@")) or ":" not in t:
            fail("Use full target path for {}".format(t))
    if whitelisted_direct_rdeps:
        expression = "rdeps(deps({from_targets}), {to_targets}, 1) - ({to_targets}) - ({whitelist})".format(
            from_targets = " + ".join(from_targets),
            to_targets = " + ".join(to_targets),
            whitelist = " + ".join(whitelisted_direct_rdeps),
        )
        extra_scope = whitelisted_direct_rdeps + to_targets
    else:
        # We use a totally different implementation if whitelisted_direct_rdeps is not specified
        # in order to not require adding to_targets to the scope in this case.
        expression = 'filter("^({to_targets})$", deps({from_targets}))'.format(
            from_targets = " + ".join(from_targets),
            to_targets = "|".join(to_targets),
        )
        extra_scope = []
    native.genquery(
        name = name + "_query",
        testonly = True,
        expression = expression,
        scope = from_targets + extra_scope,
    )
    dbx_assert_no_dependency_internal_test(
        name = name,
        query = name + "_query",
        from_targets = from_targets,
        to_targets = to_targets,
        recommended_fix = recommended_fix,
        visibility = visibility,
        size = "small",
    )

assert_one_dependency_impl = '''#!/bin/bash -eu
if [ "$(wc -l {extra_deps_query_file} | cut -f1 -d ' ')" != 1 ]; then
    {stdin_to_junit} {test_class} {test_name} < {error_message_file}
    exit 1
fi
# create an empty junit file in the passing case
{stdin_to_junit} {test_class} {test_name}
'''

def dbx_assert_one_dependency_test_impl(ctx):
    error_message = "{}'s only dependency must be {}.".format(
        ctx.attr.target,
        ctx.attr.dependency,
    )
    error_message_file = ctx.actions.declare_file(ctx.label.name + "_error_message")
    ctx.actions.write(
        output = error_message_file,
        content = error_message,
    )
    ctx.actions.write(
        output = error_message_file,
        content = error_message,
    )
    ctx.actions.write(
        output = ctx.outputs.executable,
        content = assert_one_dependency_impl.format(
            extra_deps_query_file = ctx.file.extra_deps_query.short_path,
            target = ctx.attr.target,
            stdin_to_junit = ctx.executable._stdin_to_junit.short_path,
            test_class = ctx.label.package,
            test_name = ctx.label.name,
            error_message_file = error_message_file.short_path,
        ),
    )
    runfiles = ctx.runfiles(
        files = ctx.files.extra_deps_query + ctx.files._stdin_to_junit + [error_message_file],
        collect_default = True,
    )
    runfiles = runfiles.merge(ctx.attr._stdin_to_junit.default_runfiles)
    runfiles = runfiles.merge(ctx.attr._stdin_to_junit.data_runfiles)
    return struct(
        runfiles = runfiles,
    )

dbx_assert_one_dependency_internal_test = rule(
    implementation = dbx_assert_one_dependency_test_impl,
    attrs = {
        "extra_deps_query": attr.label(allow_single_file = True),
        "target": attr.string(),
        "dependency": attr.string(),
        "_stdin_to_junit": attr.label(
            executable = True,
            default = Label("//build_tools:stdin_to_junit"),
            cfg = "target",
        ),
    },
    test = True,
)

def dbx_assert_one_dependency_test(
        name,
        target,
        dependency):
    """
    Assert that the only dependency that `target` has that `dependency`
    doesn't is `target` itself.
    When used with service groups, this implies that `target` is
    effectively an 'alias' to `dependency`.
    """

    # deps present in target, but not dependency
    # (should only contain dependency)
    extra_deps_expr = """
        deps({target}) - deps({dependency})
    """.format(
        dependency = dependency,
        target = target,
    )
    native.genquery(
        name = name + "_extra_deps_query",
        testonly = True,
        expression = extra_deps_expr,
        scope = [dependency, target],
    )

    dbx_assert_one_dependency_internal_test(
        name = name,
        extra_deps_query = name + "_extra_deps_query",
        target = target,
        dependency = dependency,
        size = "small",
    )

def _list_outputs_bin_impl(ctx):
    # Find all of the files and symlinks in the runfiles, remove the
    # leading './', and don't include this binary. Sort the files so
    # the output is stable.
    cmd = """
    cd $RUNFILES
    find . -type f -o -type l | sed 's|^\./||' | grep -v '^{label}$' | sort
    """.format(
        label = ctx.label.package + "/" + ctx.label.name,
    )
    write_runfiles_tmpl(ctx, ctx.outputs.executable, cmd)

    return struct(
        runfiles = ctx.runfiles(
            collect_default = True,
        ),
    )

_list_outputs_attrs = {
    "data": attr.label_list(mandatory = True),
}
_list_outputs_attrs.update(runfiles_attrs)

_list_outputs_bin = rule(
    implementation = _list_outputs_bin_impl,
    attrs = _list_outputs_attrs,
    executable = True,
)

# Only add to this list if necessary, because needing dbx_list_outputs
# may be caused by a design issue you should fix instead. Talk to
# bazel-dev@ before adding to this list.
_LIST_OUTPUTS_WHITELIST = [
    "//metaserver:inline_static_assets_outputs",
]

def _generate_list_outputs_impl(ctx):
    if str(ctx.label) not in _LIST_OUTPUTS_WHITELIST:
        fail("{} is not whitelisted to use with dbx_list_outputs.".format(ctx.label))

    ctx.actions.run_shell(
        outputs = [ctx.outputs.out],
        tools = [ctx.executable.tool],
        command = "{tool} > {out}".format(
            tool = ctx.file.tool.path,
            out = ctx.outputs.out.path,
        ),
    )
    return struct(
        runfiles = ctx.runfiles(
            files = [ctx.outputs.out],
        ),
    )

_generate_list_outputs = rule(
    implementation = _generate_list_outputs_impl,
    attrs = {
        "tool": attr.label(
            executable = True,
            allow_single_file = True,
            cfg = "host",
        ),
    },
    outputs = {
        "out": "%{name}.txt",
    },
)

def dbx_list_outputs(name, data = []):
    '''
    Outputs a file that contains all the file names of the outputs of
    srcs relative to runfiles.

    The name of the output file is the same as the name of the target
    with ".txt" appended to it.

    NOTE: Needing to use this rule usually comes from a design issue.
    Only use it if absolutely necessary.
    '''

    # This macro first creates a binary with `srcs` in its runfiles
    # that reads its own runfiles. Then it uses that binary in
    # _generate_list_outputs to create the "list outputs" file.
    #
    # We need to create a separate binary to get bazel to construct
    # the runfiles tree with `srcs` because Bazel doesn't expose
    # enough runfiles information to read the runfiles from `srcs`
    # directly within a rule.
    _list_outputs_bin(
        name = name + "_bin",
        data = data,
    )
    _generate_list_outputs(
        name = name,
        tool = name + "_bin",
    )
