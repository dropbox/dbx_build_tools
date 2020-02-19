def is_windows(ctx):
    return ctx.var["TARGET_CPU"] in ("x64_windows", "x86_windows")
