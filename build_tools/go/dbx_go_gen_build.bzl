load("//build_tools/go:dbx_go_gen_build_srcs.bzl", "GO_GEN_BUILD_SRCS")

_GO_GEN_BUILD_BUILD = """
exports_files(["gen-build-go_bin"], visibility="//visibility:public")
"""

def _dbx_go_gen_build_impl(ctx):
    ctx.symlink(
        ctx.path(Label("//go/src/dropbox/build_tools/gen-build-go:go.mod")).dirname,
        "gen-build-go",
    )

    go_sdk_label = Label("@" + ctx.attr.go_sdk_name + "//:ROOT")
    go_root = str(ctx.path(go_sdk_label).dirname)
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
        "go_sdk_name": attr.string(
            default = "go_sdk",
            doc = """Name of Go SDK to use to compile gen-build-go binary.""",
        ),
        "_go_gen_build_srcs": attr.label_list(
            default = GO_GEN_BUILD_SRCS,
        ),
    },
)
