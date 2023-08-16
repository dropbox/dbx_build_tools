load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load(
    "@bazel_tools//tools/build_defs/cc:action_names.bzl",
    "CPP_COMPILE_ACTION_NAME",
    "CPP_LINK_EXECUTABLE_ACTION_NAME",
    "C_COMPILE_ACTION_NAME",
)
load("//build_tools/go:cfg.bzl", "GO_USE_RULES_GO_ONLY", "NORACE_WHITELIST", "VERSION_BINARY_WHITELIST")
load("//build_tools/go:embed.bzl", "add_embedded_src")
load("//build_tools/bazel:config.bzl", "DbxStringValue")
load("//build_tools/bazel:quarantine.bzl", "process_quarantine_attr")
load("//build_tools/bazel:runfiles.bzl", "runfiles_attrs", "write_runfiles_tmpl")
load("//build_tools/services:svc.bzl", "dbx_services_test")
load("@io_bazel_rules_go//go:def.bzl", "go_binary", "go_library", "go_test")
load("//build_tools/binary:binary.bzl", "dbx_binary_shim", "dbx_binary_shim_test")

DbxGoToolchain = provider(
    fields = [
        "asm",
        "asm_include_path",
        "asm_inputs",
        "cgo",
        "compile",
        "cover",
        "link",
        "pack",
        "stdlib",
        "stdlib_race",
        "taglist",
        "version",
        "stdlib_packagefiles",
        "stdlib_race_packagefiles",
    ],
)

def _compute_stdlib_packagefiles(stdlib, race):
    packagefiles = []
    abidir = "linux_amd64"
    if race:
        abidir += "_race"
    abidir += "/"
    for f in stdlib:
        package_name = f.path[:-2].partition(abidir)[2]
        packagefiles.append("packagefile %s=%s" % (package_name, f.path))
    return depset(direct = packagefiles)

def _go_toolchain_impl(ctx):
    return [
        DbxGoToolchain(
            asm = ctx.file.asm,
            asm_inputs = ctx.attr.asm_inputs.files,
            asm_include_path = ctx.attr.include_dir,
            cgo = ctx.file.cgo,
            compile = ctx.file.compile,
            cover = ctx.file.cover,
            link = ctx.file.link,
            pack = ctx.file.pack,
            stdlib = ctx.attr.stdlib.files,
            stdlib_race = ctx.attr.stdlib_race.files,
            stdlib_packagefiles = _compute_stdlib_packagefiles(ctx.files.stdlib, False),
            stdlib_race_packagefiles = _compute_stdlib_packagefiles(ctx.files.stdlib_race, True),
            taglist = ctx.attr.taglist,
            version = ctx.attr.version,
        ),
    ]

go_toolchain = rule(
    _go_toolchain_impl,
    attrs = {
        "asm": attr.label(allow_single_file = True, executable = True, mandatory = True, cfg = "exec"),
        "asm_inputs": attr.label(mandatory = True),
        "cgo": attr.label(allow_single_file = True, executable = True, mandatory = True, cfg = "exec"),
        "compile": attr.label(allow_single_file = True, executable = True, mandatory = True, cfg = "exec"),
        "cover": attr.label(allow_single_file = True, executable = True, mandatory = True, cfg = "exec"),
        "include_dir": attr.string(mandatory = True),
        "link": attr.label(allow_single_file = True, executable = True, mandatory = True, cfg = "exec"),
        "pack": attr.label(allow_single_file = True, executable = True, mandatory = True, cfg = "exec"),
        "stdlib": attr.label(mandatory = True),
        "stdlib_race": attr.label(mandatory = True),
        "taglist": attr.string_list(mandatory = True),
        "version": attr.string(mandatory = True),
    },
)

# TODO(team): Remove all notion of versions once migration to bazel/rules_go is finished.
RULES_GO_VERSION = "1.21"
SUPPORTED_GO_VERSIONS = ["1.18", "1.19"]
DEFAULT_GO_VERSION = "1.18" if not GO_USE_RULES_GO_ONLY else RULES_GO_VERSION
DEFAULT_GO_LIBRARY_VERSIONS = ["1.18", "1.19"]
DEFAULT_GO_TEST_VERSIONS = ["1.18"]
SUPPORTED_GO_TOOLCHAINS = [
]

# DbxGoPackage is the main provider exported by dbx_go_library. Go libraries generate compilation
# actions over the matrix [go verions]X[race, no race]. To avoid the overhead of indirection, we
# directly place fields for all variants directly on the DbxGoPackage.
def _version_dependent_fields():
    fields = []
    for ver in SUPPORTED_GO_VERSIONS:
        fields.append(ver + "-native-objs")
        for race in ("race", "norace"):
            prefix = ver + "-" + race
            fields.append(prefix + "-iface")
            fields.append(prefix + "-lib")
            fields.append(prefix + "-trans-libs")
    return fields

DbxGoPackage = provider(
    fields = [
        "native_info",
    ] + _version_dependent_fields(),
)

def _get_toolchain(ctx, go_version):
    toolchain = None
    for t in ctx.attr._go_toolchains:
        toolchain = t[DbxGoToolchain]
        if toolchain.version == go_version:
            return toolchain

    fail('Required toolchain for Go version "%s" (for label %s) not found in %s' %
         (go_version, ctx.label, ctx.attr._go_toolchains))

go_file_types = [".go"]

def _filter_sources_on_tagmap(ctx, go_version):
    if len(ctx.attr.tagmap) == 0:
        # Short circuit in the vast majority of cases
        return ctx.files.srcs

    toolchain = _get_toolchain(ctx, go_version)
    srcs = []
    basenames = [x.basename for x in ctx.files.srcs]
    for taggedfile in ctx.attr.tagmap:
        if taggedfile not in [x.basename for x in ctx.files.srcs]:
            fail("Source file %s is part of tagmap, but is not listed in sources. Is this a typo?" % taggedfile)

    # TODO: In the future we can extend what's in the taglist to account for more build tags
    taglist = toolchain.taglist

    for src in ctx.files.srcs:
        skip = False
        if src.basename in ctx.attr.tagmap:
            for tag in ctx.attr.tagmap[src.basename]:
                if tag.startswith("!"):
                    if tag[1:] in taglist:
                        skip = True
                elif tag not in taglist:
                    skip = True
        if not skip:
            srcs.append(src)

    return srcs

def _go_package(ctx):
    package = ctx.label.package.replace("go/src/", "")
    if getattr(ctx.attr, "package", None) == "main":
        package = ctx.attr.package
    if hasattr(ctx.attr, "module_name") and ctx.attr.module_name:
        package = ctx.attr.module_name
    return package

def _use_go_race(ctx):
    # Only do race detection if --define=go_race=1 is passed.
    return "define-go_race" == ctx.attr._go_race[DbxStringValue].value

base_attrs = {
    "srcs": attr.label_list(allow_files = go_file_types),
    "tagmap": attr.string_list_dict(),
    "deps": attr.label_list(allow_files = True, providers = [DbxGoPackage]),
    "cdeps": attr.label_list(allow_files = True, providers = [CcInfo]),
    "data": attr.label_list(
        allow_files = True,
        doc = """Data can be used to include files which need to be available during execution but are not Go source files
        e.g. embed files for go:embed directives""",
    ),
    "package": attr.string(),
    # Support for go:embed directives
    "embed_config": attr.string(),
    "_go_toolchains": attr.label_list(default = SUPPORTED_GO_TOOLCHAINS),
    "_go_race": attr.label(
        default = Label("//build_tools/go:go_race"),
        cfg = "exec",
    ),
    "_go_cover": attr.label(
        default = Label("//build_tools/go:go_cover"),
        cfg = "exec",
    ),
    "_go_cdbg": attr.label(
        default = Label("//build_tools/go:go_cdbg"),
        cfg = "exec",
    ),
    "_cc_toolchain": attr.label(default = Label("@bazel_tools//tools/cpp:current_cc_toolchain")),
}

def go_binary_impl(ctx):
    if getattr(ctx.attr, "force_no_race", False):
        if NORACE_WHITELIST and str(ctx.label) not in NORACE_WHITELIST:
            fail("generate_norace_binary is meant to be used sparingly. '%s' binary is not whitelisted to used this functionality. Please email bazel@ first before using this." % (str(ctx.label)))
        go_race = False
    else:
        go_race = _use_go_race(ctx)

    test_wrapper = getattr(ctx.attr, "_dbx_test_wrapper", None)

    go_version = ctx.attr.go_version

    if test_wrapper == None and go_version in VERSION_BINARY_WHITELIST and str(ctx.label) not in VERSION_BINARY_WHITELIST[go_version]:
        fail("'%s' binary is not whitelisted for Go %s. Please use Go 1.18 instead" % (str(ctx.label), go_version))

    go_toolchain = _get_toolchain(ctx, go_version)
    cc_toolchain = find_cpp_toolchain(ctx)
    variant_prefix = "%s-%s" % (go_version, "race" if go_race else "norace")
    main_package = ctx.attr.deps[0][DbxGoPackage]

    executable_wrapper = ctx.outputs.executable

    link_inputs_direct = []
    link_inputs_trans = []
    link_inputs_trans.append(go_toolchain.stdlib)
    link_args = ctx.actions.args()
    linker_inputs = main_package.native_info.linking_context.linker_inputs.to_list()
    dynamic_libraries = [l2l.dynamic_library for li in linker_inputs for l2l in li.libraries if l2l.dynamic_library]

    if getattr(ctx.attr, "dynamic_libraries", []):
        for target in ctx.attr.dynamic_libraries:
            dynamic_libraries.extend(target.files.to_list())

    dylib_spec = ""
    if dynamic_libraries:
        dylib_paths = []
        for lib in dynamic_libraries:
            runfiles_lib_dir = "$RUNFILES/" + "/".join(lib.short_path.split("/")[0:-1])
            dylib_paths.append(runfiles_lib_dir)
        dylib_spec = "LD_LIBRARY_PATH=\"{}\"".format(":".join(dylib_paths))

    if getattr(ctx.attr, "standalone", False):
        if test_wrapper != None:
            fail("No test may standalone")
        executable_inner = ctx.outputs.executable
        link_args.add("-X", "dropbox/runfiles.compiledStandalone=yes")
        runfiles = ctx.runfiles(collect_default = False, collect_data = False)
    else:
        bin_name = getattr(ctx.attr, "bin_name", None)
        if bin_name:
            executable_inner = ctx.actions.declare_file("{}".format(bin_name))
        else:
            executable_inner = ctx.actions.declare_file("{}_bin".format(executable_wrapper.basename))

        test_wrapper_path = ""
        if test_wrapper != None:
            test_wrapper_path = (
                "$RUNFILES/%s %s " % (ctx.executable._dbx_test_wrapper.short_path, ctx.label)
            )

        write_runfiles_tmpl(
            ctx,
            executable_wrapper,
            '{} exec {}$RUNFILES/{} "$@"'.format(
                dylib_spec,
                test_wrapper_path,
                executable_inner.short_path,
            ),
        )

        runfiles = ctx.runfiles(
            files = [executable_wrapper, executable_inner] + dynamic_libraries,
            collect_default = True,
        )
        if test_wrapper != None:
            runfiles = runfiles.merge(test_wrapper[DefaultInfo].data_runfiles)
    link_args.add("-o", executable_inner)

    link_args.add("-linkmode=external")
    link_args.add("-extld", cc_toolchain.compiler_executable)
    link_inputs_direct.extend([l2l.pic_static_library or l2l.dynamic_library for li in linker_inputs for l2l in li.libraries])
    features = []
    if getattr(ctx.attr, "standalone", False):
        features.append("fully_static_link")
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features + features,
        unsupported_features = ctx.disabled_features + ["thin_lto"],
    )
    link_variables = cc_common.create_link_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        user_link_flags = _link_items_to_cmdline(linker_inputs),
    )
    extldflags = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = CPP_LINK_EXECUTABLE_ACTION_NAME,
        variables = link_variables,
    )
    link_args.add_joined("-extldflags", extldflags, join_with = " ")
    link_inputs_trans.append(cc_toolchain.all_files)
    if go_race:
        link_args.add("-race")
    link_args.add(getattr(main_package, variant_prefix + "-lib"))
    transitive_go_libs = getattr(main_package, variant_prefix + "-trans-libs")
    link_inputs_trans.append(transitive_go_libs)
    importcfg = ctx.actions.args()
    importcfg.set_param_file_format("multiline")
    importcfg.use_param_file("-importcfg=%s", use_always = True)
    if go_race:
        link_inputs_trans.append(go_toolchain.stdlib_race)
        importcfg.add_all(go_toolchain.stdlib_race_packagefiles)
    else:
        link_inputs_trans.append(go_toolchain.stdlib)
        importcfg.add_all(go_toolchain.stdlib_packagefiles)
    importcfg.add_all(transitive_go_libs, map_each = _lib_to_packagefile)

    ctx.actions.run(
        executable = go_toolchain.link,
        arguments = [importcfg, link_args],
        inputs = depset(direct = link_inputs_direct, transitive = link_inputs_trans),
        outputs = [executable_inner],
        mnemonic = "GoLink",
        env = {
            # Silliness to prevent the linker from embedding absolute paths.
            "PWD": "/proc/self/cwd",
        },
        tools = [],
    )

    return [
        DefaultInfo(runfiles = runfiles),
        coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["srcs"],
            dependency_attributes = ["deps"],
        ),
    ]

def _dbx_go_generate_test_main_impl(ctx):
    package = _go_package(ctx)
    gen_args = ctx.actions.args()
    gen_args.add("--package", package)
    gen_args.add("--output", ctx.outputs.test_main)
    gen_args.add("--go-version", ctx.attr.go_version)

    if ctx.coverage_instrumented():
        gen_args.add("--cover")
        srcs = depset(direct = ctx.files.srcs)
    else:
        srcs = depset(direct = [f for f in ctx.files.srcs if f.path.endswith("_test.go")])
    gen_args.add_all(srcs)

    ctx.actions.run(
        inputs = srcs,
        executable = ctx.executable._test_generator,
        outputs = [ctx.outputs.test_main],
        mnemonic = "GoGenTest",
        arguments = [gen_args],
        tools = [],
    )

_generate_test_attrs = dict(base_attrs)
_generate_test_attrs.update({
    "_test_generator": attr.label(
        default = Label("//build_tools/go:generate_test_main_norace"),
        executable = True,
        cfg = "exec",
    ),
    "go_version": attr.string(),
    "test_main": attr.output(),
    "module_name": attr.string(),
})

_dbx_go_generate_test_main = rule(
    _dbx_go_generate_test_main_impl,
    attrs = _generate_test_attrs,
)

def _link_items_to_cmdline(link_items):
    res = []
    for li in link_items:
        for lib in li.libraries:
            whole_archive = lib.alwayslink
            if whole_archive:
                res.append("-Wl,--whole-archive")
            if lib.pic_static_library:
                res.append(lib.pic_static_library.path)
            elif lib.dynamic_library:
                res.append(lib.dynamic_library.path)
            if whole_archive:
                res.append("-Wl,--no-whole-archive")
    return res

# This function takes compiled package archive and produces a "packagefile" line suitable for the
# file passed to the -importcfg option of the Go compiler or linker. We encode the package name in
# the filename like this: 'bazel-bin/go/some/package/package-lib-{some/package}.a'. This is a hack,
# so we don't have to pass around a map of package names to archives.
def _lib_to_packagefile(lib):
    p = lib.path
    pkg = p[p.index("{") + 1:-3].replace(":", "/")
    return "packagefile %s=%s" % (pkg, p)

def _gc_package(
        ctx,
        compile_out,
        linker_out,
        package,
        src_files,
        symabis_file,
        go_deps,
        go_toolchain,
        go_race,
        variant_prefix):
    "Run gc, the Go compiler, on a set of source files."
    outputs = [linker_out]
    compile_inputs_direct = []
    compile_inputs_trans = []
    compile_args = ctx.actions.args()
    compile_args.add("-p", package)
    compile_args.add("-trimpath=/proc/self/cwd")
    gen_asm_hdr_file = None
    if symabis_file:
        compile_args.add("-symabis", symabis_file.path)
        compile_inputs_direct.append(symabis_file)

        gen_asm_hdr_file = ctx.actions.declare_file("%s/go_asm.h" % (linker_out.basename[:-2]))
        compile_args.add("-asmhdr", gen_asm_hdr_file.path)
        outputs.append(gen_asm_hdr_file)
    if compile_out == None:
        compile_args.add("-o", linker_out)
    else:
        outputs.append(compile_out)
        compile_args.add("-o", compile_out)
        compile_args.add("-linkobj", linker_out)

    if getattr(ctx.attr, "embed_config", None):
        add_embedded_src(ctx, compile_args, compile_inputs_direct)

        # We add the data files because we want the embed_src to be available in the sandbox at execution time
        # It should be available here:
        # /dev/shm/bazel-sandbox.<unique_id>/linux-sandbox/<process_id>/execroot/__main__/go/src/dropbox/<package_name>
        compile_inputs_direct += ctx.files.data

    if go_race:
        compile_args.add("-race")

    if ctx.var["COMPILATION_MODE"] == "dbg" or "define-go_cdbg" == ctx.attr._go_cdbg[DbxStringValue].value:
        compile_args.add("-l")
        compile_args.add("-N")

    importcfg = ctx.actions.args()
    importcfg.set_param_file_format("multiline")
    importcfg.use_param_file("-importcfg=%s", use_always = True)
    if go_race:
        compile_inputs_trans.append(go_toolchain.stdlib_race)
        importcfg.add_all(go_toolchain.stdlib_race_packagefiles)
    else:
        compile_inputs_trans.append(go_toolchain.stdlib)
        importcfg.add_all(go_toolchain.stdlib_packagefiles)
    trans_dep_libs = []
    dep_compile_libs = []
    iface_key = variant_prefix + "-iface"
    trans_libs_key = variant_prefix + "-trans-libs"
    for go_dep in go_deps:
        dep_compile_lib = getattr(go_dep, iface_key)
        dep_compile_libs.append(dep_compile_lib)
        compile_inputs_direct.append(dep_compile_lib)
        trans_dep_libs.append(getattr(go_dep, trans_libs_key))
    importcfg.add_all(dep_compile_libs, map_each = _lib_to_packagefile)
    compile_args.add_all(src_files)
    compile_inputs_direct.extend(src_files)
    ctx.actions.run(
        executable = go_toolchain.compile,
        mnemonic = "GoCompile",
        outputs = outputs,
        inputs = depset(direct = compile_inputs_direct, transitive = compile_inputs_trans),
        tools = [],
        arguments = [importcfg, compile_args],
        env = {
            # Silliness to prevent the compiler from embedding absolute paths. The compiler will
            # absolutize filenames with this path rather than the "real" working directory. Then, it
            # will strip off the prefix with -trimpath.
            "PWD": "/proc/self/cwd",
        },
    )
    return trans_dep_libs, gen_asm_hdr_file

def _instrument_for_coverage(ctx, go_toolchain, srcs):
    "Add coverage instrumentation to a go package and return the instrumented sources."
    cover_srcs = []
    cover_seq = 0

    # The go cover tool only takes one source at a time. So, unfortunately, we have to generate an
    # action for each source.
    for src in srcs:
        if src.path.endswith("_test.go"):
            cover_srcs.append(src)
            continue

        args = ctx.actions.args()
        covered_file = ctx.actions.declare_file(
            "%s-%s-cover.go" % (go_toolchain.version, src.basename),
        )
        cover_srcs.append(covered_file)
        args.add("-o", covered_file)
        args.add("-mode=atomic")
        cov_var = "GoCover_" + str(cover_seq)
        cover_seq += 1
        args.add("-var", cov_var)
        args.add(src)
        ctx.actions.run(
            inputs = [src],
            executable = go_toolchain.cover,
            arguments = [args],
            outputs = [covered_file],
            mnemonic = "GoCover",
            tools = [],
        )
    return cover_srcs

def _compute_cgo_parameters(ctx, native_info):
    "Compute parameters for packages with CGO that are independent of the Go version."
    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features + ["thin_lto"],
    )
    compiler_inputs_direct = []
    compiler_inputs_trans = [
        cc_toolchain.all_files,
        native_info.compilation_context.headers,
    ]
    link_flags = []
    link_flags.extend(ctx.attr.cgo_linkerflags)
    for li in native_info.linking_context.linker_inputs.to_list():
        link_flags.extend(li.user_link_flags)
    link_flags.extend(ctx.fragments.cpp.linkopts)
    preprocessor_defines = native_info.compilation_context.defines

    # Add package directory to the include search path.
    quote_include_directories = depset(
        direct = [ctx.label.package],
        transitive = [native_info.compilation_context.quote_includes],
    )
    include_directories = native_info.compilation_context.includes
    system_include_directories = native_info.compilation_context.system_includes
    compile_variables = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        preprocessor_defines = preprocessor_defines,
        include_directories = include_directories,
        quote_include_directories = quote_include_directories,
        system_include_directories = system_include_directories,
        use_pic = True,
    )
    cflags = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = C_COMPILE_ACTION_NAME,
        variables = compile_variables,
    )
    cxx_compile_variables = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        user_compile_flags = ctx.attr.cgo_cxxflags,
        preprocessor_defines = preprocessor_defines,
        include_directories = include_directories,
        quote_include_directories = quote_include_directories,
        system_include_directories = system_include_directories,
        use_pic = True,
    )
    cxxflags = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = CPP_COMPILE_ACTION_NAME,
        variables = cxx_compile_variables,
    )
    cgo_go_files = []
    to_compile = []
    to_asm = []
    package_headers = []
    for cgo_src in ctx.files.cgo_srcs:
        ext = cgo_src.extension
        if ext in ("c", "cc", "cpp"):
            to_compile.append(cgo_src)
        elif ext == "s":
            to_asm.append(cgo_src)
        elif ext == "h":
            compiler_inputs_direct.append(cgo_src)
            package_headers.append(cgo_src)
        elif ext == "go":
            cgo_go_files.append(cgo_src)
        else:
            fail("unknown object in cgo_srcs: %s" % (cgo_src,))
    return struct(
        cc = cc_toolchain.compiler_executable,
        cflags = cflags + ctx.attr.cgo_includeflags,
        cxxflags = cxxflags + ctx.attr.cgo_includeflags,
        compiler_inputs = depset(
            direct = compiler_inputs_direct,
            transitive = compiler_inputs_trans,
        ),
        package_headers = tuple(package_headers),
        to_asm = tuple(to_asm),
        to_compile = tuple(to_compile),
        cgo_go_files = tuple(cgo_go_files),
        link_flags_str = " ".join(link_flags),
    )

def _handle_cgo(ctx, cgo_params, go_toolchain):
    "Invoke the cgo tool to generate bindings between Go and C/C++"
    if not ctx.attr.cgo_srcs:
        return [], depset()

    variant_prefix = go_toolchain.version
    native_objs_direct = []
    compiler_inputs = cgo_params.compiler_inputs
    to_compile = list(cgo_params.to_compile)
    cgo_go_outputs = []

    if cgo_params.cgo_go_files:
        # Run cgo. After invoking the C compiler and probing DWARF debug info, it will spit out a
        # bunch of .go files that the caller must compile into the package as well as some .c and .h
        # files, which we compile in this function.
        cgo_c_outputs = []
        cgo_export = ctx.actions.declare_file(variant_prefix + "/_cgo_export.c")
        cgo_c_outputs.append(cgo_export)
        cgo_export_header = ctx.actions.declare_file("_cgo_export.h", sibling = cgo_export)
        cgo_go_outputs.append(
            ctx.actions.declare_file("_cgo_gotypes.go", sibling = cgo_export),
        )
        for cgo_src in cgo_params.cgo_go_files:
            base = cgo_src.basename[:-3]
            cgo_go_outputs.append(
                ctx.actions.declare_file(base + ".cgo1.go", sibling = cgo_export),
            )
            cgo_c_outputs.append(
                ctx.actions.declare_file(base + ".cgo2.c", sibling = cgo_export),
            )
        to_compile.extend(cgo_c_outputs)
        args = ctx.actions.args()
        args.add("-objdir", cgo_export.dirname)
        args.add("--")
        args.add_all(cgo_params.cflags)

        # Always add -g to cancel any -g0 in the cflags. Cgo will not work if debuginfo is disabled.
        args.add("-g")
        args.add_all(cgo_params.cgo_go_files)
        ctx.actions.run(
            executable = go_toolchain.cgo,
            inputs = depset(transitive = [compiler_inputs], direct = cgo_params.cgo_go_files),
            arguments = [args],
            outputs = cgo_go_outputs + cgo_c_outputs + [cgo_export_header],
            mnemonic = "Cgo",
            tools = [],
            env = {
                "CC": cgo_params.cc,
                "CGO_LDFLAGS": cgo_params.link_flags_str,
                "PWD": "/proc/self/cwd",
            },
        )

        # Add _cgo_export.h to the available headers. In theory, any of the native source files can
        # depend on it. In practice, though, it seems only _cgo_export.c does. (If, at some point, a
        # native source file wants to include it, we'll have to add the cgo objdir to the include
        # path.)
        compiler_inputs = depset(transitive = [compiler_inputs], direct = [cgo_export_header])

    # Compile the cgo-generated C code cgo as well as any native source files in the package. We
    # ought to use Bazel's builtin C++ compilation support when that's accessible from Starlark.
    for native_source in to_compile:
        obj_file = ctx.actions.declare_file(
            "%s/%s.o" % (variant_prefix, native_source.basename),
        )
        args = ctx.actions.args()
        args.add("-c")
        args.add("-o", obj_file)
        args.add(native_source)
        if native_source.extension in ("cc", "cpp"):
            args.add_all(cgo_params.cxxflags)
        else:
            args.add_all(cgo_params.cflags)
            if native_source.path.endswith(".cgo2.c"):
                # Silence a warning common in the generated C.
                args.add("-Wno-unused-variable")
        ctx.actions.run(
            executable = cgo_params.cc,
            arguments = [args],
            inputs = depset(direct = [native_source], transitive = [compiler_inputs]),
            tools = [],
            outputs = [obj_file],
            mnemonic = "GoCcCompile",
            env = {
                # Prevent the working directory from being written into the debug info.
                "PWD": "/proc/self/cwd",
            },
        )
        native_objs_direct.append(obj_file)

    return cgo_go_outputs, depset(direct = native_objs_direct)

def _is_go119_or_higher(go_version):
    major, minor = go_version.split(".")
    return int(major) > 1 or int(minor) >= 19

def _asm_gen_symabis_action(ctx, cgo_params, go_toolchain):
    "Run go asm command, generating symabis for input to later compilation step"

    if not cgo_params or len(cgo_params.to_asm) == 0:
        return None

    # Later during compilation this header file will get generated; right now a blank throwaway
    # file is needed in case an asm file depends on it (even though gensymabis does not actually link)
    temp_asm_hdr_file = ctx.actions.declare_file("%s/%s/empty/go_asm.h" % (go_toolchain.version, ctx.label.name))
    ctx.actions.write(
        output = temp_asm_hdr_file,
        content = "\n",
    )

    package = _go_package(ctx)
    asm_inputs = depset(
        direct = list(cgo_params.to_asm) + list(cgo_params.package_headers) + [temp_asm_hdr_file],
        transitive = [go_toolchain.asm_inputs],
    )

    symabis_file = ctx.actions.declare_file("%s-%s/%s symabis" % (ctx.label.package, ctx.label.name, go_toolchain.version))
    args = ctx.actions.args()
    args.add("-gensymabis")
    args.add("-o", symabis_file)
    args.add("-I", go_toolchain.asm_include_path)
    args.add("-I", temp_asm_hdr_file.dirname)
    args.add("-D", "GOOS_linux")
    args.add("-D", "GOARCH_amd64")
    args.add("-D", "GOAMD64_v1")
    if _is_go119_or_higher(go_toolchain.version):
        args.add("-p", package)
    args.add("--")
    args.add_all(cgo_params.to_asm)
    ctx.actions.run(
        executable = go_toolchain.asm,
        inputs = asm_inputs,
        arguments = [args],
        mnemonic = "GoGenSymabis",
        outputs = [symabis_file],
        tools = [],
        env = {
            "PWD": "/proc/self/cwd",
        },
    )

    return symabis_file

def _post_compile_asm_action(ctx, asm_file, go_toolchain, asm_inputs, gen_asm_hdr_file, linker_out):
    "Run go asm command to generate an object file for each asm file, having compile generate a go_asm.h header is a pre-requisite"

    package = _go_package(ctx)
    obj_file = ctx.actions.declare_file("%s/%s.o" % (linker_out.basename[:-2], asm_file.basename.replace("." + asm_file.extension, "", 1)))

    args = ctx.actions.args()
    args.add("-o", obj_file)
    args.add("-I", go_toolchain.asm_include_path)
    args.add("-I", gen_asm_hdr_file.dirname)
    args.add("-D", "GOOS_linux")
    args.add("-D", "GOARCH_amd64")
    args.add("-D", "GOAMD64_v1")
    if _is_go119_or_higher(go_toolchain.version):
        args.add("-p", package)
    args.add("--")
    args.add(asm_file)
    ctx.actions.run(
        executable = go_toolchain.asm,
        inputs = asm_inputs,
        arguments = [args],
        mnemonic = "GoAsm",
        outputs = [obj_file],
        tools = [],
        env = {
            "PWD": "/proc/self/cwd",
        },
    )

    return obj_file

def _build_package(ctx, go_versions):
    package_info = {}
    package = _go_package(ctx)
    encoded_package = "{%s}" % (package.replace("/", ":"),)

    race_conceivable = _use_go_race(ctx)

    # Walk direct dependencies, partitioning them into Go and native dependencies.
    go_deps = []
    cgo_cc_infos = []
    go_native_infos = []
    direct_native_deps = []
    for dep in ctx.attr.deps:
        go_dep = dep[DbxGoPackage]
        go_deps.append(go_dep)
        go_native_infos.append(go_dep.native_info)
    for dep in ctx.attr.cdeps:
        cgo_cc_infos.append(dep[CcInfo])
    cgo_cc_info = cc_common.merge_cc_infos(cc_infos = cgo_cc_infos)
    go_native_infos.append(cgo_cc_info)
    native_info = cc_common.merge_cc_infos(cc_infos = go_native_infos)
    package_info["native_info"] = native_info

    if ctx.attr.cgo_srcs:
        cgo_params = _compute_cgo_parameters(ctx, cgo_cc_info)
    else:
        cgo_params = None

    for go_version in go_versions:
        srcs = _filter_sources_on_tagmap(ctx, go_version)
        go_toolchain = _get_toolchain(ctx, go_version)

        if ctx.coverage_instrumented() and ctx.label.name.endswith("_testlib"):
            srcs = _instrument_for_coverage(ctx, go_toolchain, srcs)

        cgo_go_outputs, c_native_objs = _handle_cgo(ctx, cgo_params, go_toolchain)
        symabis_file = _asm_gen_symabis_action(ctx, cgo_params, go_toolchain)
        native_objs = depset(transitive = [c_native_objs])

        if cgo_go_outputs:
            srcs = srcs + cgo_go_outputs

        if len(srcs) == 0:
            fail('Need at least one of "srcs" or "cgo_srcs" to be non-empty')

        for go_race in (True, False):
            # Don't generate race compilation actions if we'll never need them.
            if go_race and not race_conceivable:
                continue

            variant_prefix = "%s-%s" % (go_version, "race" if go_race else "norace")
            artifact_prefix = "%s-%s" % (ctx.label.name, variant_prefix)

            # If the package isn't "main", produce both an interface output and a linker
            # input. Dependent packages only need the interface output to compile against. We don't
            # bother with the interface output for main packages because no other package should
            # depend on them.
            linker_out = ctx.actions.declare_file(
                "%s-lib-%s.a" % (artifact_prefix, encoded_package),
            )
            if package == "main":
                compile_out = None
            else:
                compile_out = ctx.actions.declare_file(
                    "%s-iface-%s.a" % (artifact_prefix, encoded_package),
                )

            dep_libs_trans, gen_asm_hdr_file = _gc_package(
                ctx,
                compile_out,
                linker_out,
                package,
                srcs,
                symabis_file,
                go_deps,
                go_toolchain,
                go_race,
                variant_prefix,
            )

            if cgo_params and len(cgo_params.to_asm):
                asm_native_objs = []
                asm_inputs = depset(
                    direct = list(cgo_params.to_asm) + list(cgo_params.package_headers) + [gen_asm_hdr_file],
                    transitive = [go_toolchain.asm_inputs],
                )
                for asm_file in cgo_params.to_asm:
                    asm_native_objs.append(_post_compile_asm_action(ctx, asm_file, go_toolchain, asm_inputs, gen_asm_hdr_file, linker_out))
                asm_objects = depset(direct = asm_native_objs)
                native_objs = depset(transitive = [asm_objects, c_native_objs])

            if native_objs:
                # It would be nice if we could just pass the native object files we compiled into
                # the final link of a Go binary. Alas, we're obliged to pack the native objects into
                # the package's archive.
                pack_out = ctx.actions.declare_file(
                    "%s-libnative-%s.a" % (artifact_prefix, encoded_package),
                )
                args = ctx.actions.args()
                args.add("c")
                args.add(pack_out)
                args.add(linker_out)
                args.add_all(native_objs)
                ctx.actions.run(
                    executable = go_toolchain.pack,
                    inputs = depset(direct = [linker_out], transitive = [native_objs]),
                    mnemonic = "GoPack",
                    arguments = [args],
                    outputs = [pack_out],
                    tools = [],
                )
                linker_out = pack_out
            package_info[variant_prefix + "-iface"] = compile_out
            package_info[variant_prefix + "-lib"] = linker_out
            package_info[variant_prefix + "-trans-libs"] = depset(
                direct = [linker_out],
                transitive = dep_libs_trans,
            )

    return DbxGoPackage(**package_info)

def _dbx_go_library_impl(ctx):
    if ctx.attr.single_go_version_override and len(ctx.attr.go_versions) != 0:
        fail(
            ("%s defines both single_go_version_override and go_versions. " +
             "Please only use `go_versions`") % (ctx.label),
        )
    go_versions = ([ctx.attr.single_go_version_override] if ctx.attr.single_go_version_override else ctx.attr.go_versions)
    if len(go_versions) == 0:
        fail(("%s has an empty `go_versions` list. " +
              "Please specify at least one version.") % (ctx.label))

    pkg_info = _build_package(ctx, go_versions)
    variant = "{}-{}-lib".format(
        # If we have libraries that don't support building with the DEFAULT_GO_VERSION, fall back to
        # one of the versions it supports.
        DEFAULT_GO_VERSION if DEFAULT_GO_VERSION in go_versions else go_versions[0],
        "race" if _use_go_race(ctx) else "norace",
    )
    files = [getattr(pkg_info, variant)]

    return [
        DefaultInfo(
            runfiles = ctx.runfiles(collect_default = True),
            files = depset(direct = files),
        ),
        pkg_info,
        coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["srcs"],
            dependency_attributes = ["deps"],
        ),
    ]

_go_library_attrs = dict(base_attrs)
_go_library_attrs.update({
    "cgo_srcs": attr.label_list(allow_files = [".c", ".h", ".go", ".cpp", ".cc", ".s"]),
    "cgo_includeflags": attr.string_list(),
    "cgo_linkerflags": attr.string_list(),
    "cgo_cxxflags": attr.string_list(),
    "cover_name": attr.string(),
    # NOTE(anupc): Ideally, `go_versions` should have `non_empty=True`. However, because of the
    # hack used below, this is difficult to enforce right now.
    "go_versions": attr.string_list(default = DEFAULT_GO_LIBRARY_VERSIONS),
    # HACK(anupc): This is a nasty way to satisfy Bazel's selector resolution system.
    # In `dbx_go_binary` macro, if we pass in `go_versions = [go_version]` where
    # `go_version` is computed from the selector, Bazel complains with
    #
    # "expected value of type 'string' for element 0 of attribute 'go_versions' in 'dbx_go_library' rule"
    #
    # However, passing a single string value through works just fine.
    "single_go_version_override": attr.string(),
    "module_name": attr.string(),
})

_dbx_go_library_internal = rule(
    _dbx_go_library_impl,
    attrs = _go_library_attrs,
    fragments = ["cpp"],
)

_SUFFIX_DBX_GO = "_dbx_go"

def _normalized_dep(dep):
    if dep.startswith("@") and "//" not in dep:
        dep = dep + "//:" + dep[1:]
    if ":" not in dep:
        fixed_name = dep[dep.rfind("/") + 1:]
        if "//" in dep:
            dep = dep + ":" + fixed_name
        else:
            dep = ":" + fixed_name
    return dep

def _rewrite_godeps(deps):
    return [
        _normalized_dep(dep) + _SUFFIX_DBX_GO
        for dep in deps
    ]

def dbx_go_library(
        name,
        srcs = [],
        deps = [],
        cgo_srcs = [],
        cdeps = [],
        data = [],
        tagmap = {},
        module_name = None,
        cgo_includeflags = [],
        cgo_linkerflags = [],
        cgo_cxxflags = [],
        package = "",
        embed_config = None,
        # The following are bazel/rules_go-specific attributes.
        x_defs = {},
        **kwargs):
    if not GO_USE_RULES_GO_ONLY:
        _dbx_go_library_internal(
            name = name + _SUFFIX_DBX_GO,
            srcs = srcs,
            deps = _rewrite_godeps(deps),
            cgo_srcs = cgo_srcs,
            cdeps = cdeps,
            data = data,
            tagmap = tagmap,
            module_name = module_name,
            cgo_includeflags = cgo_includeflags,
            cgo_linkerflags = cgo_linkerflags,
            cgo_cxxflags = cgo_cxxflags,
            package = package,
            embed_config = embed_config,
            **kwargs
        )

    embedsrcs = []
    if embed_config:
        embedsrcs = data

    go_library(
        name = name,
        cgo = len(cgo_srcs) > 0,
        srcs = srcs + cgo_srcs,
        data = data,
        deps = deps,
        cdeps = cdeps,
        embedsrcs = embedsrcs,
        importpath = module_name if module_name else native.package_name()[len("go/src/"):],
        clinkopts = cgo_linkerflags,
        copts = cgo_includeflags,
        cppopts = cgo_cxxflags + cgo_includeflags,
        x_defs = x_defs,
        **kwargs
    )

_go_binary_attrs = dict(base_attrs)
_go_binary_attrs.update(runfiles_attrs)
_go_binary_attrs.update({
    # NOTE(D881381): Add support for arbitrary binary names.
    #
    # This is necessary when a go binary must be called by some external source,
    # and that source expects a specific filename. Currently, all binaries are
    # built and appended with `_bin`. An example is osquery expects the binary
    # to be a go binary (and not a bash script, which is currently generated
    # with the name specified in the bazel target) and for that binary to end
    # in `.ext`.
    #
    "bin_name": attr.string(),
    "go_version": attr.string(),
    "force_no_race": attr.bool(default = False),
    "standalone": attr.bool(default = False),
    "dynamic_libraries": attr.label_list(allow_files = True),
})

dbx_go_binary_internal = rule(
    go_binary_impl,
    attrs = _go_binary_attrs,
    executable = True,
    fragments = ["cpp"],
)

_go_test_attrs = dict(base_attrs)
_go_test_attrs.update(runfiles_attrs)
_go_test_attrs.update({
    "go_version": attr.string(),
    "_dbx_test_wrapper": attr.label(
        default = Label("//build_tools/go:go_test_wrapper"),
        executable = True,
        cfg = "target",
    ),
    "quarantine": attr.string_dict(),
})

_dbx_go_internal_test = rule(
    go_binary_impl,
    attrs = _go_test_attrs,
    executable = True,
    test = True,
    fragments = ["cpp"],
)

def dbx_go_binary(
        name,
        srcs,
        deps,
        data = [],
        tagmap = {},
        cgo_includeflags = [],
        cgo_linkerflags = [],
        cgo_cxxflags = [],
        go_version = None,
        alternate_go_versions = [],
        testonly = False,
        visibility = None,
        generate_norace_binary = False,
        bin_name = None,
        standalone = None,
        embed_config = None,
        tags = [],
        cgo_srcs = None,
        cdeps = [],
        # The following are bazel/rules_go-specific attributes.
        gotags = [],
        static = "off",
        x_defs = {},
        **kwargs):
    if not go_version:
        go_version = DEFAULT_GO_VERSION
    if go_version not in alternate_go_versions:
        alternate_go_versions = alternate_go_versions + [go_version]

    embedsrcs = []
    if embed_config:
        embedsrcs = data

    all_srcs = srcs + (cgo_srcs or [])
    x_defs = x_defs
    static = static
    if standalone:
        x_defs = dict(x_defs)  # original is immutable
        x_defs["dropbox/runfiles.compiledStandalone"] = "yes"
        static = "on"

    dynamic_libraries = kwargs.get("dynamic_libraries", [])
    if dynamic_libraries:
        kwargs.pop("dynamic_libraries")

    if go_version != RULES_GO_VERSION and not GO_USE_RULES_GO_ONLY:
        _dbx_go_library_internal(
            name = name + "_exelib",
            srcs = srcs,
            deps = _rewrite_godeps(deps),
            data = data,
            package = "main",
            go_versions = [],
            single_go_version_override = go_version,
            tags = tags,
            cgo_srcs = cgo_srcs,
            cdeps = cdeps,
            tagmap = tagmap,
            cgo_includeflags = cgo_includeflags,
            cgo_linkerflags = cgo_linkerflags,
            cgo_cxxflags = cgo_cxxflags,
            testonly = testonly,
            visibility = visibility,
            embed_config = embed_config,
            **kwargs
        )
        dbx_go_binary_internal(
            name = name,
            bin_name = bin_name,
            deps = [":" + name + "_exelib"],
            data = data,
            go_version = go_version,
            tags = tags,
            standalone = standalone,
            dynamic_libraries = dynamic_libraries,
            tagmap = tagmap,
            testonly = testonly,
            visibility = visibility,
            embed_config = embed_config,
            **kwargs
        )
    else:
        go_binary(
            name = name + "_bin",
            cgo = bool(cgo_srcs),
            srcs = all_srcs,
            data = data,
            embedsrcs = embedsrcs,
            gotags = gotags,
            deps = deps,
            cdeps = cdeps,
            clinkopts = cgo_linkerflags,
            copts = cgo_includeflags,
            cppopts = cgo_cxxflags + cgo_includeflags,
            static = static,
            x_defs = x_defs,
            testonly = testonly,
            visibility = visibility,
            tags = tags,
            **kwargs
        )

        dbx_binary_shim(
            name = name,
            binary = name + "_bin",
            testonly = testonly,
            visibility = visibility,
            tags = tags,
        )

    for alternate_go_version in alternate_go_versions:
        versioned_name = name + "_" + alternate_go_version
        if alternate_go_version != RULES_GO_VERSION and not GO_USE_RULES_GO_ONLY:
            _dbx_go_library_internal(
                name = versioned_name + "_exelib",
                srcs = srcs,
                deps = _rewrite_godeps(deps),
                data = data,
                package = "main",
                go_versions = [],
                single_go_version_override = alternate_go_version,
                tags = tags,
                cgo_srcs = cgo_srcs,
                cdeps = cdeps,
                tagmap = tagmap,
                cgo_includeflags = cgo_includeflags,
                cgo_linkerflags = cgo_linkerflags,
                cgo_cxxflags = cgo_cxxflags,
                testonly = testonly,
                visibility = visibility,
                embed_config = embed_config,
                **kwargs
            )
            dbx_go_binary_internal(
                name = versioned_name,
                deps = [":" + versioned_name + "_exelib"],
                data = data,
                go_version = alternate_go_version,
                tags = tags,
                dynamic_libraries = dynamic_libraries,
                tagmap = tagmap,
                testonly = testonly,
                visibility = visibility,
                embed_config = embed_config,
                **kwargs
            )
        else:
            go_binary(
                name = versioned_name + "_bin",
                cgo = bool(cgo_srcs),
                srcs = all_srcs,
                data = data,
                embedsrcs = embedsrcs,
                gotags = gotags,
                deps = deps,
                cdeps = cdeps,
                clinkopts = cgo_linkerflags,
                copts = cgo_includeflags,
                cppopts = cgo_cxxflags + cgo_includeflags,
                static = static,
                x_defs = x_defs,
                testonly = testonly,
                visibility = visibility,
                tags = tags,
                **kwargs
            )

            dbx_binary_shim(
                name = versioned_name,
                binary = versioned_name + "_bin",
                testonly = testonly,
                visibility = visibility,
                tags = tags,
            )

    if (go_version == RULES_GO_VERSION or GO_USE_RULES_GO_ONLY) and generate_norace_binary:
        go_binary(
            name = name + "_bin_norace",
            cgo = bool(cgo_srcs),
            srcs = all_srcs,
            data = data,
            gotags = gotags,
            deps = deps,
            cdeps = cdeps,
            clinkopts = cgo_linkerflags,
            copts = cgo_includeflags,
            cppopts = cgo_cxxflags + cgo_includeflags,
            race = "off",
            static = static,
            x_defs = x_defs,
            testonly = testonly,
            visibility = visibility,
            **kwargs
        )

        dbx_binary_shim(
            name = name + "_norace",
            binary = name + "_bin_norace",
            testonly = testonly,
            visibility = visibility,
            tags = tags,
        )
    elif generate_norace_binary:
        dbx_go_binary_internal(
            name = name + "_norace",
            deps = [":" + name + "_exelib"],
            data = data,
            go_version = go_version,
            tags = tags,
            force_no_race = True,
            dynamic_libraries = dynamic_libraries,
            tagmap = tagmap,
            testonly = testonly,
            visibility = visibility,
            embed_config = embed_config,
            **kwargs
        )

def _dbx_gen_maybe_services_test(
        name,
        srcs,
        test_main,
        deps,
        size = "small",
        package = None,
        module_name = None,
        tagmap = {},
        tags = [],
        data = [],
        cdeps = [],
        cgo_srcs = [],
        cgo_includeflags = [],
        cgo_includeheaders = [],
        cgo_linkerflags = [],
        cgo_cxxflags = [],
        shard_count = 1,
        services = [],
        local = None,
        args = None,
        start_services = True,
        go_version = None,
        flaky = 0,
        quarantine = {},
        embed_config = "",
        # normally, the service controller is only launched if a test
        # requries services. To launch it unconditionally, use this flag:
        force_launch_svcctl = False,
        timeout = None):
    testlib_name = name + "_testlib"
    _dbx_go_library_internal(
        name = testlib_name,
        srcs = srcs,
        deps = _rewrite_godeps(deps),
        package = package,
        module_name = module_name,
        tags = tags,
        tagmap = tagmap,
        data = data,
        cdeps = cdeps,
        cgo_srcs = cgo_srcs,
        cgo_includeflags = cgo_includeflags,
        cgo_linkerflags = cgo_linkerflags,
        cgo_cxxflags = cgo_cxxflags,
        cover_name = testlib_name,
        go_versions = [],
        single_go_version_override = go_version,
        testonly = True,
        embed_config = embed_config,
    )
    testmain_name = name + "_testmain"
    _dbx_go_library_internal(
        name = testmain_name,
        package = "main",
        srcs = [test_main],
        # Note: The tagmap will always fail the validation that requires a tagged
        # file to be in the "srcs" here.
        # TODO: Not sure if that means we need to drop the validation or not pass tagmaps to this
        # tagmap = tagmap,
        deps = [testlib_name],
        tags = tags,
        go_versions = [],
        single_go_version_override = go_version,
        testonly = True,
        embed_config = embed_config,
    )
    test_deps = [testmain_name]

    # A tag of the form "go<version>" (like, "go1.5", "go1.6", etc) is added to each test target,
    # corresponding to its Go version. To only run tests for a given go version, use the bazel test
    # flag, `--test_tags_filter=go<version>`
    tags = tags + ["go" + go_version]

    # TODO (drg): consider requiring timeouts on enormous tests
    if timeout != None and size != "enormous":
        # we use size=enormous to disable our 8GB memory limit on tests,
        # but this implies an eternal timeout (1 hour - yikes!) so we want
        # to tune that separately.  For non-enormous tests, the only thing
        # we use size for is to impact the timeout, though, so it doesn't make
        # sense to have two knobs to turn for one thing.  Bazel itself (but not
        # changes) uses size to choose to run smaller tests in parallel, so we
        # may want to relax this if we consider local test running use cases in
        # the future.
        fail("Please use \"size\" to set the timeout; only use timeout on size=\"enormous\" tests")

    if len(services) > 0 or force_launch_svcctl:
        _dbx_go_internal_test(
            name = name + "_bin",
            srcs = srcs,
            tagmap = tagmap,
            size = size,
            deps = test_deps,
            tags = tags + ["manual"],
            local = local,
            data = data,
            go_version = go_version,
            shard_count = shard_count,
            flaky = flaky,
            quarantine = quarantine,
            timeout = timeout,
        )
        dbx_services_test(
            name = name,
            test = name + "_bin",
            size = size,
            services = services,
            start_services = start_services,
            tags = tags,
            local = local,
            args = args,
            shard_count = shard_count,
            flaky = flaky,
            quarantine = quarantine,
            timeout = timeout,
        )
    else:
        _dbx_go_internal_test(
            name = name,
            tagmap = tagmap,
            size = size,
            deps = test_deps,
            tags = tags,
            data = data,
            shard_count = shard_count,
            local = local,
            args = args,
            go_version = go_version,
            flaky = flaky,
            quarantine = quarantine,
            timeout = timeout,
            embed_config = embed_config,
        )

def dbx_go_test(
        name,
        srcs,
        deps,
        size = "small",
        package = None,
        module_name = None,
        tagmap = {},
        tags = [],
        data = [],
        cdeps = [],
        cgo_srcs = [],
        cgo_includeflags = [],
        cgo_linkerflags = [],
        cgo_cxxflags = [],
        shard_count = 1,
        services = [],
        local = None,
        args = None,
        start_services = True,
        go_versions = DEFAULT_GO_TEST_VERSIONS,
        flaky = 0,
        quarantine = {},
        timeout = None,
        embed_config = "",
        # normally, the service controller is only launched if a test requries services.
        # To launch it unconditionally, use this flag:
        force_launch_svcctl = False,
        # bazel/rules_go-specific attributes.
        static = "off",
        x_defs = {},
        gotags = []):
    q_tags = process_quarantine_attr(quarantine)
    tags = tags + q_tags

    # Generate test targets for each entry in `go_versions`, with the following pattern.
    # A test target in `//go/src/foo/bar` (typically, `bar_test) with `go_versions=['1.5', '1.6',
    # '1.8'], will generate 3 `dbx_go_test` targets.
    # //go/src/foo/bar:bar_test_1.5, which runs tests against Go version 1.5
    # //go/src/foo/bar:bar_test_1.6, which runs tests against Go version 1.6
    # //go/src/foo/bar:bar_test_1.8, which runs tests against Go version 1.8
    #
    # In addition, a test suite, //go/src/foo/bar:bar_test which just runs
    # //go/src/foo/bar:bar_test_1.5 will be created (this target shows up during bash autocompletion)

    for go_version in go_versions:
        versioned_name = name + "_" + go_version

        # We ensure we don't add alternative_go_version to at least one of the elements
        # in go_versions (in case someone disables the default go version from running)
        versioned_tags = tags
        if go_version != DEFAULT_GO_VERSION and DEFAULT_GO_VERSION in go_versions:
            versioned_tags = tags + ["alternative_go_version"]

        if go_version == RULES_GO_VERSION or GO_USE_RULES_GO_ONLY:
            launch_svcctl = len(services) > 0 or force_launch_svcctl

            embedsrcs = []
            if embed_config:
                embedsrcs = data

            manual_tags = versioned_tags + ["manual"]

            test_name = versioned_name
            test_tags = versioned_tags
            if launch_svcctl:
                test_name = versioned_name + "_bin"
                test_tags = manual_tags

            go_test(
                name = test_name + "_bin",
                cgo = len(cgo_srcs) > 0,
                srcs = srcs + cgo_srcs,
                gotags = gotags,
                deps = deps,
                cdeps = cdeps,
                importpath = module_name if module_name else native.package_name()[len("go/src/"):],
                embedsrcs = embedsrcs,
                rundir = ".",
                clinkopts = cgo_linkerflags,
                copts = cgo_includeflags,
                cppopts = cgo_cxxflags + cgo_includeflags,
                static = static,
                x_defs = x_defs,
                data = data,
                tags = manual_tags,
                size = size,
                local = local,
                args = args,
                shard_count = shard_count,
                flaky = flaky,
                timeout = timeout,
            )

            dbx_binary_shim_test(
                name = test_name,
                binary = test_name + "_bin",
                testonly = True,
                tags = test_tags,
                size = size,
                local = local,
                args = args,
                shard_count = shard_count,
                flaky = flaky,
                # quarantine = quarantine,
                timeout = timeout,
            )

            if launch_svcctl:
                dbx_services_test(
                    name = versioned_name,
                    test = versioned_name + "_bin",
                    size = size,
                    services = services,
                    start_services = start_services,
                    tags = versioned_tags,
                    local = local,
                    args = args,
                    shard_count = shard_count,
                    flaky = flaky,
                    quarantine = quarantine,
                    timeout = timeout,
                )
        else:
            test_main_fmt = name + "-test_main-{}.go"
            test_main_versioned = test_main_fmt.format(go_version)

            _dbx_go_generate_test_main(
                name = name + "-gentest-" + go_version,
                srcs = srcs,
                test_main = test_main_versioned,
                testonly = True,
                module_name = module_name,
                go_version = go_version,
            )

            _dbx_gen_maybe_services_test(
                versioned_name,
                srcs = srcs,
                test_main = test_main_versioned,
                deps = deps,
                size = size,
                package = package,
                module_name = module_name,
                tagmap = tagmap,
                tags = versioned_tags,
                data = data,
                cdeps = cdeps,
                cgo_srcs = cgo_srcs,
                cgo_includeflags = cgo_includeflags,
                cgo_linkerflags = cgo_linkerflags,
                cgo_cxxflags = cgo_cxxflags,
                shard_count = shard_count,
                services = services,
                local = local,
                args = args,
                start_services = start_services,
                go_version = go_version,
                force_launch_svcctl = force_launch_svcctl,
                flaky = flaky,
                quarantine = quarantine,
                timeout = timeout,
                embed_config = embed_config,
            )
    native.test_suite(name = name, tests = [":" + name + "_" + go_versions[0]], tags = tags)
