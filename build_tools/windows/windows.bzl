def is_windows(ctx):
    return ctx.target_platform_has_constraint(ctx.attr._windows_platform[platform_common.ConstraintValueInfo])
