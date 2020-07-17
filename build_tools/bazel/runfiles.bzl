load("//build_tools/windows:windows.bzl", "is_windows")

# Finding the .runfiles tree is delicate, and we've broken it many times. Be
# careful! A couple of points:
#
# - Morally, what we want to do is
#     RUNFILES = readlink("/proc/self/exe") + ".runfiles"
#
#   The above implementation has many virtues. It's certainly simple, but there
#   are other subtler advantages. In particular, /proc/self/exe points a
#   fully-resolved path. That's important because
#     1) We may be invoked through a symlink that doesn't have an associated
#        runfiles tree.
#     2) During a YAPS package switch, using the fully resolved path prevents
#        old executables from reading the new executable's runfiles tree. In
#        this case, the executable won't be a symlink, but a directory component
#        in the absolute path of argv[0] may be.
#     3) /proc/self/exe gives us the actual executable path without races; it's
#        exactly the same path the kernel loaded us from.
#   Alas, we're computing the path to runfiles in a shell script, and
#   /proc/self/exe is consequently useless to us. All we have is argv[0]. So,
#   our computations here are inherently racy.
#
# - If a binary is listed as a data dep for another tool, we want to find the
#   "outer" binary's runfiles tree and not follow any symlinks out of it.
#
# - In the sandbox, every executable is a symlink. Here, we DONT'T want to
#   resolve too much lest we escape the sandbox. Note the .runfiles directory
#   itself is not a symlink in the sandbox.
#
# So, what we're going to do is resolve the executable until we find a .runfiles
# directory and then fully resolve the path to that directory.

runfiles_attrs = {
    "_runfiles_template": attr.label(
        default = Label("//build_tools/bazel:runfiles.tmpl"),
        allow_single_file = True,
    ),
    "_runfiles_bat_template": attr.label(
        default = Label("//build_tools/bazel:runfiles.bat.tmpl"),
        allow_single_file = True,
    ),
    "_windows_platform": attr.label(default = Label("@platforms//os:windows")),
}

# This will write different types of files depending on the OS.
# Be sure to make `content` compatible with the expected script
# type -- either batch on Windows or bash on Unix.
def write_runfiles_tmpl(ctx, out, content):
    if is_windows(ctx):
        template_file = ctx.file._runfiles_bat_template
    else:
        template_file = ctx.file._runfiles_template

    ctx.actions.expand_template(
        template = template_file,
        output = out,
        substitutions = {
            "{workspace_name}": ctx.workspace_name,
            "{content}": content,
        },
        is_executable = True,
    )
