def _new_drte_build_sysroot_archive_impl(repository_ctx):
    # There doesn't seem to be any Starlark API to get this as an absolute path.
    cwd = repository_ctx.execute(["/bin/pwd"]).stdout.strip()
    repository_ctx.template("BUILD", repository_ctx.attr.build_file_template, {
        "%{crosstool_top_absolute}": cwd,
        "%{workspace_absolute}": cwd.split("/external/")[0],
    })

    # Unfortunately Bazel throws an error if we pass a gcc wrapper from another
    # repo in the tool_path directly.
    # "The include path '../../external/cuda/wrap_gcc' is not normalized."
    # Work around with another layer of wrapper script.
    repository_ctx.file(
        "root/bin/cuda_wrap_gcc",
        '''\
#! /bin/sh
d="$(dirname $0)"
export REAL_GCC="$d/gcc"
exec "$d/../../../../external/cuda/wrap_gcc" "$@"
''',
        executable = True,
    )

    # Download and extract the drte_build_sysroot archive.
    # This should be the final step to avoid duplicate downloads caused by
    # bazel's implicit restarting of repository rules when labels are resolved.
    repository_ctx.download_and_extract(
        repository_ctx.attr.url,
        sha256 = repository_ctx.attr.sha256,
    )

new_drte_build_sysroot_archive = repository_rule(
    implementation = _new_drte_build_sysroot_archive_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "build_file_template": attr.label(mandatory = True, allow_files = True),
    },
)
