load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load(
    "@bazel_tools//tools/build_defs/cc:action_names.bzl",
    "CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME",
    "C_COMPILE_ACTION_NAME",
)
load("//build_tools/bazel:runfiles.bzl", "runfiles_attrs")
load("//build_tools/bazel:quarantine.bzl", "process_quarantine_attr")
load(
    "@dbx_build_tools//build_tools/py:toolchain.bzl",
    "BUILD_TAG_TO_TOOLCHAIN_MAP",
    "CPYTHON_27_TOOLCHAIN_NAME",
    "DbxPyInterpreter",
    "get_py_toolchain_name",
)
load("//build_tools/services:svc.bzl", "dbx_services_test")
load(
    "//build_tools/py:cfg.bzl",
    "ALL_ABIS",
    "GLOBAL_PYTEST_ARGS",
    "GLOBAL_PYTEST_PLUGINS",
    "NON_THIRDPARTY_PACKAGE_PREFIXES",
    "PY2_TEST_ABI",
    "PY3_ALTERNATIVE_TEST_ABIS",
    "PY3_DEFAULT_BINARY_ABI",
    "PY3_TEST_ABI",
    "PYPI_MIRROR_URL",
)
load(
    "//build_tools/py:common.bzl",
    "ALL_TOOLCHAIN_NAMES",
    "DbxPyVersionCompatibility",
    "allow_dynamic_links",
    "collect_required_piplibs",
    "collect_transitive_srcs_and_libs",
    "compile_pycs",
    "emit_py_binary",
    "py_binary_attrs",
    "py_file_types",
    "pyi_file_types",
    "workspace_root_to_pythonpath",
)
load("//build_tools/bazel:config.bzl", "DbxStringValue")
load("//build_tools/windows:windows.bzl", "is_windows")

def _get_build_interpreters(attr):
    interpreters = []
    if attr.python2_compatible:
        interpreters.extend([abi for abi in ALL_ABIS if abi.major_python_version == 2])
    if attr.python3_compatible:
        interpreters.extend([abi for abi in ALL_ABIS if abi.major_python_version == 3])
    return interpreters

def _get_build_interpreters_for_target(ctx):
    abis = _get_build_interpreters(ctx.attr)
    return [struct(
        build_tag = abi.build_tag,
        target = ctx.toolchains[BUILD_TAG_TO_TOOLCHAIN_MAP[abi.build_tag]].interpreter[DbxPyInterpreter],
        attr = abi.attr,
    ) for abi in abis]

# We use `$(ROOT)` env var in env/global-options attributes to refer to absolute path to base/root
# directory where action is executed. If absolute path to this directory is computed at analysis
# time (in Starlark), this action cannot be executed remotely. To work around this, we use a
# placeholder attribute for `$(ROOT)` which gets replaced in vpip during execution.
# Placeholder text which gets replaced with base/root directory where action is executed.
ROOT_PLACEHOLDER = "____root____"

def _add_vpip_compiler_args(ctx, cc_toolchain, copts, args):
    # Set the compiler to the crosstool compilation driver.
    args.add(cc_toolchain.compiler_executable, format = "--compiler-executable=%s")
    args.add(cc_toolchain.ar_executable, format = "--archiver=%s")
    feature_configuration = cc_common.configure_features(ctx = ctx, cc_toolchain = cc_toolchain)

    # Add base compiler flags from the crosstool. These contain the correct
    # include paths and other side-wide settings like -fstack-protector. These
    # flags are added in addition to whatever other flags distutils sees fit to
    # use. distutils does not distinguish between compilation of C and C++; we
    # must pass the C++ flags through CFLAGS if there is any C++ in the extension
    # module. Passing C++ options when compiling C is basically harmless. At most,
    # it generates some warnings that no one ever has to look at.
    compile_variables = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        user_compile_flags = copts,
    )
    compiler_options = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = C_COMPILE_ACTION_NAME,
        variables = compile_variables,
    )
    args.add_all(compiler_options, format_each = "--compile-flags=%s")

    link_variables = cc_common.create_link_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        is_static_linking_mode = True,
    )
    link_flags = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME,
        variables = link_variables,
    )
    link_env = cc_common.get_environment_variables(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME,
        variables = link_variables,
    )
    if cc_common.is_enabled(
        feature_configuration = feature_configuration,
        feature_name = "fortran",
    ):
        fortran = cc_common.get_tool_for_action(
            feature_configuration = feature_configuration,
            action_name = "fortran_compile",
        )
        args.add(fortran, format = "--fortran-compiler=%s")

    # Add anything that isn't a library from the linker flags.
    args.add_all(
        [flag for flag in link_flags if not flag.startswith("-l") and flag != "-shared"],
        format_each = "--extra-ldflag=%s",
    )

    return link_env

def _debug_prefix_map_supported(ctx):
    return ctx.attr._debug_prefix_map_supported[DbxStringValue].value == "yes"

def _build_wheel(ctx, wheel, python_interp, sdist_tar):
    build_tag = python_interp.build_tag
    toolchain = ctx.toolchains[get_py_toolchain_name(build_tag)]
    command_args = ctx.actions.args()
    command_args.add("--no-deps")
    command_args.add("--wheel", wheel)
    command_args.add("--python", python_interp.path)
    command_args.add("--build-tag", build_tag)

    # Add linux specific exclusions when that is the target platform.
    if ctx.target_platform_has_constraint(ctx.attr._linux_platform[platform_common.ConstraintValueInfo]):
        command_args.add("--linux-exclude-libs")
        command_args.add("--target-dynamic-lib-suffix", ".so")
    elif ctx.target_platform_has_constraint(ctx.attr._macos_platform[platform_common.ConstraintValueInfo]):
        command_args.add("--target-dynamic-lib-suffix", ".dylib")
    elif is_windows(ctx):
        command_args.add("--msvc-toolchain")
        command_args.add("--target-dynamic-lib-suffix", ".lib")

    # Some client toolchains are old enough to not support this.
    if not _debug_prefix_map_supported(ctx):
        command_args.add("--no-debug-prefix-map")

    if ctx.attr.use_pep517:
        command_args.add("--use-pep517")

    outputs = [wheel]

    cc_toolchain = find_cpp_toolchain(ctx)
    link_env = _add_vpip_compiler_args(ctx, cc_toolchain, ctx.attr.copts, command_args)

    inputs_direct = []
    inputs_trans = [
        python_interp.runtime,
        python_interp.headers,
        cc_toolchain.all_files,
    ]
    tools = [t[DefaultInfo].files_to_run for t in ctx.attr.tools]

    cc_infos = []
    frameworks = []
    rust_deps = []
    for dep in ctx.attr.deps:
        # Automatically include header files from any cc_library dependencies
        if CcInfo in dep:
            cc_infos.append(dep[CcInfo])
        elif hasattr(dep, "crate_type"):
            # dep is a rust_library.
            rust_deps.append(dep)
        elif apple_common.AppleDynamicFramework in dep:
            if allow_dynamic_links(ctx):
                frameworks.append(dep[apple_common.AppleDynamicFramework])
            else:
                fail("Encountered Apple framework while dynamic links were disallowed.")
        elif not hasattr(dep, "piplib_contents"):
            # Note vpip can't depend on other Python libraries.
            inputs_trans.append(dep.files)
    cc_info = cc_common.merge_cc_infos(cc_infos = cc_infos)
    cc_compilation = cc_info.compilation_context
    cc_linking = cc_info.linking_context
    inputs_trans.append(cc_compilation.headers)
    inputs_trans.append(cc_linking.additional_inputs)
    command_args.add_all(cc_compilation.includes, format_each = "--compile-flags=-I %s")
    command_args.add_all(
        cc_compilation.system_includes,
        format_each = "--compile-flags=-isystem %s",
    )
    command_args.add_all(
        cc_compilation.quote_includes,
        format_each = "--compile-flags=-iquote %s",
    )
    l2ls = cc_linking.libraries_to_link
    if hasattr(l2ls, "to_list"):
        l2ls = l2ls.to_list()
    pic_libs = []
    dynamic_libs = []
    for l2l in l2ls:
        if l2l.pic_static_library or l2l.static_library:
            pic_libs.append(l2l.pic_static_library or l2l.static_library)
        elif l2l.dynamic_library and allow_dynamic_links(ctx):
            # Skip versioned forms, they are only necessary for symlinks to resolve correctly.
            if l2l.dynamic_library.basename.endswith(".dylib"):
                stripped = l2l.dynamic_library.basename[:-len(".dylib")]
                if "." in stripped and stripped[-1].isdigit():
                    continue
            elif ".so." in l2l.dynamic_library.basename:
                continue
            dynamic_libs.append(l2l.dynamic_library)

    for rust_dep in rust_deps:
        if rust_dep.crate_type == "staticlib":
            pic_libs.append(rust_dep.rust_lib)
        elif rust_dep.crate_type == "cdylib":
            if allow_dynamic_links(ctx):
                dynamic_libs.append(rust_dep.rust_lib)
            else:
                fail("Dynamic linking is not allowed: {}".format(rust_dep.name))
        else:
            fail("Only cdylib and staticlib rust libraries are supported: {}".format(rust_dep.name))

    command_args.add_all(pic_libs, before_each = "--extra-lib")
    inputs_direct.extend(pic_libs)
    command_args.add_all(dynamic_libs, before_each = "--extra-dynamic-lib")
    inputs_direct.extend(dynamic_libs)

    for framework in frameworks:
        command_args.add_all(framework.framework_dirs, before_each = "--extra-framework")
        inputs_trans.append(framework.framework_files)
    for link_flag in cc_linking.user_link_flags:
        if link_flag == "-pthread":
            # Python is going to add this anyway.
            continue

        # On Windows, specific link inputs are passed in as command arguments to
        # link.exe and are not passed in as flags. We assume these to be Bazel-built
        # inputs, and should be handled the same as libraries.
        if not link_flag.startswith("-l") and not is_windows(ctx):
            fail("only know how to handle -l linkopts, not '{}'".format(link_flag))
        command_args.add(link_flag, format = "--extra-lib=%s")

    command_args.add_all(ctx.attr.extra_path, before_each = "--extra-path")

    for option in ctx.attr.global_options:
        command_args.add(
            ctx.expand_make_variables("cmd", ctx.expand_location(option), {"ROOT": ROOT_PLACEHOLDER}),
            format = "--global-option=%s",
        )
    command_args.add_all(ctx.attr.build_options, format_each = "--build-option=%s")

    build_dep_wheels = []
    for build_dep in ctx.attr.setup_requires:
        versions = build_dep[DbxPyVersionCompatibility]
        if ctx.attr.python2_compatible and not versions.python2_compatible:
            fail("%s is not compatible with Python 2." % (build_dep.label,))
        if ctx.attr.python3_compatible and not versions.python3_compatible:
            fail("%s is not compatible with Python 3." % (build_dep.label,))
        build_dep_wheels.extend(
            [piplib.archive for piplib in build_dep.piplib_contents[build_tag].to_list()],
        )
    command_args.add_all(build_dep_wheels, before_each = "--build-dep")
    inputs_direct.extend(build_dep_wheels)

    if sdist_tar:
        module_base = sdist_tar.path
        inputs_direct.append(sdist_tar)

        # Assume the distribution name is the target name. We could provide an
        # additional attribute if needed.
        dist_name = ctx.label.name
        command_args.add("--local-module-base", module_base)
        command_args.add("--dist-name", dist_name)
        description = ctx.label.package + ":" + dist_name
    else:
        inputs_direct.extend(ctx.files.srcs)
        version_spec = "{}=={}".format(ctx.label.name, ctx.attr.pip_version)
        command_args.add(version_spec)
        description = version_spec

    env = ctx.configuration.default_shell_env
    env.update(link_env)

    genfiles_root = ctx.configuration.genfiles_dir.path + "/" + ctx.label.workspace_root
    for e in ctx.attr.env:
        env[e] = ctx.expand_make_variables("cmd", ctx.expand_location(ctx.attr.env[e], targets = ctx.attr.tools), {
            "ROOT": ROOT_PLACEHOLDER,
            "GENFILES_ROOT": ROOT_PLACEHOLDER + "/" + genfiles_root,
        })

    if ctx.attr.use_magic_mirror:
        command_args.add("--index-url", PYPI_MIRROR_URL)

    command_args.add(ROOT_PLACEHOLDER, format = "--root-placeholder=%s")

    if not ctx.attr.ignore_missing_static_libraries and not allow_dynamic_links(ctx):
        fail("May not disable ignore_missing_static_libraries when dynamic links are not allowed.")

    if ctx.attr.ignore_missing_static_libraries:
        command_args.add("--ignore-missing-static-libraries")

    if is_windows(ctx):
        command_args.add("--ducible", ctx.file._ducible)
        tools.append(ctx.file._ducible)

    ctx.actions.run(
        inputs = depset(direct = inputs_direct, transitive = inputs_trans),
        tools = tools,
        outputs = outputs,
        mnemonic = "PyPip",
        env = env,
        executable = ctx.executable._vpip_tool,
        arguments = [command_args],
        progress_message = "fetch/build {} for {}".format(description, build_tag),
    )

    extracted_dir = ctx.actions.declare_directory(ctx.label.name + "-" + build_tag + "/lib")
    install_args = ctx.actions.args()
    install_args.add("install")
    install_args.add_all(ctx.attr.py_excludes, before_each = "--exclude")
    install_args.add_all(ctx.attr.namespace_pkgs, before_each = "--namespace_pkg")
    if toolchain.pyc_compilation_enabled:
        install_args.add("--pyc_python", python_interp.path)
        install_args.add("--pyc_compiler", toolchain.pyc_compile_exe)
        if python_interp.major_python_version != 2:
            install_args.add("--pyc_build_tag", build_tag)
    install_args.add(wheel)
    install_args.add(extracted_dir.path)
    install_args.add(extracted_dir.short_path)
    ctx.actions.run(
        inputs = depset(direct = [wheel], transitive = [python_interp.runtime]),
        tools = [toolchain.pyc_compile_files_to_run] if toolchain.pyc_compilation_enabled else [],
        outputs = [extracted_dir],
        executable = ctx.executable._vinst,
        use_default_shell_env = True,
        arguments = [install_args],
        mnemonic = "PyExtractWheel",
    )

    piplib_contents = struct(
        archive = wheel,
        extracted_dir = extracted_dir,
        namespace_pkgs = ctx.attr.namespace_pkgs,
        label = ctx.label,
    )

    if ctx.attr.pip_main:
        main = ctx.actions.declare_file(ctx.label.name + "-" + build_tag + "/bin/" + ctx.attr.pip_main.split("/")[-1])
        main_args = ctx.actions.args()
        main_args.add("script")
        main_args.add(wheel)
        main_args.add(ctx.attr.pip_main)
        main_args.add(main)
        ctx.actions.run(
            inputs = [wheel],
            tools = [],
            outputs = [main],
            executable = ctx.executable._vinst,
            use_default_shell_env = True,
            arguments = [main_args],
            mnemonic = "PyExtractScript",
        )
    else:
        main = None

    return struct(
        piplib_contents = depset([piplib_contents]),
        pip_main = main,
    ), dynamic_libs, frameworks

def _vpip_rule_impl(ctx, local):
    if local and NON_THIRDPARTY_PACKAGE_PREFIXES:
        thirdparty_package = not any([
            ctx.label.package == prefix or ctx.label.package.startswith(prefix + "/")
            for prefix in NON_THIRDPARTY_PACKAGE_PREFIXES
        ])
        pip_version = hasattr(ctx.attr, "pip_version") and ctx.attr.pip_version.strip()
        if (not thirdparty_package and pip_version):
            fail('non-thirdparty local piplib should not specify "pip_version"')
        elif (thirdparty_package and not pip_version):
            fail('thirdparty local piplib should specify its version using "pip_version"')

    (
        pyc_files_by_build_tag,
        piplib_contents,
        extra_pythonpath,
        dynamic_libraries_trans,
        frameworks_trans,
    ) = collect_transitive_srcs_and_libs(
        ctx,
        deps = ctx.attr.deps,
        data = ctx.attr.data,
        pip_version = ctx.attr.pip_version,
        python2_compatible = ctx.attr.python2_compatible,
        python3_compatible = ctx.attr.python3_compatible,
        is_local_piplib = local,
    )
    required_piplibs = depset(transitive = [collect_required_piplibs(ctx.attr.deps)], direct = [ctx.label.name])

    if not ctx.attr.use_magic_mirror:
        print("Magic mirror is not being used for %s. This should only be used during local testing or 'bzl gen'. use_magic_mirror=False should not be checked in." % (ctx.label,))

    pip_main = {}
    py_configs = _get_build_interpreters_for_target(ctx)
    valid_build_tags = []
    sdist_tar = None
    if local:
        sdist_tar = _build_sdist_tar(ctx)
    for py_config in py_configs:
        python_impl = py_config.target
        wheel = getattr(ctx.outputs, py_config.attr)
        wheel_out, dynamic_libraries, frameworks = _build_wheel(ctx, wheel, python_impl, sdist_tar)
        pip_main[py_config.build_tag] = wheel_out.pip_main
        piplib_contents[py_config.build_tag] = depset(
            transitive = [piplib_contents[py_config.build_tag], wheel_out.piplib_contents],
        )
        valid_build_tags.append(py_config.build_tag)

    return struct(
        providers = [
            DbxPyVersionCompatibility(
                python2_compatible = ctx.attr.python2_compatible,
                python3_compatible = ctx.attr.python3_compatible,
            ),
        ],
        pip_main = pip_main,
        provides = ctx.attr.provides,
        piplib_contents = piplib_contents,
        dynamic_libraries = depset(direct = dynamic_libraries, transitive = [dynamic_libraries_trans]),
        frameworks = depset(direct = frameworks, transitive = [frameworks_trans]),
        extra_pythonpath = extra_pythonpath,
        runfiles = ctx.runfiles(collect_default = True),
        required_piplibs = required_piplibs,
    )

def _vpip_outputs(name, python2_compatible, python3_compatible):
    outs = {}
    name = name.replace("-", "_")
    whl_file_tmpl = "{name}-{build_tag}/{name}-0.0.0-py2.py3-none-any.whl"
    py_configs = _get_build_interpreters_for_macro(
        python2_compatible = python2_compatible,
        python3_compatible = python3_compatible,
    )
    for py_config in py_configs:
        whl_file = whl_file_tmpl.format(name = name, build_tag = py_config.build_tag)
        outs[py_config.attr] = whl_file
    return outs

def _dbx_py_pypi_piplib_impl(ctx):
    return _vpip_rule_impl(ctx, False)

def _dbx_py_local_piplib_impl(ctx):
    return _vpip_rule_impl(ctx, True)

def _find_package_root(files):
    """
    In some cases the srcs may start with a subdirectory. So we find the setup.py/pyproject.toml
    with the shortest path and use its directory. We want the shortest path to
    handle cases where the package has vendorized its dependencies.
    """
    package_dir = None
    setup_pys = [
        f
        for f in files
        if f.basename in ("setup.py", "pyproject.toml")
    ]
    if not setup_pys:
        fail("setup.py/pyproject.toml not found")

    package_dir = None
    for f in setup_pys:
        # Shed prefix ("bazel-out/...") in case the file is from a genrule.
        normalized_dirname = f.dirname[len(f.root.path):].lstrip("/")
        if package_dir == None or len(package_dir) > len(normalized_dirname):
            package_dir = normalized_dirname

    return package_dir

def _build_sdist_tar(ctx):
    """
    Create a sdist tar file

    Building a sdist tar file allows pip/setuptools to only see the files listed
    in srcs. In addition because vpip cleans its workdir each run old source
    files and build artifacts will not accumulate.
    """
    sdist_tar = ctx.actions.declare_file("{}-sdist.tar".format(ctx.label.name))

    all_files = ctx.files.srcs

    package_root = _find_package_root(all_files)
    start_idx = len(package_root) + 1

    manifest_file = ctx.actions.declare_file("{}-manifest".format(ctx.label.name))

    sdist_args = ctx.actions.args()

    manifest_struct = struct(files = [])
    required_files = []
    for inf in all_files:
        normalized_path = inf.path[len(inf.root.path):].lstrip("/")
        if normalized_path.startswith(package_root):
            dst_path = normalized_path[start_idx:]
            manifest_struct.files.append(struct(src = inf.path, dst = dst_path))
            required_files.append(inf)
    ctx.actions.write(
        output = manifest_file,
        content = manifest_struct.to_json(),
    )

    sdist_args.add("--output", sdist_tar)

    # Remove the "./" default prefix.
    sdist_args.add("--root_directory=")
    sdist_args.add("--manifest", manifest_file)
    sdist_args.add("--owner", "65534.65534")
    ctx.actions.run(
        inputs = required_files + [manifest_file],
        outputs = [sdist_tar],
        executable = ctx.executable._tar_tool,
        use_default_shell_env = True,
        arguments = [sdist_args],
        mnemonic = "SdistTar",
        progress_message = "Building source dist tar " + sdist_tar.path,
    )
    return sdist_tar

_piplib_attrs = {
    "srcs": attr.label_list(allow_files = True),
    "deps": attr.label_list(allow_files = True),
    "data": attr.label_list(allow_files = True),
    "global_options": attr.string_list(),
    "build_options": attr.string_list(),
    "extra_path": attr.string_list(),
    "pip_main": attr.string(),
    "provides": attr.string_list(),
    "py_excludes": attr.string_list(default = ["test", "tests", "testing", "SelfTest", "Test", "Tests"]),
    "python2_compatible": attr.bool(default = True),
    "python3_compatible": attr.bool(default = True),
    "env": attr.string_dict(),
    "ignore_missing_static_libraries": attr.bool(
        default = True,
        doc = """Ignore library flags that can't be linked statically.

Can only be set to False when linking dynamic libraries is allowed (_py_link_dynamic_libs).""",
    ),
    "use_pep517": attr.bool(
        default = False,
        doc = """Use a new, PEP 517-defined installation style instead of the legacy, setup.py-based
one. Note, it does not support 'global_options' and 'build_options' arguments.""",
    ),
    "_vpip_tool": attr.label(executable = True, default = Label("//build_tools/py:vpip"), cfg = "host"),
    "use_magic_mirror": attr.bool(default = True),
    "_debug_prefix_map_supported": attr.label(default = Label("//build_tools:py_debug_prefix_map_supported")),
    "_py_link_dynamic_libs": attr.label(default = Label("//build_tools:py_link_dynamic_libs")),
    "_vinst": attr.label(default = Label("//build_tools/py:vinst"), cfg = "host", executable = True),
    "_cc_toolchain": attr.label(default = Label("@bazel_tools//tools/cpp:current_cc_toolchain")),
    "_ducible": attr.label(default = Label("@ducible//:ducible.exe"), allow_single_file = True),
    "_linux_platform": attr.label(default = Label("@platforms//os:linux")),
    "_macos_platform": attr.label(default = Label("@platforms//os:macos")),
    "_windows_platform": attr.label(default = Label("@platforms//os:windows")),
}

_pypi_piplib_attrs = dict(_piplib_attrs)
_pypi_piplib_attrs.update({
    "pip_version": attr.string(mandatory = True),
    "copts": attr.string_list(),
    "namespace_pkgs": attr.string_list(),
    "setup_requires": attr.label_list(providers = ["piplib_contents", DbxPyVersionCompatibility]),
    "tools": attr.label_list(cfg = "host"),
})

dbx_py_pypi_piplib_internal = rule(
    implementation = _dbx_py_pypi_piplib_impl,
    outputs = _vpip_outputs,
    attrs = _pypi_piplib_attrs,
    toolchains = ALL_TOOLCHAIN_NAMES,
    fragments = ["cpp"],
)

_local_piplib_attrs = dict(_piplib_attrs)
_local_piplib_attrs.update({
    "copts": attr.string_list(),
    "namespace_pkgs": attr.string_list(),
    "pip_version": attr.string(),
    "setup_requires": attr.label_list(providers = ["piplib_contents", DbxPyVersionCompatibility]),
    "tools": attr.label_list(cfg = "host"),
    "_tar_tool": attr.label(default = Label("@rules_pkg//:build_tar"), cfg = "host", executable = True),
})

dbx_py_local_piplib_internal = rule(
    implementation = _dbx_py_local_piplib_impl,
    outputs = _vpip_outputs,
    attrs = _local_piplib_attrs,
    fragments = ["cpp"],
    toolchains = ALL_TOOLCHAIN_NAMES,
)

def get_default_py_toolchain_name(python2_compatible):
    if not python2_compatible:
        return BUILD_TAG_TO_TOOLCHAIN_MAP[PY3_DEFAULT_BINARY_ABI.build_tag]
    return CPYTHON_27_TOOLCHAIN_NAME

def _dbx_py_binary_impl(ctx):
    return dbx_py_binary_base_impl(ctx, internal_bootstrap = False)

def _dbx_py_internal_bootstrap_binary_impl(ctx):
    return dbx_py_binary_base_impl(ctx, internal_bootstrap = True)

def dbx_py_binary_base_impl(ctx, internal_bootstrap = False, ext_modules = None):
    # Get the toolchain name for either the bootstrap or normal py
    # toolchain. Both toolchains have `interpreter` defined as the
    # same attribute.
    if internal_bootstrap:
        python = None
        build_tag = None
    else:
        if ctx.attr.python:
            toolchain_name = get_py_toolchain_name(ctx.attr.python)
        else:
            toolchain_name = get_default_py_toolchain_name(ctx.attr.python2_compatible)

        python = ctx.toolchains[toolchain_name].interpreter[DbxPyInterpreter]
        build_tag = python.build_tag

    if ctx.files.main:
        main = ctx.files.main[0]
        if main not in ctx.files.srcs:
            fail("main must be in srcs")
    elif ctx.attr.pip_main:
        if internal_bootstrap:
            fail("dbx_py_internal_bootstrap can't have a \"pip_main\" attribute.")
        if not ctx.attr.pip_main.pip_main:
            fail("{} missing pip_main".format(ctx.attr.pip_main.label))
        if build_tag not in ctx.attr.pip_main.pip_main:
            fail("{} not built for {}".format(ctx.attr.pip_main.label, build_tag))
        main = ctx.attr.pip_main.pip_main[build_tag]
    else:
        fail('dbx_py_binary requires one of "main" or "pip_main" attributes')

    if ctx.attr.pythonpath:
        pythonpath = ctx.attr.pythonpath
    else:
        pythonpath = workspace_root_to_pythonpath(ctx.label.workspace_root)

    # On Windows, we need to end our files with ".bat", to tell Windows how to
    # execute it.
    if is_windows(ctx):
        output_name = ctx.attr.name + ".bat"
    else:
        output_name = ctx.attr.name
    output_file = ctx.actions.declare_file(output_name)

    runfiles, extra_pythonpath, hidden_output = emit_py_binary(
        ctx,
        main = main,
        srcs = ctx.files.srcs,
        out_file = output_file,
        pythonpath = ctx.attr.pythonpath,
        deps = ctx.attr.deps,
        data = ctx.attr.data,
        ext_modules = ext_modules,
        python = python,
        internal_bootstrap = internal_bootstrap,
        python2_compatible = ctx.attr.python2_compatible,
        python3_compatible = ctx.attr.python3_compatible,
    )
    runfiles = runfiles.merge(ctx.runfiles(collect_default = True))
    return struct(
        executable = output_file,
        runfiles = runfiles,
        extra_pythonpath = extra_pythonpath,
        providers = [
            coverage_common.instrumented_files_info(
                ctx,
                dependency_attributes = ["deps", "extra_instrumented"],
            ),
            OutputGroupInfo(
                _hidden_top_level_INTERNAL_ = hidden_output,
            ),
        ],
    )

_dbx_py_binary_base_attrs = {
    "main": attr.label(allow_files = True),
    "srcs": attr.label_list(allow_files = py_file_types),
    "stub_srcs": attr.label_list(allow_files = pyi_file_types),  # For mypy
    "pip_main": attr.label(providers = ["pip_main"], allow_files = False),
    "deps": attr.label_list(providers = [[PyInfo], [DbxPyVersionCompatibility]]),
    "autogen_deps": attr.bool(default = True),
    "validate": attr.string(default = "warn", mandatory = False, values = ["strict", "warn", "ignore", "allow-unused"]),
    "data": attr.label_list(allow_files = True),
    "pythonpath": attr.string(),
    "extra_args": attr.string_list(),
    "python2_compatible": attr.bool(default = True),
    "python3_compatible": attr.bool(default = True),
    "python": attr.string(values = BUILD_TAG_TO_TOOLCHAIN_MAP.keys() + [""]),
}
_dbx_py_binary_base_attrs.update(runfiles_attrs)
_dbx_py_binary_base_attrs.update({
    "_blank_py_binary": attr.label(
        default = Label("//build_tools/py:blank_py_binary"),
        cfg = "host",
    ),
})

# A dbx_py_binary rule that doesn't depend on _dbx_compile.
_dbx_internal_bootstrap_py_binary_attrs = dict(_dbx_py_binary_base_attrs)
dbx_internal_bootstrap_py_binary = rule(
    implementation = _dbx_py_internal_bootstrap_binary_impl,
    attrs = _dbx_internal_bootstrap_py_binary_attrs,
    executable = True,
    doc = """
Constructs a bootstrap Python binary.

Bootstrap Python binaries don't contain dependencies on the Python
toolchain, so they can be included on the toolchain directly. For more
information on how to use a bootstrap binary, see the dbx_py_toolchain
doc.
    """,
)

dbx_py_binary_attrs = dict(_dbx_py_binary_base_attrs)
dbx_py_binary_attrs.update(py_binary_attrs)
dbx_py_binary = rule(
    implementation = _dbx_py_binary_impl,
    attrs = dbx_py_binary_attrs,
    toolchains = ALL_TOOLCHAIN_NAMES,
    executable = True,
)
dbx_py_test_attrs = dict(dbx_py_binary_attrs)
dbx_py_test_attrs.update({
    "quarantine": attr.string_dict(),
    # List of targets other than srcs and deps that need to be instrumented to capture coverage.
    # Note, it is test responsibility to copy or merge coverage data. Currently only dbx_docker_test
    # supports that.
    "extra_instrumented": attr.label_list(),
})

dbx_py_test = rule(
    implementation = _dbx_py_binary_impl,
    toolchains = ALL_TOOLCHAIN_NAMES,
    test = True,
    attrs = dbx_py_test_attrs,
)

# Wrapper around dbx_py_test that handles the quarantine attr correctly.
# In general, this macro should be used instead of dbx_py_test (otherwise, targets
# not be quarantinable).
def dbx_py_dbx_test(
        quarantine = {},
        tags = [],
        **kwargs):
    tags = (tags or []) + process_quarantine_attr(quarantine)
    dbx_py_test(
        quarantine = quarantine,
        tags = tags,
        **kwargs
    )

def _gen_import_test(
        build_interpreters,
        name,
        provides,
        python2_compatible,
        python3_compatible,
        **kwargs):
    for py_config in build_interpreters:
        dbx_py_dbx_test(
            name = name + "_" + py_config.build_tag + "_import_test",
            main = Label("//build_tools/py:import_check.py"),
            srcs = [Label("//build_tools/py:import_check.py")],
            extra_args = provides,
            deps = [name],
            python = py_config.build_tag,
            size = "small",
            python2_compatible = python2_compatible,
            python3_compatible = python3_compatible,
            **kwargs
        )

def _get_build_interpreters_for_macro(python2_compatible, python3_compatible):
    attrs = struct(
        python2_compatible = python2_compatible,
        python3_compatible = python3_compatible,
    )
    return _get_build_interpreters(attrs)

def dbx_py_pypi_piplib(
        name,
        provides = None,
        hidden_provides = None,
        import_test_tags = None,
        python2_compatible = True,
        python3_compatible = True,
        **kwargs):
    if provides == None:
        # If no explicit 'provides' attribute is specified, default to using the target name itself.
        if hidden_provides == None:
            provides = [name]
        else:
            provides = []

    if hidden_provides:
        provides += hidden_provides

    dbx_py_pypi_piplib_internal(
        name = name,
        provides = provides,
        python2_compatible = python2_compatible,
        python3_compatible = python3_compatible,
        **kwargs
    )
    _gen_import_test(
        _get_build_interpreters_for_macro(python2_compatible, python3_compatible),
        name,
        provides,
        python2_compatible = python2_compatible,
        python3_compatible = python3_compatible,
        tags = import_test_tags,
    )

def dbx_py_local_piplib(
        name,
        provides = None,
        hidden_provides = None,
        import_test_tags = None,
        python2_compatible = True,
        python3_compatible = True,
        **kwargs):
    if provides == None:
        # If no explicit 'provides' attribute is specified, default to using the target name itself.
        if hidden_provides == None:
            provides = [name]
        else:
            provides = []

    if hidden_provides:
        provides += hidden_provides

    dbx_py_local_piplib_internal(
        name = name,
        provides = provides,
        python2_compatible = python2_compatible,
        python3_compatible = python3_compatible,
        **kwargs
    )
    _gen_import_test(
        _get_build_interpreters_for_macro(python2_compatible, python3_compatible),
        name,
        provides,
        python2_compatible = python2_compatible,
        python3_compatible = python3_compatible,
        tags = import_test_tags,
    )

def dbx_py_piplib_alias(name, provides = None, **kwargs):
    native.alias(name = name, **kwargs)

dbx_py_library_attrs = {
    "data": attr.label_list(allow_files = True),
    "deps": attr.label_list(providers = [[PyInfo], [DbxPyVersionCompatibility]]),
    "autogen_deps": attr.bool(default = True),
    "srcs": attr.label_list(allow_files = py_file_types),
    "stub_srcs": attr.label_list(allow_files = pyi_file_types),  # For mypy
    "pythonpath": attr.string(),
    "python2_compatible": attr.bool(default = True),
    "python3_compatible": attr.bool(default = True),
    "validate": attr.string(default = "strict", mandatory = False, values = ["strict", "warn", "ignore", "allow-unused"]),
    # This is available for a few odd cases like tensorflow and opencv which use
    # a wrapper library to expose a piplib
    "provides": attr.string_list(),
    "compiled": attr.bool(default = False),
}

def _dbx_py_library_impl(ctx):
    (
        pyc_files_by_build_tag,
        piplib_contents,
        extra_pythonpath,
        dynamic_libraries,
        frameworks,
    ) = collect_transitive_srcs_and_libs(
        ctx,
        deps = ctx.attr.deps,
        python2_compatible = ctx.attr.python2_compatible,
        python3_compatible = ctx.attr.python3_compatible,
        is_local_piplib = False,
        data = ctx.attr.data,
        pip_version = None,
    )

    direct_pythonpath = [workspace_root_to_pythonpath(ctx.label.workspace_root)]
    if ctx.attr.pythonpath:
        direct_pythonpath.append(ctx.attr.pythonpath)
    extra_pythonpath = depset(direct = direct_pythonpath, transitive = [extra_pythonpath])

    required_piplibs = collect_required_piplibs(ctx.attr.deps)

    if ctx.files.srcs:
        if ctx.attr.python2_compatible:
            for abi in ALL_ABIS:
                if abi.major_python_version == 2:
                    pyc_files_by_build_tag[abi.build_tag] = depset(
                        direct = compile_pycs(ctx, ctx.files.srcs, abi),
                        transitive = [pyc_files_by_build_tag[abi.build_tag]],
                    )
        if ctx.attr.python3_compatible:
            for abi in ALL_ABIS:
                if abi.major_python_version == 3:
                    pyc_files_by_build_tag[abi.build_tag] = depset(
                        direct = compile_pycs(ctx, ctx.files.srcs, abi),
                        transitive = [pyc_files_by_build_tag[abi.build_tag]],
                    )

    return struct(
        providers = [
            coverage_common.instrumented_files_info(ctx, source_attributes = ["srcs"]),
            DbxPyVersionCompatibility(
                python2_compatible = ctx.attr.python2_compatible,
                python3_compatible = ctx.attr.python3_compatible,
            ),
        ],
        piplib_contents = piplib_contents,
        dynamic_libraries = dynamic_libraries,
        frameworks = frameworks,
        pyc_files_by_build_tag = pyc_files_by_build_tag,
        extra_pythonpath = extra_pythonpath,
        required_piplibs = required_piplibs,
        runfiles = ctx.runfiles(
            files = ctx.files.srcs,
            collect_default = True,
        ),
    )

dbx_py_library = rule(
    implementation = _dbx_py_library_impl,
    attrs = dbx_py_library_attrs,
    toolchains = ALL_TOOLCHAIN_NAMES,
)

def extract_pytest_args(
        args = [],
        test_root = None,
        plugins = [],
        srcs = [],
        **kwargs):
    if test_root:
        root = test_root + ("/" + native.package_name() if native.package_name() else "")
    else:
        root = "$RUNFILES" + "/" + native.package_name()

    if "main" in kwargs:
        fail("You cannot provide a 'main' to pytest rules.  Use 'srcs' instead.")

    pytest_args = GLOBAL_PYTEST_ARGS + args
    for src in srcs:
        # pytest misbehaves if you pass it __init__.py, so we drop it from the arguments. This means
        # we don't support running tests in __init__.py.
        if src.rpartition("/")[2] == "__init__.py":
            continue
        if src.startswith("//"):
            pytest_args += ["$RUNFILES/" + src[2:].replace(":", "/")]
        elif src.startswith("@"):
            fail("'srcs' can't cross repositories")
        else:
            pytest_args += [root + "/" + src]

    if not pytest_args:
        fail("At least one test source must be provided")

    pytest_args += [
        "--import-mode=append",  # Unfortunately, "don't mess with sys.path" isn't an option.
        # Prevent `$PWD/.cache` from being created, since that is not writable in itest, and in
        # `bazel test` we don't copy it back out, so we're never using the cache.
        "-p",
        "no:cacheprovider",
        "-vvv",
    ]

    for plugin in plugins:
        if not plugin.startswith("//"):
            fail("plugin %r should be a target" % (plugin,))
        plugin_arg = plugin[2:].replace("/", ".").replace(":", ".")
        pytest_args += ["-p", plugin_arg]

    pytest_deps = GLOBAL_PYTEST_PLUGINS + plugins + ["@dbx_build_tools//pip/pytest:pytest_fake"]

    pytest_args += [
        "--junitxml",
        "${XML_OUTPUT_FILE:-/dev/null}",
        # $TESTBRIDGE_TEST_ONLY is set to the exact string sent to `--test_filter`.
        "-k",
        "${TESTBRIDGE_TEST_ONLY:-.}",
        "--maxfail",
        "${TESTBRIDGE_TEST_RUNNER_FAIL_FAST:-0}",
    ]

    return pytest_args, pytest_deps

def dbx_py_pytest_test(
        name,
        deps = [],
        args = [],
        srcs = [],
        size = "small",
        timeout = None,
        services = [],
        # if 'services' is a select, we can't calculate len, this works around
        # by telling the test that there are services. Note that you still can't
        # select between no-services and some-services, but if you know you will
        # have services either way, this works.
        force_services = False,
        start_services = True,
        tags = [],
        test_root = None,
        local = 0,
        flaky = 0,
        quarantine = {},
        python = None,
        plugins = [],
        python2_compatible = True,
        python3_compatible = True,
        visibility = None,
        **kwargs):
    pytest_args, pytest_deps = extract_pytest_args(args, test_root, plugins, srcs, **kwargs)

    tags = tags + process_quarantine_attr(quarantine)

    pythons = []
    if python == None:
        if python2_compatible:
            if python3_compatible:
                variant = "python2"
            else:
                variant = ""
            pythons.append((PY2_TEST_ABI.build_tag, variant))
        if python3_compatible:
            pythons.append((PY3_TEST_ABI.build_tag, ""))
            if not python2_compatible:
                for abi in PY3_ALTERNATIVE_TEST_ABIS:
                    pythons.append((abi.build_tag, abi.build_tag))
    else:
        if (not python2_compatible) or python3_compatible:
            fail('Cannot use a custom "python" attribute and set python(2|3)_compatible.')
        pythons.append((python, ""))

    all_deps = deps + pytest_deps
    for python, variant in pythons:
        if variant:
            extra_args = pytest_args + ["--junitprefix", variant + ":"]
            suffix = "-" + variant
            variant_tags = tags + ["alternative_py_version"]
        else:
            extra_args = pytest_args
            suffix = ""
            variant_tags = tags
        if force_services or len(services) > 0:
            dbx_py_dbx_test(
                name = name + "_bin" + suffix,
                main = "@dbx_build_tools//pip/pytest:main.py",
                srcs = srcs + ["@dbx_build_tools//pip/pytest:main.py"],
                extra_args = extra_args,
                deps = all_deps,
                size = size,
                tags = variant_tags + ["manual"],
                local = local,
                quarantine = quarantine,
                python = python,
                python2_compatible = python2_compatible,
                python3_compatible = python3_compatible,
                visibility = ["//visibility:private"],
                **kwargs
            )
            dbx_services_test(
                name = name + suffix,
                test = name + "_bin" + suffix,
                services = services,
                start_services = start_services,
                local = local,
                size = size,
                timeout = timeout,
                tags = variant_tags,
                flaky = flaky,
                quarantine = quarantine,
                visibility = visibility,
            )
        else:
            dbx_py_dbx_test(
                name = name + suffix,
                main = "@dbx_build_tools//pip/pytest:main.py",
                srcs = srcs + ["@dbx_build_tools//pip/pytest:main.py"],
                extra_args = extra_args,
                deps = all_deps,
                size = size,
                timeout = timeout,
                tags = variant_tags,
                local = local,
                flaky = flaky,
                python = python,
                python2_compatible = python2_compatible,
                python3_compatible = python3_compatible,
                quarantine = quarantine,
                visibility = visibility,
                **kwargs
            )
