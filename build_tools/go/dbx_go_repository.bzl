load("//build_tools/bazel:magic_mirror_fallback.bzl", "MAGIC_MIRROR_FALLBACK_GO", "MAGIC_MIRROR_URL_MAPPING")
load("//build_tools/go:cfg.bzl", "GO_DEPENDENCIES_JSON_PATH")

_DBX_GO_REPOSITORY_RULE_TIMEOUT = 86400

def _dbx_go_dependency_impl(ctx):
    go_sdk_label = Label("@" + ctx.attr.go_sdk_name + "//:ROOT")
    go_root = str(ctx.path(go_sdk_label).dirname)

    mm_url = ctx.attr.url
    for mapping in MAGIC_MIRROR_URL_MAPPING:
        mm_url = mm_url.replace(mapping, MAGIC_MIRROR_URL_MAPPING[mapping])

    urls = []

    if not MAGIC_MIRROR_FALLBACK_GO:
        # do not try hitting Artifactory if falling back
        urls.append(ctx.attr.url)

    # append magic mirror url for fallback
    urls.append(mm_url)

    # Fetch an actual archive with module sources and apply patches.
    ctx.download_and_extract(
        urls,
        sha256 = ctx.attr.sha256,
        stripPrefix = ctx.attr.strip_prefix,
    )
    for patch in ctx.attr.patches:
        ctx.patch(patch, strip = 1)

    _run_gen_dep(ctx, "", go_root)

def _run_gen_dep(ctx, working_directory, go_root):
    environment = {
        "GO111MODULE": "off",
        "GOCACHE": "/tmp/go_build_cache",
        "GOROOT": go_root,
    }
    env_keys = ["PATH", "HOME"]
    environment.update({k: ctx.os.environ[k] for k in env_keys if k in ctx.os.environ})

    ctx.report_progress("Running bzl gen...")
    result = ctx.execute(
        [
            str(ctx.path(ctx.attr._gen_build_go)),
            "--embed-use-absolute-filepaths",
            "--skip-deps-generation",
            "--build-config",
            str(ctx.path(ctx.attr._gen_build_go_build_config)),
            "--build-filename",
            "BUILD",
            "--module-name",
            ctx.attr.importpath,
            "--dependencies-path",
            str(ctx.path(ctx.attr._dbx_go_dependencies)),
            ".",
        ],
        environment = environment,
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
        "patches": attr.label_list(
            default = [],
            doc = "labels of patches to apply",
        ),
        "strip_prefix": attr.string(doc = "A directory prefix to strip from the extracted files"),
        "url": attr.string(doc = "The url of the repo's zip file. We currently use magic mirror"),
        "sha256": attr.string(),

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
        "go_sdk_name": attr.string(
            default = "go_sdk",
            doc = """Name of Go SDK to use to determine which imports are native go imports.""",
        ),
        "_dbx_go_dependencies": attr.label(
            default = GO_DEPENDENCIES_JSON_PATH,
            doc = "Indicate that BUILD files need to be regenerated on modules list changes.",
        ),
        "_gen_build_go": attr.label(
            default = "@dbx_go_repository_build_gen//:gen-build-go_bin",
            doc = "Tool that generates BUILD files",
        ),
        "_gen_build_go_build_config": attr.label(
            default = "//go/src/dropbox/build_tools/gen-build-go:config.json",
            doc = "Config for build gen tool",
        ),
    },
)
