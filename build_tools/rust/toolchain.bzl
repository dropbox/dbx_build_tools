DbxRustCompiler = provider(fields = [
    "cargo",
    "rustc",
    "rustc_executable",
    "rustdoc",
    "rustc_lib_files",
    "rustlib_files",
    "clippy_driver",
    "rustc_lib",
    "rustlib",
])

def get_dirname(short_path):
    return short_path[0:short_path.rfind("/")]

def _dbx_rust_compiler_impl(ctx):
    return [
        DbxRustCompiler(
            rustc = ctx.file.rustc,
            rustc_executable = ctx.executable.rustc,
            cargo = ctx.executable.cargo,
            rustdoc = ctx.executable.rustdoc,
            clippy_driver = ctx.executable.clippy_driver,
            rustc_lib = ctx.attr.rustc_lib,
            rustlib = ctx.attr.rustlib,
        ),
    ]

dbx_rust_compiler = rule(
    _dbx_rust_compiler_impl,
    attrs = {
        "rustc": attr.label(mandatory = True, executable = True, allow_single_file = True, cfg = "host"),
        "rustdoc": attr.label(mandatory = True, executable = True, allow_single_file = True, cfg = "host"),
        "cargo": attr.label(mandatory = True, executable = True, allow_single_file = True, cfg = "host"),
        "rustc_lib": attr.label(mandatory = True),
        "rustlib": attr.label(mandatory = True),
        "clippy_driver": attr.label(mandatory = True, executable = True, allow_single_file = True, cfg = "host"),
    },
)

def _dbx_rust_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            compiler = ctx.attr.compiler,
        ),
    ]

dbx_rust_toolchain = rule(
    _dbx_rust_toolchain_impl,
    attrs = {
        "compiler": attr.label(mandatory = True, providers = [DbxRustCompiler]),
    },
)
