# Create a dummy rule. These type of rules will be handle externally
# until there is a better story for Starlark rules accessing runfiles.

def pkg_deb_impl(ctx):
    ctx.actions.run_shell(
        command = "echo 'dbx_pkg_deb targets must be built using bzl pkg'; exit 1",
        inputs = ctx.files.data,
        outputs = [ctx.outputs.executable],
    )

# These attrs will be interpreted by the bazelpkg tool directly.
deb_pkg_attrs = {
    "data": attr.label_list(allow_files = True),
    "prefix": attr.string(default = "/usr/bin"),
    "preserve_symlinks": attr.bool(
        default = False,
        doc = "Controls whether or not to preserve symlinks found in the Bazel outputs. " +
              "If set to True, prevents dereferencing of any symlinks (for example, created " +
              "by a genrule) and instead recreates the symlink inside the package.",
    ),
    "file_map": attr.string_dict(),
    "package": attr.string(),
    "version": attr.string(),
    "after_install": attr.string(),
    "after_upgrade": attr.string(),
    "before_remove": attr.string(),
    "before_upgrade": attr.string(),
    "replaces": attr.string_list(default = []),
    "conflicts": attr.string_list(default = []),
    "provides": attr.string_list(default = []),
    "depends": attr.string_list(default = []),
}

_dbx_pkg_deb = rule(
    implementation = pkg_deb_impl,
    attrs = deb_pkg_attrs,
    # Not really executable, of course, but avoids warnings about the rule name
    # and output being the same.
    executable = True,
)

# Use a macro to ensure the file extension is .deb
def dbx_pkg_deb(name, tags = [], **kargs):
    if not name.endswith(".deb"):
        name += ".deb"
    _dbx_pkg_deb(name = name, tags = tags + ["manual"], **kargs)

# A small macro to bundle configs in a runfiles directory with a fake shell script.
def legacy_dbx_pkg_config(name, data, visibility = None):
    if visibility != None:
        fail("""legacy_dbx_pkg_config does not support custom visibilities.
because nothing should ever depend directly on a legacy_dbx_pkg_config.
It is a hack used only for yaps deployments. If you need to depend
on this, use a filegroup instead.
""")
    native.sh_binary(
        name = name,
        srcs = ["//configs:_config_hack.sh"],
        data = data,
        visibility = ["//configs/services:__subpackages__"],
    )

def dbx_unsquash(name, srcs, outs, visibility = None):
    "Extract *outs* from the squashfs image in *srcs*."
    if len(srcs) != 1:
        fail("need exactly one src")
    dest = "$(GENDIR)/{}".format(native.package_name())
    native.genrule(
        name = name,
        srcs = srcs,
        cmd = """
$(location //build_tools:chronic) $(location @com_github_plougher_squashfs-tools//:unsquashfs) -f -d {} $< {}
""".format(dest, " ".join(outs)),
        outs = outs,
        visibility = visibility,
        tools = [
            "//build_tools:chronic",
            "@com_github_plougher_squashfs-tools//:unsquashfs",
        ],
    )

###########
# New-age Bazel sandboxed packaging rules below.
##########

def _add_runfiles_to_file_map(file_map, runfiles, runfiles_prefix, empty_file):
    # For files and empty files, we must handle the case where the files live in
    # external workspaces -- we would like to put them in both ../WORKSPACE and
    # external/WORKSPACE.
    for f in runfiles.files.to_list():
        file_map[runfiles_prefix + get_canonical_path(f.short_path, legacy = True)] = f
        file_map[runfiles_prefix + get_canonical_path(f.short_path, legacy = False)] = f
    for ln in runfiles.symlinks.to_list():
        file_map[runfiles_prefix + ln.path] = ln.target_file
    for ln in runfiles.root_symlinks.to_list():
        file_map[ln.path] = ln.target_file
    for path in runfiles.empty_filenames.to_list():
        file_map[runfiles_prefix + get_canonical_path(path, legacy = True)] = empty_file
        file_map[runfiles_prefix + get_canonical_path(path, legacy = False)] = empty_file

def _pkg_path(item):
    (name_in_pkg, f) = item
    return name_in_pkg + "\000" + f.path

def _collect_data(ctx, data, symlink_map_attr, binary_link_dir):
    file_map = {}

    # Allow symlinks so users can maintain some semblance of backwards compatibility.
    # This should be a temporary tactic for configuration files -- users who are using
    # this long-term should be encouraged to fix code references instead. This should
    # not be needed for binaries -- those are already symlinked into the root or bin/
    # directory.
    # Keys are symlink locations, values are the target, relative to SquashFS root.
    symlink_map = dict()
    symlink_map.update(symlink_map_attr)

    targets = _collect_transitive_data(data).to_list()

    for target in targets:
        files_to_run = target[DefaultInfo].files_to_run
        if files_to_run and files_to_run.executable and files_to_run.runfiles_manifest:
            is_executable = True
        else:
            is_executable = False

        empty_file = ctx.actions.declare_file(ctx.label.name + ".empty")
        ctx.actions.write(empty_file, "")

        if not ctx.attr.allow_empty_targets and not is_executable and not target[DefaultInfo].files:
            fail(str(target.label) + " has no files to package. " +
                 "if using a filegroup, files should be specified under srcs and not data")

        for f in target[DefaultInfo].files.to_list():
            # Empirically, external files will have a short_path starting with '../WORKSPACE'.
            file_map[get_canonical_path(f.short_path, legacy = True)] = f

        if is_executable:
            root_runfiles_prefix = ""

            # If the target label refers to an external workspace, put it in `external/WORKSPACE/`.
            # Empirically, the workspace_root for a label will be of form `external/WORKSPACE`, so
            # we can use this as is.
            if target.label.workspace_root:
                root_runfiles_prefix += target.label.workspace_root + "/"

            # A label's package will be empty if the target is in the top-level BUILD file.
            if target.label.package:
                root_runfiles_prefix += target.label.package + "/"
            root_runfiles_prefix += target.label.name + ".runfiles/"
            package_runfiles_prefix = root_runfiles_prefix + ctx.workspace_name + "/"

            # Symlink the executable and its runfiles directory to binary_link_dir.
            if binary_link_dir != None:
                executable = files_to_run.executable
                symlink_map[binary_link_dir + executable.basename] = get_canonical_path(executable.short_path, legacy = True)
                symlink_map[binary_link_dir + target.label.name + ".runfiles"] = root_runfiles_prefix

            _add_runfiles_to_file_map(
                file_map,
                target[DefaultInfo].data_runfiles,
                package_runfiles_prefix,
                empty_file,
            )
            _add_runfiles_to_file_map(
                file_map,
                target[DefaultInfo].default_runfiles,
                package_runfiles_prefix,
                empty_file,
            )

    content = ctx.actions.args()
    content.set_param_file_format("multiline")
    content.add_all(file_map.items(), map_each = _pkg_path)

    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(manifest, content)

    symlink = _write_map_to_file(ctx, "symlink", symlink_map)

    return file_map.values(), manifest, symlink

def get_canonical_path(file_path, legacy = False):
    # If the file is in an external workspace, the path can start with either '../WORKSPACE'
    # or 'external/WORKSPACE'. If legacy is True, it returns 'external/WORKSPACE', otherwise
    # it returns '../WORKSPACE'..
    # If the file isn't from an external workspace, this function returns the input unchanged.
    if legacy and file_path.startswith("../"):
        return "external/" + file_path[3:]
    if not legacy and file_path.startswith("external/"):
        return "../" + file_path[9:]
    return file_path

def _write_map_to_file(ctx, name, dictionary):
    file_to_write = ctx.actions.declare_file(ctx.label.name + "." + name)

    ctx.actions.write(
        file_to_write,
        "\n".join([key + "\000" + value for key, value in dictionary.items()]),
    )

    return file_to_write

DbxPkgGroupInfo = provider(fields = [
    "data",
])

def _collect_transitive_data(data):
    transitive_data = []
    direct_data = []
    for target in data:
        if DbxPkgGroupInfo in target:
            transitive_data.append(target[DbxPkgGroupInfo].data)
        else:
            direct_data.append(target)
    return depset(direct_data, transitive = transitive_data)

def pkg_group_impl(ctx):
    return struct(
        providers = [
            DbxPkgGroupInfo(
                data = _collect_transitive_data(ctx.attr.data),
            ),
        ],
    )

# dbx_pkg_group allows one to define a group of targets that can then be included
# correctly in dbx_pkg_sqfs later. filegroup doesn't work, as it loses information
# like which targets are binaries
dbx_pkg_group = rule(
    implementation = pkg_group_impl,
    attrs = {
        "data": attr.label_list(allow_files = True),
    },
)

def pkg_sqfs_impl(ctx):
    binary_link_dir = ""
    if ctx.attr.use_bin_dir:
        binary_link_dir = "bin/"

    files, manifest, symlink = _collect_data(
        ctx,
        ctx.attr.data + [ctx.attr._repo_revision],
        ctx.attr.symlink_map,
        binary_link_dir,
    )
    extra_input_files = [manifest, symlink]

    args = ctx.actions.args()
    args.add("--output", ctx.outputs.executable)
    args.add("--manifest", manifest)
    args.add("--symlink", symlink)
    workdir = ctx.configuration.genfiles_dir.path + "/" + ctx.label.package + "/" + ctx.outputs.executable.basename + ".tmp"
    args.add("--scratch-dir", workdir)

    if ctx.attr.capability_map:
        capability_file = _write_map_to_file(ctx, "capability", ctx.attr.capability_map)
        extra_input_files.append(capability_file)
        args.add("--capability-map", capability_file)

    if ctx.attr.block_size_kb:
        args.add("--block-size-kb", str(ctx.attr.block_size_kb))

    ctx.actions.run(
        outputs = [ctx.outputs.executable],
        inputs = files + extra_input_files,
        executable = ctx.executable._build_sqfs,
        arguments = [args],
        mnemonic = "sqfs",
        execution_requirements = {
            "requires-fakeroot": "1",
        },
    )

def dbx_pkg_sqfs(name, tags = [], **kwargs):
    if not name.endswith(".sqfs"):
        fail("dbx_pkg_sqfs target name must end with .sqfs")
    _dbx_pkg_sqfs(name = name, tags = tags + ["sqfs"], **kwargs)

_dbx_pkg_sqfs = rule(
    implementation = pkg_sqfs_impl,
    attrs = {
        "data": attr.label_list(allow_files = True),
        "release_tests": attr.string_list(
            mandatory = True,
            allow_empty = True,
            doc = "List of tests that need to be green before the service can safely deploy. " +
                  "This attribute will be ignored if yaps config explicitly sets repo_key.",
            default = [],
        ),
        "block_size_kb": attr.int(),
        "capability_map": attr.string_dict(),
        "symlink_map": attr.string_dict(
            allow_empty = True,
            default = {},
            doc = "Maps a location in the SquashFS to another location. " +
                  "Key is the destination location in the SquashFS, value is " +
                  "the symlink target. All paths must be relative to " +
                  "the top level SquashFS root. Should only be used to symlink config " +
                  "files while migrating to this rule.",
        ),
        "use_bin_dir": attr.bool(
            default = False,
            doc = "If true, creates links for all binaries in a bin/ directory for " +
                  "convenience, instead of in the top-level root.",
        ),
        "allow_empty_targets": attr.bool(
            default = False,
            doc = "If true, disables the assertion that all data targets must have files to package. " +
                  "Setting this to false allows you to package empty filegroups, for example. " +
                  "By default, this is set to False as empty targets are usually user-errors, but " +
                  "auto-generated SquashFS packages may find this useful.",
        ),
        "_repo_revision": attr.label(
            default = Label("//:repo_revision"),
            executable = False,
        ),
        "_build_sqfs": attr.label(
            default = Label("//build_tools:build_sqfs"),
            executable = True,
            cfg = "host",
        ),
    },
    # Avoids warnings about the rule name and output being the same.
    executable = True,
)
