genrule(
    name = "repo_revision",
    outs = [".repo_revision"],
    cmd = "$(location //build_tools:parse_workspace_status) >$@",
    stamp = True,
    tools = ["//build_tools:parse_workspace_status"],
    visibility = ["//visibility:public"],
)
