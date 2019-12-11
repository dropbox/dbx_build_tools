load("//build_tools/bazel:runfiles.bzl", "runfiles_attrs", "write_runfiles_tmpl")
load("//build_tools/bazel:quarantine.bzl", "process_quarantine_attr")

def dbx_sh_binary_impl(ctx):
    if len(ctx.files.srcs) != 1:
        fail("Must have exactly one file in srcs")

    main = ctx.files.srcs[0]
    write_runfiles_tmpl(
        ctx,
        ctx.outputs.executable,
        "exec $RUNFILES/{} \"$@\"".format(main.short_path),
    )
    return struct(
        files = depset([ctx.outputs.executable, main]),
        runfiles = ctx.runfiles(files = [main, ctx.outputs.executable], collect_default = True),
    )

_sh_attrs = {
    "data": attr.label_list(allow_files = True),
    "deps": attr.label_list(allow_rules = ["sh_library"]),
    "srcs": attr.label_list(allow_files = True, allow_empty = False),
}
_sh_attrs.update(runfiles_attrs)

_sh_test_attrs = dict(_sh_attrs)
_sh_test_attrs.update({
    "quarantine": attr.string_dict(),
})

dbx_sh_binary = rule(
    implementation = dbx_sh_binary_impl,
    attrs = _sh_attrs,
    executable = True,
)

dbx_sh_internal_test = rule(
    implementation = dbx_sh_binary_impl,
    attrs = _sh_test_attrs,
    test = True,
)

def dbx_sh_test(name, quarantine = {}, tags = [], **kwargs):
    q_tags = process_quarantine_attr(quarantine)
    tags = tags + q_tags

    dbx_sh_internal_test(
        name = name,
        tags = tags,
        quarantine = quarantine,
        **kwargs
    )

shim_template = """
exec $RUNFILES/{binary_path} "$@"
"""

def _dbx_binary_shim_impl(ctx):
    """A shim for binaries. An unfortunate replacement for dbx_sh_binary because
    dbx_sh_binary expects a file in srcs.
    """
    write_runfiles_tmpl(
        ctx,
        ctx.outputs.executable,
        shim_template.format(
            binary_path = ctx.executable.binary.short_path,
        ),
    )

    runfiles = ctx.runfiles(
        files = [ctx.outputs.executable],
    ).merge(
        ctx.attr.binary.default_runfiles,
    )

    default_info = DefaultInfo(
        files = depset([ctx.outputs.executable]),
        runfiles = runfiles,
    )

    return [default_info]

_binary_shim_attrs = {
    "binary": attr.label(mandatory = True, executable = True, cfg = "target"),
}
_binary_shim_attrs.update(runfiles_attrs)

dbx_binary_shim = rule(
    implementation = _dbx_binary_shim_impl,
    attrs = _binary_shim_attrs,
    executable = True,
)

dbx_binary_shim_test = rule(
    implementation = _dbx_binary_shim_impl,
    attrs = _binary_shim_attrs,
    executable = True,
    test = True,
)
