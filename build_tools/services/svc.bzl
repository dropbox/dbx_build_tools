load("//build_tools/bazel:runfiles.bzl", "runfiles_attrs", "write_runfiles_tmpl")
load(
    "//build_tools/py:common.bzl",
    "ALL_TOOLCHAIN_NAMES",
    "DbxPyVersionCompatibility",
    "emit_py_binary",
    "py_binary_attrs",
    "py_file_types",
)
load(
    "//build_tools/py:toolchain.bzl",
    "BUILD_TAG_TO_TOOLCHAIN_MAP",
    "DbxPyInterpreter",
    "cpython_27",
)

DbxServicePyBinaryExtension = provider(fields = [
    "service",
    "main",
    "lib",
    "python",
    "allow_missing",  # allow the service referenced by this extension to be missing
])

DbxServiceDefinitionExtension = provider(fields = [
    "service",  # service this extension is targeting
    "deps",  # additional dependency to bring in to this service
    "data",  # additional data to bring in to this service
    "version_file",  # additional version_file for this service
    "extensions",  # extensions provided transitively by the deps
    "services",  # mapping of all service definitions in this deps
    "health_checks",  # extra health checks for this service
    "args",  # extra arguments for this service
    "allow_missing",  # allow the service referenced by this extension to be missing
])

DbxServiceExtensionArgsProvider = provider(fields = ["args"])

execute_runfiles_cmd_tmpl = '''
exec $RUNFILES/{service_launcher} {launcher_args} --svc.service-defs=$RUNFILES/{service_definitions} --svc.service-defs-version-file=$RUNFILES/{service_defs_version_file} {extra_args} "$@"
'''

_svcd_tool_attr = attr.label(
    cfg = "target",
    default = Label("//go/src/dropbox/build_tools/svcctl/cmd/svcd:svcd_norace"),
    executable = True,
)

_svcinit_tool_attr = attr.label(
    cfg = "target",
    default = Label("//go/src/dropbox/build_tools/svcctl/cmd/svcinit:svcinit_norace"),
    executable = True,
)

_svc_verbose_choices = {
    str(Label("//build_tools:services-verbose")): True,
    str(Label("//build_tools:noservices-verbose")): False,
    "//conditions:default": False,
}

_svc_create_version_file_choices = {
    str(Label("//build_tools:services-version-file")): True,
    str(Label("//build_tools:noservices-version-file")): False,
    "//conditions:default": True,
}

# keep in sync with //configs/proto/dropbox/proto/build_tools/svclib/service.proto
HEALTH_CHECK_TYPE_CMD = 1
HEALTH_CHECK_TYPE_HTTP = 5

def _create_version_file(ctx, inputs, output):
    if ctx.attr.create_version_file:
        ctx.actions.run_shell(
            inputs = inputs,
            tools = [],  # Ensure inputs in the host configuration are not treated specially.
            outputs = [output],
            command = "/bin/date --rfc-3339=seconds > {}".format(
                output.path,
            ),
            mnemonic = "SvcVersionFile",
            # disable remote cache and sandbox, since the output is not stable given the inputs
            # additionally, running this action in the sandbox is way too expensive
            execution_requirements = {"local": "1"},
        )
    else:
        ctx.actions.write(
            output = output,
            content = "NEVER CHANGING",
        )

def _to_proto(services):
    if services:
        return proto.encode_text(struct(services = list(services)))

def _extension_sort_key(ext):
    return ext.label

def _apply_service_extensions(ctx, services, extensions):
    service_version_files = dict()
    service_exe = dict()
    service_exe_args = dict()
    service_deps = dict()
    service_data = dict()
    service_health_checks = dict()
    for service in services:
        service_version_files[service.service_name] = [service.version_file]
        service_exe[service.service_name] = service.launch_cmd.exe
        service_exe_args[service.service_name] = list(service.launch_cmd.args)
        service_deps[service.service_name] = list(service.dependencies)
        service_health_checks[service.service_name] = list(service.health_checks)

    all_runfiles = ctx.runfiles()

    py_binary_info = dict()
    for ext in extensions.to_list():
        if DbxServicePyBinaryExtension in ext:
            info = ext[DbxServicePyBinaryExtension]
            if info.service not in service_exe:
                if info.allow_missing:
                    continue
                fail("Extension target service {} which is not in the dependency tree".format(info.service))
            if info.service not in py_binary_info:
                # Make up the python3/python2 compatibility based on the selected python interpreter.
                if info.python == cpython_27.build_tag:
                    python2_compatible = True
                else:
                    python2_compatible = False
                python3_compatible = not python2_compatible

                py_binary_info[info.service] = struct(
                    main = info.main,
                    libs = [info.lib],
                    python2_compatible = python2_compatible,
                    python3_compatible = python3_compatible,
                    python = info.python,
                )
            else:
                if info.main != py_binary_info[info.service].main:
                    fail("Multiple main py binaries provided for %s", info.service)
                if info.python != py_binary_info[info.service].python:
                    fail("Multiple python attrs provided for %s", info.service)
                py_binary_info[info.service].libs.append(info.lib)
        if DbxServiceDefinitionExtension in ext:
            info = ext[DbxServiceDefinitionExtension]
            if info.service not in service_deps:
                if info.allow_missing:
                    continue
                fail("Extension target service {} which is not in the dependency tree".format(info.service))
            service_deps[info.service] += info.deps
            service_exe_args[info.service].extend(info.args)
            service_version_files[info.service].append(info.version_file)
            service_health_checks[info.service].extend(info.health_checks)

            for target in info.data:
                all_runfiles = all_runfiles.merge(target[DefaultInfo].default_runfiles)

    hidden_output_transitive = []

    for service in py_binary_info:
        info = py_binary_info[service]
        name_prefix = service.split("/")[-1]  # have a prefix that isn't just root service/test label so we can easily identify the process
        binary_out_file = ctx.actions.declare_file(name_prefix + "-" + ctx.label.name + "-service-extensions/py-binary/" + service.strip("/") + "_py_binary")

        python = ctx.toolchains[BUILD_TAG_TO_TOOLCHAIN_MAP[info.python]].interpreter[DbxPyInterpreter]
        runfiles, _, hidden_output = emit_py_binary(
            ctx,
            main = info.main,
            srcs = [info.main],
            out_file = binary_out_file,
            pythonpath = None,
            deps = depset(direct = info.libs).to_list(),
            data = [],
            ext_modules = None,
            python = python,
            internal_bootstrap = False,
            python2_compatible = info.python2_compatible,
            python3_compatible = info.python3_compatible,
        )
        service_exe[service] = binary_out_file.short_path

        version_file_deps = [binary_out_file]
        version_file = ctx.actions.declare_file(
            binary_out_file.basename + ".version",
            sibling = binary_out_file,
        )
        _create_version_file(
            ctx,
            depset(direct = [binary_out_file], transitive = [runfiles.files]),
            output = version_file,
        )
        service_version_files[service].append("//" + version_file.short_path)

        all_runfiles = all_runfiles.merge(runfiles)
        all_runfiles = all_runfiles.merge(ctx.runfiles(files = [binary_out_file, version_file]))
        hidden_output_transitive.append(hidden_output)

    return [
        struct(
            type = service.type,
            service_name = service.service_name,
            launch_cmd = struct(
                cmd = service_exe[service.service_name] + " " + " ".join(service_exe_args[service.service_name]),
                env_vars = service.launch_cmd.env_vars,
            ),
            dependencies = depset(direct = service_deps[service.service_name]).to_list(),
            health_checks = service_health_checks[service.service_name],
            verbose = service.verbose,
            owner = service.owner,
            version_files = service_version_files[service.service_name],
        )
        for service in services
    ], all_runfiles, depset(transitive = hidden_output_transitive)

# create a services binary target at the output of this context, return the runfiles and hidden output
def _create_services_bin(ctx, services, extensions, launcher_args = [], extra_args = []):
    if ctx.attr.verbose:
        launcher_args = launcher_args + ["--svc.verbose=1"]
    else:
        launcher_args = launcher_args + ["--svc.verbose=0"]

    # Use Args to generate the file content to avoid doing it during analysis phase.
    content = ctx.actions.args()
    content.set_param_file_format("multiline")
    services, runfiles, hidden_output = _apply_service_extensions(ctx, services, extensions)
    content.add_all([services], map_each = _to_proto)

    service_defs = ctx.actions.declare_file(ctx.label.name + ".service_defs")
    ctx.actions.write(
        output = service_defs,
        content = content,
    )

    service_defs_version_file = ctx.actions.declare_file(ctx.label.name + ".service_defs.version")
    _create_version_file(ctx, inputs = [service_defs] + ctx.files._svcinit_tool + ctx.files._svcd_tool, output = service_defs_version_file)

    write_runfiles_tmpl(
        ctx,
        ctx.outputs.executable,
        execute_runfiles_cmd_tmpl.format(
            service_launcher = ctx.executable._svcinit_tool.short_path,
            launcher_args = " ".join(launcher_args),
            service_definitions = service_defs.short_path,
            service_defs_version_file = service_defs_version_file.short_path,
            extra_args = " ".join(extra_args),
        ),
    )

    runfiles = runfiles.merge(ctx.runfiles(
        files = [service_defs, service_defs_version_file] + ctx.files._svcinit_tool + ctx.files._svcd_tool,
    ))
    runfiles = runfiles.merge(ctx.attr._svcinit_tool.data_runfiles)
    runfiles = runfiles.merge(ctx.attr._svcinit_tool.default_runfiles)
    runfiles = runfiles.merge(ctx.attr._svcd_tool.data_runfiles)
    runfiles = runfiles.merge(ctx.attr._svcd_tool.default_runfiles)
    return runfiles, hidden_output

def _get_version_files_transitive_dep_from_data(data_targets):
    transitive_deps = []
    for target in data_targets:
        transitive_deps.append(target.data_runfiles.files)
        transitive_deps.append(target.default_runfiles.files)

        # unfortunately we don't have access to the full runfiles tree
        # at this stage. apply some heuristic to get our restart logic
        # to be more correct
        if hasattr(target, "files"):
            transitive_deps.append(target.files)
    return transitive_deps

def service_impl(ctx):
    version_file_deps_trans = _get_version_files_transitive_dep_from_data(ctx.attr.data)
    version_file_deps = ctx.files.data + ctx.files.exe
    version_file_deps_trans.append(ctx.attr.exe.default_runfiles.files)

    version_file = ctx.actions.declare_file(ctx.label.name + ".version")
    _create_version_file(
        ctx,
        depset(direct = version_file_deps, transitive = version_file_deps_trans),
        output = version_file,
    )

    args = []
    for arg in ctx.attr.exe_args:
        args.append(ctx.expand_location(arg, targets = ctx.attr.data))

    dependents = []
    transitive_extensions = []
    services = dict()

    for dep in ctx.attr.deps:
        dependents += dep.root_services
        transitive_extensions.append(dep.extensions)
        services.update(dep.services)

    # some extensions modify the dependency tree and bring in services of their own.
    # it is simpler to handle them here than in _apply_service_extensions, and also
    # more accurate (so that, e.g., the `services` attribute actually contains
    # all service definitions that may be used in this tree)
    for ext in ctx.attr.extensions:
        if DbxServiceDefinitionExtension in ext:
            info = ext[DbxServiceDefinitionExtension]
            transitive_extensions.append(info.extensions)
            services.update(info.services)

    label = "//" + ctx.label.package + "/" + ctx.label.name

    health_checks = []

    for verify in ctx.attr.verify_cmds:
        health_checks += [struct(type = HEALTH_CHECK_TYPE_CMD, cmd = struct(cmd = verify))]

    if ctx.attr.http_health_check:
        health_checks += [struct(
            type = HEALTH_CHECK_TYPE_HTTP,
            http_health_check = struct(url = ctx.attr.http_health_check),
        )]

    launch_cmd = struct(exe = ctx.executable.exe.short_path, args = args, env_vars = [])
    for env_var in ctx.attr.exe_env:
        env_value = ctx.attr.exe_env[env_var]
        env_value = ctx.expand_location(env_value, targets = ctx.attr.data)
        launch_cmd.env_vars.append(struct(key = env_var, value = env_value))

    service = struct(
        type = ctx.attr.type,
        service_name = label,
        launch_cmd = launch_cmd,
        dependencies = dependents,
        health_checks = health_checks,
        verbose = ctx.attr.verbose,
        owner = ctx.attr.owner,
        version_file = label + ".version",
    )

    services[label] = service

    extensions = depset(direct = ctx.attr.extensions, transitive = transitive_extensions)

    # /bin/true is used as the underlying binary of this service binary, so that bzl itest
    # can treat service targets and service test targets the same way
    runfiles, hidden_output = _create_services_bin(
        ctx,
        services = services.values(),
        extensions = extensions,
        extra_args = ["/bin/true"],
    )

    runfiles = runfiles.merge(ctx.runfiles(
        files = [version_file],
        collect_default = True,
    ))
    for ext in ctx.attr.extensions:
        runfiles = runfiles.merge(ext[DefaultInfo].default_runfiles)

    return struct(
        service_name = label,
        services = services,
        root_services = [label],
        extensions = extensions,
        providers = [
            DefaultInfo(
                runfiles = runfiles,
            ),
            OutputGroupInfo(
                _hidden_top_level_INTERNAL_ = hidden_output,
            ),
        ],
    )

# this must match up with the proto definition in
# //dropbox/proto/build_tools/svclib/service.proto#L26
SERVICE_TYPE_DAEMON = 0
SERVICE_TYPE_TASK = 1

_service_common_attrs = {
    "_svcd_tool": _svcd_tool_attr,
    "_svcinit_tool": _svcinit_tool_attr,
}
_service_common_attrs.update(py_binary_attrs)

_service_internal_attrs = {
    "create_version_file": attr.bool(mandatory = True),
    "exe": attr.label(mandatory = True, executable = True, cfg = "target"),
    "exe_env": attr.string_dict(),
    "exe_args": attr.string_list(),
    "data": attr.label_list(allow_files = True),
    "deps": attr.label_list(providers = ["services", "root_services", "extensions"]),
    "extensions": attr.label_list(),
    "owner": attr.string(mandatory = True),  # must be the name of a team defined in TEAMS.yaml
    "verify_cmds": attr.string_list(),
    "http_health_check": attr.string(),
    "verbose": attr.bool(default = False),
    "type": attr.int(values = [SERVICE_TYPE_DAEMON, SERVICE_TYPE_TASK]),
}
_service_internal_attrs.update(runfiles_attrs)
_service_internal_attrs.update(_service_common_attrs)

service_internal = rule(
    implementation = service_impl,
    attrs = _service_internal_attrs,
    toolchains = ALL_TOOLCHAIN_NAMES,
    executable = True,
)

def service_group_impl(ctx):
    root_services = []
    transitive_extensions = []
    services = dict()

    for svc in ctx.attr.services:
        root_services += svc.root_services
        transitive_extensions.append(svc.extensions)
        services.update(svc.services)

    # some extensions modify the dependency tree and bring in services of their own.
    # it is simpler to handle them here than in _apply_service_extensions, and also
    # more accurate (so that, e.g., the `services` attribute actually contains
    # all service definitions that may be used in this tree)
    for ext in ctx.attr.extensions:
        if DbxServiceDefinitionExtension in ext:
            info = ext[DbxServiceDefinitionExtension]
            transitive_extensions.append(info.extensions)
            services.update(info.services)

    extensions = depset(direct = ctx.attr.extensions, transitive = transitive_extensions)

    # /bin/true is used as the underlying binary of this service binary, so that bzl itest
    # can treat service targets and service test targets the same way
    runfiles, hidden_output = _create_services_bin(
        ctx,
        services = services.values(),
        extensions = extensions,
        extra_args = ["/bin/true"],
    )
    runfiles = runfiles.merge(ctx.runfiles(
        files = ctx.files.services,
        collect_default = True,
    ))
    for ext in ctx.attr.extensions:
        runfiles = runfiles.merge(ext[DefaultInfo].default_runfiles)

    return struct(
        services = services,
        root_services = root_services,
        extensions = extensions,
        providers = [
            DefaultInfo(
                runfiles = runfiles,
            ),
            OutputGroupInfo(
                _hidden_top_level_INTERNAL_ = hidden_output,
            ),
        ],
    )

_service_group_internal_attrs = {
    "create_version_file": attr.bool(mandatory = True),
    "services": attr.label_list(providers = ["services", "root_services", "extensions"]),
    "extensions": attr.label_list(),
    "data": attr.label_list(allow_files = True),
    "verbose": attr.bool(default = False),
    "_svcd_tool": _svcd_tool_attr,
    "_svcinit_tool": _svcinit_tool_attr,
}
_service_group_internal_attrs.update(runfiles_attrs)
_service_group_internal_attrs.update(_service_common_attrs)

service_group_internal = rule(
    implementation = service_group_impl,
    attrs = _service_group_internal_attrs,
    toolchains = ALL_TOOLCHAIN_NAMES,
    executable = True,
)

def _services_bin_impl(ctx):
    services = {}
    transitive_extensions = []
    for svc_def in ctx.attr.services:
        services.update(svc_def.services)
        transitive_extensions.append(svc_def.extensions)

    test_target = ctx.label.package + "/" + ctx.label.name
    launcher_args = []
    if not ctx.attr.start_services:
        launcher_args.append("--svc.create-only")

    extra_args = []
    if ctx.attr.bin:
        launcher_args.append("--svc.test-bin={}".format(ctx.executable.bin.short_path))
        extra_args.append("$RUNFILES/{}".format(ctx.executable.bin.short_path))

    runfiles, hidden_output = _create_services_bin(
        ctx,
        services = services.values(),
        extensions = depset(direct = ctx.attr.extensions, transitive = transitive_extensions),
        launcher_args = launcher_args,
        extra_args = extra_args,
    )
    runfiles = runfiles.merge(ctx.runfiles(collect_default = True))
    for ext in ctx.attr.extensions:
        runfiles = runfiles.merge(ext[DefaultInfo].default_runfiles)
    return [
        DefaultInfo(runfiles = runfiles),
        coverage_common.instrumented_files_info(ctx, dependency_attributes = ["bin"]),
        OutputGroupInfo(
            _hidden_top_level_INTERNAL_ = hidden_output,
        ),
    ]

_services_bin_attrs = {
    "bin": attr.label(cfg = "target", mandatory = False, executable = True),
    "services": attr.label_list(providers = ["services"]),
    # this `data` field is expected to be the concatenation of
    # [`test`] and `services`. It is done as a convenient way
    # to collect the runfiles from those fields.
    "data": attr.label_list(allow_files = True),
    "start_services": attr.bool(default = True),
    "verbose": attr.bool(default = False),
    "extensions": attr.label_list(),
    "create_version_file": attr.bool(mandatory = True),
    "_svcd_tool": _svcd_tool_attr,
    "_svcinit_tool": _svcinit_tool_attr,
    # The `quarantine` attr is used at Dropbox to store metadata regarding a flaky test target that's been
    # disabled from running in CI.
    "quarantine": attr.string_dict(),
}
_services_bin_attrs.update(runfiles_attrs)
_services_bin_attrs.update(_service_common_attrs)

services_internal_test = rule(
    implementation = _services_bin_impl,
    attrs = _services_bin_attrs,
    test = True,
    toolchains = ALL_TOOLCHAIN_NAMES,
    executable = True,
)

def service_extension_py_binary_impl(ctx):
    main = ctx.files.main[0]
    runfiles = ctx.runfiles(collect_default = True)
    runfiles = runfiles.merge(ctx.attr.lib[DefaultInfo].default_runfiles)

    return struct(
        providers = [
            DbxServicePyBinaryExtension(
                main = main,
                lib = ctx.attr.lib,
                service = ctx.attr.service.service_name,
                python = ctx.attr.python,
                allow_missing = ctx.attr.allow_missing,
            ),
            DefaultInfo(
                runfiles = runfiles,
            ),
        ],
    )

service_extension_py_binary_internal = rule(
    implementation = service_extension_py_binary_impl,
    attrs = {
        "main": attr.label(allow_files = True, mandatory = True),
        "lib": attr.label(
            mandatory = True,
            providers = [[PyInfo], [DbxPyVersionCompatibility]],
        ),
        "service": attr.label(providers = ["service_name"], mandatory = True),
        "python": attr.string(default = cpython_27.build_tag, values = BUILD_TAG_TO_TOOLCHAIN_MAP.keys()),
        "allow_missing": attr.bool(default = False),
    },
)

def dbx_service_py_binary_extension(**kwargs):
    service_extension_py_binary_internal(
        testonly = True,
        **kwargs
    )

def service_extension_definition_impl(ctx):
    version_file_deps_trans = _get_version_files_transitive_dep_from_data(ctx.attr.data)
    version_file_deps = ctx.files.data

    version_file = ctx.actions.declare_file(ctx.label.name + ".version")
    _create_version_file(
        ctx,
        depset(direct = version_file_deps, transitive = version_file_deps_trans),
        output = version_file,
    )

    runfiles = ctx.runfiles(
        files = [version_file],
        collect_default = True,
    )
    for data in ctx.attr.data:
        runfiles = runfiles.merge(data[DefaultInfo].default_runfiles)

    dependents = []
    transitive_extensions = []
    services = dict()

    for dep in ctx.attr.deps:
        for root_svc in dep.root_services:
            if root_svc == ctx.attr.service.service_name:
                # this can happen when an extension of one service depends on
                # another extension of the same service, in which case what is
                # important is we combine the extensions below
                continue
            dependents.append(root_svc)
        transitive_extensions.append(dep.extensions)
        services.update(dep.services)

    health_checks = []

    for verify in ctx.attr.verify_cmds:
        health_checks += [struct(type = HEALTH_CHECK_TYPE_CMD, cmd = struct(cmd = verify))]

    if ctx.attr.http_health_check:
        health_checks += [struct(
            type = HEALTH_CHECK_TYPE_HTTP,
            http_health_check = struct(url = ctx.attr.http_health_check),
        )]

    args = list(ctx.attr.args)
    for args_provider in ctx.attr.args_providers:
        args.extend(args_provider[DbxServiceExtensionArgsProvider].args)

    return struct(
        providers = [
            DbxServiceDefinitionExtension(
                service = ctx.attr.service.service_name,
                deps = dependents,
                data = ctx.attr.data,
                extensions = depset(transitive = transitive_extensions),
                services = services,
                args = args,
                version_file = "//" + version_file.short_path,
                health_checks = health_checks,
                allow_missing = ctx.attr.allow_missing,
            ),
            DefaultInfo(
                runfiles = runfiles,
            ),
        ],
    )

service_extension_definition_internal = rule(
    implementation = service_extension_definition_impl,
    attrs = {
        "create_version_file": attr.bool(mandatory = True),
        "verify_cmds": attr.string_list(),
        "http_health_check": attr.string(),
        "args": attr.string_list(),
        "args_providers": attr.label_list(providers = [DbxServiceExtensionArgsProvider]),
        "deps": attr.label_list(providers = ["services", "root_services", "extensions"]),
        "data": attr.label_list(allow_files = True),
        "service": attr.label(providers = ["service_name"], mandatory = True),
        "allow_missing": attr.bool(default = False),
    },
)

def dbx_service_definition_extension(**kwargs):
    service_extension_definition_internal(
        testonly = True,
        create_version_file = select(_svc_create_version_file_choices),
        **kwargs
    )

def dbx_services_test(
        name,
        test,
        services = [],
        size = "small",
        local = 0,
        tags = [],
        start_services = True,
        shard_count = 1,
        **kwargs):
    verbose = select(_svc_verbose_choices)
    services_internal_test(
        name = name,
        bin = test,
        services = services,
        data = [test] + services,
        size = size,
        local = local,
        tags = tags,
        start_services = start_services,
        verbose = verbose,
        create_version_file = select(_svc_create_version_file_choices),
        shard_count = shard_count,
        **kwargs
    )

def _select_deps(deps):
    if type(deps) == "list":
        return select({
            str(Label("//build_tools:disable-service-deps")): [],
            "//conditions:default": deps,
        })
    # bazel doesn't support nested selects
    return deps

def dbx_service_daemon(
        name,
        owner,
        exe,
        exe_env = {},
        args = [],
        data = [],
        deps = [],
        http_health_check = None,
        verify_cmds = [],
        service_test_tags = [],
        service_test_size = "small",
        quarantine = {},
        verbose = False,
        idempotent = True,
        **kwargs):
    if not verbose:
        verbose = select(_svc_verbose_choices)
    if len(verify_cmds) == 0 and not http_health_check:
        fail("A health check is required.")

    # TODO(zbarsky): default to public visibility while we fix sprawling dependencies.
    visibility = kwargs.pop("visibility", ["//visibility:public"])

    service_internal(
        name = name,
        exe = exe,
        exe_env = exe_env,
        exe_args = args,
        data = data + [exe],
        deps = _select_deps(deps),
        http_health_check = http_health_check,
        verify_cmds = verify_cmds,
        testonly = True,
        verbose = verbose,
        type = SERVICE_TYPE_DAEMON,
        owner = owner,
        create_version_file = select(_svc_create_version_file_choices),
        visibility = visibility,
        **kwargs
    )

    # Automatically verify that the service can start up correctly.
    test = Label("//build_tools/services:restart_test")
    if not idempotent:
        test = Label("//build_tools:pass")
    dbx_services_test(
        name = name + "_service_test",
        test = test,
        services = [name],
        start_services = True,
        size = service_test_size,
        tags = service_test_tags,
        quarantine = quarantine,
    )

def dbx_service_task(
        name,
        owner,
        exe,
        exe_env = {},
        args = [],
        data = [],
        deps = [],
        service_test_tags = [],
        service_test_size = "small",
        quarantine = {},
        verbose = False,
        idempotent = True,
        **kwargs):
    if not verbose:
        verbose = select(_svc_verbose_choices)

    # TODO(zbarsky): default to public visibility while we fix sprawling dependencies.
    visibility = kwargs.pop("visibility", ["//visibility:public"])

    service_internal(
        name = name,
        exe = exe,
        exe_env = exe_env,
        exe_args = args,
        data = data + [exe],
        deps = _select_deps(deps),
        testonly = True,
        verbose = verbose,
        type = SERVICE_TYPE_TASK,
        owner = owner,
        create_version_file = select(_svc_create_version_file_choices),
        visibility = visibility,
        **kwargs
    )

    # Automatically verify that the service can start up correctly.
    test = Label("//build_tools/services:restart_test")
    if not idempotent:
        test = Label("//build_tools:pass")
    dbx_services_test(
        name = name + "_service_test",
        test = test,
        services = [name],
        start_services = True,
        size = service_test_size,
        tags = service_test_tags,
        quarantine = quarantine,
    )

def dbx_service_group(
        name,
        services = [],
        service_test_tags = [],
        service_test_size = "small",
        quarantine = {},
        idempotent = True,
        data = [],
        **kwargs):
    service_group_internal(
        name = name,
        services = services,
        data = data + services,
        testonly = True,
        verbose = select(_svc_verbose_choices),
        create_version_file = select(_svc_create_version_file_choices),
        **kwargs
    )

    # Automatically verify that the service can start up correctly.
    test = Label("//build_tools/services:restart_test")
    if not idempotent:
        test = Label("//build_tools:pass")
    dbx_services_test(
        name = name + "_service_test",
        test = test,
        services = [name],
        start_services = True,
        size = service_test_size,
        tags = service_test_tags,
        quarantine = quarantine,
    )
