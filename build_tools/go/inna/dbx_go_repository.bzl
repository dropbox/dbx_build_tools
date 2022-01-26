_DBX_GO_REPOSITORY_RULE_TIMEOUT = 86400

def _dbx_go_dependency_impl(ctx):
    fetch_repo_args = None
    if ctx.attr.commit or ctx.attr.tag:
        # repository mode
        if ctx.attr.commit:
            rev = ctx.attr.commit
            rev_key = "commit"
        elif ctx.attr.tag:
            rev = ctx.attr.tag
            rev_key = "tag"

        if ctx.attr.vcs and not ctx.attr.remote:
            fail("if vcs is specified, remote must also be")

        fetch_repo_args = ["-dest", str(ctx.path("")), "-importpath", ctx.attr.importpath]
        if ctx.attr.remote:
            fetch_repo_args.extend(["--remote", ctx.attr.remote])
        if rev:
            fetch_repo_args.extend(["--rev", rev])
        if ctx.attr.vcs:
            fetch_repo_args.extend(["--vcs", ctx.attr.vcs])
    else:
        fail("one of commit or tag must be specified")

    execute_command = str(ctx.path(Label("@bazel_gazelle_go_repository_tools//:bin/fetch_repo")))
    result = ctx.execute(
        [execute_command] + fetch_repo_args,
        timeout = _DBX_GO_REPOSITORY_RULE_TIMEOUT,
    )
    if result.return_code:
        fail("failed to fetch %s: %s" % (ctx.name, result.stderr))
    if result.stderr:
        print("fetch_repo: " + result.stderr)

    _run_gen_dep_on_repo(ctx)

def _run_gen_dep_on_repo(ctx):
    _run_gen_dep(ctx, "")
    if ctx.attr.submodules:
        for submodule in ctx.attr.submodules:
            _run_gen_dep(ctx, submodule)

def _run_gen_dep(ctx, working_directory):
    module_name = ctx.attr.importpath
    if working_directory:
        module_name = "/".join([module_name, working_directory])
    go_root = "/".join([str(ctx.path("").dirname), "go_1_16_linux_amd64_tar_gz/go"])
    environment = {
        "GO111MODULE": "off",
        "GOCACHE": "/tmp/go_build_cache",
        "GOROOT": go_root,
    }
    env_keys = ["PATH", "HOME"]
    environment.update({k: ctx.os.environ[k] for k in env_keys if k in ctx.os.environ})
    result = ctx.execute(
        [
            "/sqpkg/team/build-infra-team/bzl/bzl-gen.runfiles/__main__/go/src/dropbox/build_tools/gen-build-go-dep/gen-build-go-dep",
            "--verbose",
            "--skip-deps-generation",
            "--build-filename",
            "BUILD",
            "--module-name",
            module_name,
            "--repo-root",
            ctx.attr.importpath,
            ".",
        ],
        environment = environment,
        working_directory = working_directory,
    )
    if result.return_code:
        fail("failed to build %s: %s" % (ctx.name, result.stderr))
    if result.stderr:
        print("gen-build-go-dep: " + result.stderr)

dbx_go_dependency = repository_rule(
    implementation = _dbx_go_dependency_impl,
    doc = """
        This rule is used to define a third party repository. The repo will be downloaded
        to bazel cache and bzl gen will be run on it to generate BUILD files.
    """,
    local = True,
    attrs = {
        # Fundamental attributes of a go repository
        "importpath": attr.string(
            doc = """The Go import path that matches the root directory of this repository.

            In module mode (when `version` is set), this must be the module path. If
            neither `urls` nor `remote` is specified, `go_repository` will
            automatically find the true path of the module, applying import path
            redirection.

            If build files are generated for this repository, libraries will have their
            `importpath` attributes prefixed with this `importpath` string.  """,
            mandatory = True,
        ),
        # Attributes for a repository that should be checked out from VCS
        "commit": attr.string(
            doc = """If the repository is downloaded using a version control tool, this is the
            commit or revision to check out. With git, this would be a sha1 commit id.
            `commit` and `tag` may not both be set.""",
        ),
        "tag": attr.string(
            doc = """If the repository is downloaded using a version control tool, this is the
            named revision to check out. `commit` and `tag` may not both be set.""",
        ),
        "submodules": attr.string_list(
            default = [],
            doc = "sub-paths in the repo that need to have a BUILD file",
        ),
        "vcs": attr.string(
            default = "",
            values = [
                "",
                "git",
                "hg",
                "svn",
                "bzr",
            ],
        ),
        "remote": attr.string(),
    },
)
