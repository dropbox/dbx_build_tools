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
