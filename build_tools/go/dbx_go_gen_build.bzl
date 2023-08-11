load("//build_tools/go:cfg.bzl", "GO_GEN_BUILD_SRCS")

_GO_GEN_BUILD_BUILD = """
exports_files(["gen-build-go_bin"], visibility="//visibility:public")
"""

def _dbx_go_gen_build_impl(ctx):
    ctx.symlink(
        ctx.path(ctx.attr._go_gen_build_srcs.relative("go.mod")).dirname,
        "gen-build-go",
    )

    go_root = "/".join([str(ctx.path(ctx.attr._go_toolchain).dirname), "go"])
    env = {
        "GOPATH": str(ctx.path(".")),
        "GOROOT": go_root,
        "GOCACHE": "/tmp/go_build_cache",
        "GOBIN": "",
        # workaround: avoid the Go SDK paths from leaking into the binary
        "GOROOT_FINAL": "GOROOT",
        # workaround: avoid cgo paths in /tmp leaking into binary
        "CGO_ENABLED": "0",
    }
    if ctx.attr.goproxy_url:
        env["GOPROXY"] = ctx.attr.goproxy_url
    go_tool = go_root + "/bin/go"

    args = [
        go_tool,
        "install",
        "-ldflags",
        "-w -s",
        "-gcflags",
        "all=-trimpath=" + env["GOPATH"],
        "-asmflags",
        "all=-trimpath=" + env["GOPATH"],
        "-trimpath",
        ".",
    ]
    result = ctx.execute(args, environment = env, working_directory = "gen-build-go")
    if result.return_code:
        fail("failed to build tools: " + result.stderr)

    ctx.symlink("bin/gen-build-go", "gen-build-go_bin")

    ctx.file("BUILD", _GO_GEN_BUILD_BUILD, executable = True)

dbx_go_gen_build = repository_rule(
    _dbx_go_gen_build_impl,
    attrs = {
        "goproxy_url": attr.string(
            doc = """Base url for GOPROXY to fetch modules.""",
        ),
        "_go_toolchain": attr.label(
            default = "@go_1_18_linux_amd64_tar_gz//:WORKSPACE",
            doc = """This implicit dep loads the golang toolchain package. It's a dependency we
            need for gen-build-go-dep to determine which imports are native go imports.""",
        ),
        "_go_gen_build_srcs": attr.label(
            default = GO_GEN_BUILD_SRCS,
        ),
    },
)
