load("//build_tools/go:dbx_go_gen_build.bzl", "dbx_go_gen_build")

def load_go_build_gen(goproxy_url = ""):
    dbx_go_gen_build(
        name = "dbx_go_repository_build_gen",
        goproxy_url = goproxy_url,
    )
