_create_symlink_attrs = {
    "link": attr.string(mandatory = True),
    "target": attr.string(mandatory = True),
}

def _create_symlink_impl(ctx):
    symlink = ctx.actions.declare_symlink(ctx.attr.link)
    ctx.actions.symlink(output = symlink, target_path = ctx.attr.target)
    return [DefaultInfo(files = depset([symlink]))]

create_symlink = rule(
    implementation = _create_symlink_impl,
    attrs = _create_symlink_attrs,
)
