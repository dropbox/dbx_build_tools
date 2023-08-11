load("//build_tools/bazel:runfiles.bzl", "runfiles_attrs", "write_runfiles_tmpl")
load("//build_tools/windows:windows.bzl", "is_windows")

unix_shim_template = """
exec "$RUNFILES/{binary_path}" "$@"
"""

windows_shim_template = """
"%RUNFILES%\\{binary_path}" "%*"
"""

def _binary_wrapper_template(ctx):
    if is_windows(ctx):
        return windows_shim_template
    return unix_shim_template

def _dbx_binary_shim_impl(ctx):
    """A shim for binaries that works for Windows & Unix.
    Originally a replacement for `dbx_sh_binary`, which expects a file
    in `srcs`.
    """
    output_name = ctx.attr.name
    if is_windows(ctx):
        output_name = output_name + ".bat"
    output_file = ctx.actions.declare_file(output_name)

    write_runfiles_tmpl(
        ctx,
        output_file,
        _binary_wrapper_template(ctx).format(
            binary_path = ctx.executable.binary.short_path,
        ),
    )

    runfiles = ctx.runfiles(
        files = [output_file],
    ).merge(
        ctx.attr.binary.default_runfiles,
    )

    default_info = DefaultInfo(
        executable = output_file,
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
