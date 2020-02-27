load("//build_tools/py:py.bzl", "dbx_py_local_piplib")

def local_new_file(ctx, name):
    """
    Create a new file prefixed with the current label name
    """
    return ctx.actions.declare_file(ctx.label.name + "/" + name)

def gen_ext_module(ctx, use_cpp):
    # disutils will add diffrent linker flags if the source files are c++
    if use_cpp:
        file_ext = ".cpp"
    else:
        file_ext = ".c"

    c_ext_module = local_new_file(ctx, ctx.attr.module_name + file_ext)
    ctx.actions.run(
        inputs = [ctx.file.cdef, ctx.file.source],
        outputs = [c_ext_module],
        executable = ctx.executable._gen_ext_module_c,
        use_default_shell_env = True,
        arguments = [
            "--out",
            c_ext_module.path,
            "--ext-name",
            ctx.attr.module_name,
            "--cdef",
            ctx.file.cdef.path,
            "--source",
            ctx.file.source.path,
        ],
        progress_message = "creating cffi {}".format(ctx.attr.module_name),
    )
    return c_ext_module

SETUP_PY = """
from setuptools import setup, Extension
setup(
    name='{package_name}',
    version='1',
    ext_modules=[
        Extension(
            name='{module_name}',
            sources=[{sources}],
            extra_compile_args=[{extra_compile_args}],
            extra_link_args={extra_link_args},
            libraries={libraries},
        )
    ]
) """

def gen_setup_py(ctx, c_files, extra_compile_args = [], extra_link_args = [], libraries = []):
    setup_py = local_new_file(ctx, "setup.py")
    prefix_len = len(setup_py.dirname) + 1
    sources = ", ".join([
        "'{}'".format(f.path[prefix_len:])
        for f in c_files
    ])
    extra_compile_args = ", ".join([
        "'{}'".format(arg)
        for arg in extra_compile_args
    ])
    extra_link_args = repr(extra_link_args)
    libraries = repr(libraries)
    ctx.actions.write(
        output = setup_py,
        content = SETUP_PY.format(
            package_name = ctx.label.name,
            module_name = ctx.attr.module_name,
            sources = sources,
            extra_compile_args = extra_compile_args,
            extra_link_args = extra_link_args,
            libraries = libraries,
        ),
    )
    return setup_py

def _cffi_module_impl(ctx):
    c_ext_module = gen_ext_module(ctx, ctx.attr.use_cpp)
    setup_py = gen_setup_py(
        ctx = ctx,
        c_files = [c_ext_module],
        extra_compile_args = ctx.attr.copts,
        extra_link_args = ctx.attr.linkopts,
        libraries = ctx.attr.libraries,
    )

    return struct(
        files = depset(
            [c_ext_module] +
            [setup_py],
        ),
    )

_cffi_module = rule(
    implementation = _cffi_module_impl,
    attrs = {
        "module_name": attr.string(
            mandatory = True,
        ),
        "cdef": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "source": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "use_cpp": attr.bool(default = False),
        "copts": attr.string_list(),
        "linkopts": attr.string_list(),
        "libraries": attr.string_list(),
        "_gen_ext_module_c": attr.label(
            default = Label("//build_tools/py:build_cffi_binding"),
            cfg = "host",
            executable = True,
        ),
    },
)

def dbx_cffi_module(
        name,
        module_name = None,
        visibility = None,
        deps = [],
        python2_compatible = True,
        python3_compatible = None,
        contents = None,
        ignore_missing_static_libraries = True,
        tags = [],
        import_test_tags = [],
        **kwargs):
    contents = contents or {}
    if module_name == None:
        module_name = name
    cffi_name = name + "_cffi"
    _cffi_module(
        name = cffi_name,
        module_name = module_name,
        visibility = ["//visibility:private"],
        tags = tags,
        **kwargs
    )
    if not contents:
        if python2_compatible:
            contents["cpython-27"] = [module_name + ".so"]
        if python3_compatible:
            contents["cpython-37"] = [module_name + ".cpython-37m-x86_64-linux-gnu.so"]
            contents["cpython-38"] = [module_name + ".cpython-38-x86_64-linux-gnu.so"]
    dbx_py_local_piplib(
        name = name,
        provides = [module_name],
        contents = contents,
        srcs = [":" + cffi_name],
        deps = ["//pip/cffi"] + deps,
        visibility = visibility,
        python2_compatible = python2_compatible,
        python3_compatible = python3_compatible,
        ignore_missing_static_libraries = ignore_missing_static_libraries,
        tags = tags,
        import_test_tags = import_test_tags,
    )
