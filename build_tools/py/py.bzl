load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load(
    "@bazel_tools//tools/build_defs/cc:action_names.bzl",
    "CPP_COMPILE_ACTION_NAME",
    "CPP_LINK_DYNAMIC_LIBRARY_ACTION_NAME",
)
load("//build_tools/bazel:runfiles.bzl", "runfiles_attrs")
load("//build_tools/bazel:quarantine.bzl", "process_quarantine_attr")
load(
    "@dbx_build_tools//build_tools/py:toolchain.bzl",
    "ALL_ABIS",
    "BUILD_TAG_TO_TOOLCHAIN_MAP",
    "CPYTHON_27_TOOLCHAIN_NAME",
    "CPYTHON_37_TOOLCHAIN_NAME",
    "DbxPyInterpreter",
    "cpython_27",
    "cpython_37",
    "get_default_py_toolchain_name",
    "get_py_toolchain_name",
)
load("//build_tools/services:svc.bzl", "dbx_services_test")
load("//build_tools/py:cfg.bzl", "GLOBAL_PYTEST_ARGS", "GLOBAL_PYTEST_PLUGINS", "PYPI_MIRROR_URL")
load("//build_tools/py:cfg.bzl", "NON_THIRDPARTY_PACKAGE_PREFIXES")
load(
    "//build_tools/py:common.bzl",
    "DbxPyVersionCompatibility",
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

# This logic is duplicated in build_tools/bzl_lib/gen_build_pip.py::_get_build_interpreters and must
# be kept in sync.
def _get_build_interpreters(attr):
    interpreters = []
    if attr.python2_compatible:
        interpreters.append(cpython_27)
    if attr.python3_compatible:
        interpreters.append(cpython_37)
    return interpreters

def _get_build_interpreters_for_target(ctx):
    interpreters = []
    if ctx.attr.python2_compatible:
        interpreters.append(struct(
            build_tag = cpython_27.build_tag,
            target = ctx.toolchains[CPYTHON_27_TOOLCHAIN_NAME].interpreter[DbxPyInterpreter],
            attr = cpython_27.attr,
        ))
    if ctx.attr.python3_compatible:
        interpreters.append(struct(
            build_tag = cpython_37.build_tag,
            target = ctx.toolchains[CPYTHON_37_TOOLCHAIN_NAME].interpreter[DbxPyInterpreter],
            attr = cpython_37.attr,
        ))
    return interpreters

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
        action_name = CPP_COMPILE_ACTION_NAME,
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

def _allow_dynamic_links(ctx):
    return ctx.attr._py_link_dynamic_libs[DbxStringValue].value == "allowed"

def _build_wheel(ctx, wheel, python_interp, sdist_tar):
    build_tag = python_interp.build_tag
    command_args = ctx.actions.args()
    command_args.add("--no-deps")
    command_args.add("--wheel", wheel)
    command_args.add("--python", python_interp.path)
    command_args.add("--build-tag", build_tag)
    outputs = [wheel]

    cc_toolchain = find_cpp_toolchain(ctx)
    _add_vpip_compiler_args(ctx, cc_toolchain, ctx.attr.copts, command_args)

    inputs_direct = []
    inputs_trans = [
        python_interp.runtime,
        python_interp.headers,
        cc_toolchain.all_files,
    ]
    tools_trans = [t.files for t in ctx.attr.tools]

    cc_infos = []
    rust_deps = []
    for dep in ctx.attr.deps:
        # Automatically include header files from any cc_library dependencies
        if CcInfo in dep:
            cc_infos.append(dep[CcInfo])
        elif hasattr(dep, "crate_type"):
            # dep is a rust_library.
            if dep.crate_type != "cdylib":
                fail("Only cdylib rust libraries are supported: {}".format(dep.name))
            rust_deps.append(dep)
        elif not hasattr(dep, "piplib_contents"):
            # Note vpip can't depend on other Python libraries.
            inputs_trans.append(dep.files)
    cc_info = cc_common.merge_cc_infos(cc_infos = cc_infos)
    cc_compilation = cc_info.compilation_context
    cc_linking = cc_info.linking_context
    inputs_trans.append(cc_compilation.headers)
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
        elif l2l.dynamic_library and _allow_dynamic_links(ctx):
            dynamic_libs.append(l2l.dynamic_library)

    if _allow_dynamic_links(ctx):
        for rust_dep in rust_deps:
            dynamic_libs.append(rust_dep.rust_lib)

    command_args.add_all(pic_libs, before_each = "--extra-lib")
    inputs_direct.extend(pic_libs)
    command_args.add_all(dynamic_libs, before_each = "--extra-dynamic-lib")
    inputs_direct.extend(dynamic_libs)
    for link_flag in cc_linking.user_link_flags:
        if link_flag == "-pthread":
            # Python is going to add this anyway.
            continue
        if not link_flag.startswith("-l"):
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

    env = {}
    genfiles_root = ctx.configuration.genfiles_dir.path + "/" + ctx.label.workspace_root
    for e in ctx.attr.env:
        env[e] = ctx.expand_make_variables("cmd", ctx.expand_location(ctx.attr.env[e], targets = ctx.attr.tools), {
            "ROOT": ROOT_PLACEHOLDER,
            "GENFILES_ROOT": ROOT_PLACEHOLDER + "/" + genfiles_root,
        })

    if ctx.attr.use_magic_mirror:
        command_args.add("--index-url", PYPI_MIRROR_URL)

    command_args.add(ROOT_PLACEHOLDER, format = "--root-placeholder=%s")

    if not ctx.attr.ignore_missing_static_libraries and not _allow_dynamic_links(ctx):
        fail("May not disable ignore_missing_static_libraries when dynamic links are not allowed.")

    if ctx.attr.ignore_missing_static_libraries:
        command_args.add("--ignore-missing-static-libraries")

    ctx.actions.run(
        inputs = depset(direct = inputs_direct, transitive = inputs_trans),
        tools = depset(transitive = tools_trans),
        outputs = outputs,
        mnemonic = "PyPip",
        env = env,
        executable = ctx.executable._vpip_tool,
        arguments = [command_args],
        progress_message = "fetch/build {} for {}".format(description, build_tag),
    )

    # contents will be empty when we are building under bzl gen
    if ctx.attr.contents:
        contents = ctx.attr.contents[build_tag]
    else:
        contents = []
    extracted_files = [ctx.actions.declare_file(f, sibling = wheel) for f in contents]
    if contents:  # may be empty if bzl genning
        install_args = ctx.actions.args()
        install_args.add("install")
        install_args.add(wheel)
        install_args.add(wheel.dirname)
        install_args.add_all(contents)
        ctx.actions.run(
            inputs = [wheel],
            tools = [],
            outputs = extracted_files,
            executable = ctx.executable._vinst,
            arguments = [install_args],
            mnemonic = "ExtractWheel",
            progress_message = "ExtractWheel {}".format(wheel.path),
            execution_requirements = {"local": "1"},
        )
        pycs = compile_pycs(
            ctx,
            [f for f in extracted_files if f.extension == "py"],
            build_tag,
            allow_failures = True,  # Thirdparty .py files can contain all manner of brokenness.
        )
        extracted_files.extend(pycs)

    piplib_contents = struct(
        archive = wheel,
        extracted_dir = wheel.dirname,
        extracted_files = depset(direct = extracted_files),
        namespace_pkgs = ctx.attr.namespace_pkgs,
        label = ctx.label,
    )

    if ctx.attr.pip_main:
        main = ctx.actions.declare_file("_bin/" + ctx.attr.pip_main.split("/")[-1], sibling = wheel)
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
            arguments = [main_args],
            progress_message = "extract " + ctx.attr.pip_main,
        )
    else:
        main = None

    return struct(
        piplib_contents = depset([piplib_contents]),
        pip_main = main,
    )

def _vpip_rule_impl(ctx, local):
    if local and NON_THIRDPARTY_PACKAGE_PREFIXES:
        package_prefix, _, _ = ctx.label.package.partition("/")
        pip_version = hasattr(ctx.attr, "pip_version") and ctx.attr.pip_version.strip()
        if (package_prefix in NON_THIRDPARTY_PACKAGE_PREFIXES) and pip_version:
            fail('non-thirdparty local piplib should not specify "pip_version"')
        elif (package_prefix not in NON_THIRDPARTY_PACKAGE_PREFIXES) and not pip_version:
            fail('thirdparty local piplib should specify its version using "pip_version"')

    (
        pyc_files_by_build_tag,
        piplib_contents,
        extra_pythonpath,
        versioned_deps,
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
        wheel_out = _build_wheel(ctx, wheel, python_impl, sdist_tar)
        pip_main[py_config.build_tag] = wheel_out.pip_main
        piplib_contents[py_config.build_tag] = depset(
            transitive = [piplib_contents[py_config.build_tag], wheel_out.piplib_contents],
        )
        valid_build_tags.append(py_config.build_tag)
    for build_tag in ctx.attr.contents:
        if build_tag not in valid_build_tags:
            fail("%r is not a valid build tag" % (build_tag,))

    return struct(
        providers = [
            DbxPyVersionCompatibility(
                python2_compatible = ctx.attr.python2_compatible,
                python3_compatible = ctx.attr.python3_compatible,
            ),
        ],
        pip_main = pip_main,
        versioned_deps = versioned_deps,
        provides = ctx.attr.provides,
        piplib_contents = piplib_contents,
        extra_pythonpath = extra_pythonpath,
        runfiles = ctx.runfiles(collect_default = True),
        required_piplibs = required_piplibs,
    )

def _vpip_outputs(name, python2_compatible, python3_compatible):
    outs = {}
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
    In some cases the srcs may start with a subdirectory. So we find the setup.py
    with the shortest path and use its directory. We want the shortest path to
    handle cases where the package has vendorized its dependencies.
    """
    package_dir = None
    setup_pys = [
        f
        for f in files
        if f.basename == "setup.py"
    ]
    if not setup_pys:
        fail("setup.py not found")

    # This is the Starlark way to write min(seq, key=lambda x: len(x))
    package_dir = setup_pys[0].dirname
    for f in setup_pys:
        if len(package_dir) > len(f.dirname):
            package_dir = f.dirname

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

    required_files = [
        f
        for f in all_files
        if f.path.startswith(package_root)
    ]

    manifest_file = ctx.actions.declare_file("{}-manifest".format(ctx.label.name))
    ctx.actions.write(
        output = manifest_file,
        content = "\n".join([
            f.path[start_idx:]
            for f in required_files
        ]),
    )

    sdist_args = ctx.actions.args()
    sdist_args.add(sdist_tar)
    sdist_args.add(package_root)
    sdist_args.add(manifest_file)

    ctx.actions.run_shell(
        inputs = required_files + [manifest_file],
        tools = [],
        outputs = [sdist_tar],
        command = "tar -cf $1 --mtime=2018-11-11 -h --mode=go=rX,u+rw --numeric-owner --owner=65534 --group=65534 --directory $2 --files-from $3",
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
    "py_excludes": attr.string_list(),  # used by bzl gen
    "python2_compatible": attr.bool(default = True),
    "python3_compatible": attr.bool(default = True),
    "env": attr.string_dict(),
    "ignore_missing_static_libraries": attr.bool(
        default = True,
        doc = """Ignore library flags that can't be linked statically.

Can only be set to False when linking dynamic libraries is allowed (_py_link_dynamic_libs).""",
    ),
    "_vpip_tool": attr.label(executable = True, default = Label("//build_tools/py:vpip"), cfg = "host"),
    "use_magic_mirror": attr.bool(default = True),
    "_py_link_dynamic_libs": attr.label(default = Label("//build_tools:py_link_dynamic_libs")),
    "_vinst": attr.label(default = Label("//build_tools/py:vinst"), cfg = "host", executable = True),
    "_cc_toolchain": attr.label(default = Label("@bazel_tools//tools/cpp:current_cc_toolchain")),
}

_pypi_piplib_attrs = dict(_piplib_attrs)
_pypi_piplib_attrs.update({
    "pip_version": attr.string(mandatory = True),
    "contents": attr.string_list_dict(),
    "copts": attr.string_list(),
    "namespace_pkgs": attr.string_list(),
    "setup_requires": attr.label_list(providers = ["piplib_contents", DbxPyVersionCompatibility]),
    "tools": attr.label_list(cfg = "host"),
})

dbx_py_pypi_piplib_internal = rule(
    implementation = _dbx_py_pypi_piplib_impl,
    outputs = _vpip_outputs,
    attrs = _pypi_piplib_attrs,
    toolchains = [CPYTHON_27_TOOLCHAIN_NAME, CPYTHON_37_TOOLCHAIN_NAME],
    fragments = ["cpp"],
)

_local_piplib_attrs = dict(_piplib_attrs)
_local_piplib_attrs.update({
    "copts": attr.string_list(),
    "contents": attr.string_list_dict(),
    "namespace_pkgs": attr.string_list(),
    "pip_version": attr.string(),
    "setup_requires": attr.label_list(providers = ["piplib_contents", DbxPyVersionCompatibility]),
    "tools": attr.label_list(cfg = "host"),
})

dbx_py_local_piplib_internal = rule(
    implementation = _dbx_py_local_piplib_impl,
    outputs = _vpip_outputs,
    attrs = _local_piplib_attrs,
    fragments = ["cpp"],
    toolchains = [CPYTHON_27_TOOLCHAIN_NAME, CPYTHON_37_TOOLCHAIN_NAME],
)

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

    runfiles, extra_pythonpath, hidden_output = emit_py_binary(
        ctx,
        main = main,
        srcs = ctx.files.srcs,
        out_file = ctx.outputs.executable,
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
    toolchains = [CPYTHON_27_TOOLCHAIN_NAME, CPYTHON_37_TOOLCHAIN_NAME],
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
    toolchains = [CPYTHON_27_TOOLCHAIN_NAME, CPYTHON_37_TOOLCHAIN_NAME],
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
        versioned_deps,
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
            pyc_files_by_build_tag[cpython_27.build_tag] = depset(
                direct = compile_pycs(ctx, ctx.files.srcs, cpython_27.build_tag),
                transitive = [pyc_files_by_build_tag[cpython_27.build_tag]],
            )
        if ctx.attr.python3_compatible:
            for abi in ALL_ABIS:
                if abi.build_tag != cpython_27.build_tag:
                    pyc_files_by_build_tag[abi.build_tag] = depset(
                        direct = compile_pycs(ctx, ctx.files.srcs, abi.build_tag),
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
        versioned_deps = versioned_deps,
        piplib_contents = piplib_contents,
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
    toolchains = [CPYTHON_27_TOOLCHAIN_NAME, CPYTHON_37_TOOLCHAIN_NAME],
)

def extract_pytest_args(
        args = [],
        test_root = None,
        plugins = [],
        **kwargs):
    if test_root:
        root = test_root + ("/" + native.package_name() if native.package_name() else "")
    else:
        root = "$RUNFILES" + "/" + native.package_name()

    if "main" in kwargs:
        fail("You cannot provide a 'main' to pytest rules.  Use 'srcs' instead.")

    pytest_args = GLOBAL_PYTEST_ARGS + args
    for src in kwargs["srcs"]:
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
    ]

    return pytest_args, pytest_deps

def dbx_py_pytest_test(
        name,
        deps = [],
        args = [],
        size = "small",
        services = [],
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
    pytest_args, pytest_deps = extract_pytest_args(args, test_root, plugins, **kwargs)

    tags = tags + process_quarantine_attr(quarantine)

    pythons = []
    if python == None:
        if python2_compatible:
            if python3_compatible:
                variant = "python2"
            else:
                variant = ""
            pythons.append((cpython_27.build_tag, variant))
        if python3_compatible:
            pythons.append((cpython_37.build_tag, ""))
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
        if len(services) > 0:
            dbx_py_dbx_test(
                name = name + "_bin" + suffix,
                pip_main = "@dbx_build_tools//pip/pytest",
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
                tags = variant_tags,
                flaky = flaky,
                quarantine = quarantine,
                visibility = visibility,
            )
        else:
            dbx_py_dbx_test(
                name = name + suffix,
                pip_main = "@dbx_build_tools//pip/pytest",
                extra_args = extra_args,
                deps = all_deps,
                size = size,
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
