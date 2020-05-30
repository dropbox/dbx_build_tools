# Currently used only by sqfs rules to store a file containing the git commit
# for deployments. Shouldn't be needed or used by anything else.
genrule(
    name = "repo_revision",
    outs = [".repo_revision"],
    cmd = "$(location //build_tools:parse_workspace_status) >$@",
    stamp = True,
    tools = ["//build_tools:parse_workspace_status"],
    visibility = ["//build_tools:__pkg__"],
)
