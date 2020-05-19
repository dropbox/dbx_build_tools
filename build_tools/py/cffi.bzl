load("//build_tools/py:py.bzl", "dbx_py_local_piplib")

_CFFIBUILD_PY_TEMPLATE = """
from cffi import FFI

__ffi__ = FFI()
__ffi__.set_unicode(True)
with open("{cdef}") as fp:
    __ffi__.cdef(fp.read())
with open("{source}") as fp:
    __ffi__.set_source(
        "{ext_name}",
        fp.read(),
        libraries={libraries},
        extra_compile_args={extra_compile_args},
        extra_link_args={extra_link_args},
        source_extension="{extension}",
    )
"""

def _gen_cffibuild_py(ctx):
    cffibuild = ctx.actions.declare_file("_cffibuild.py")

    # Some targets currently pass in things like ".h" files,
    # so just assume C in those cases.
    if ctx.file.source.extension == ".cpp":
        extension = ".cpp"
    else:
        extension = ".c"

    ctx.actions.write(
        output = cffibuild,
        content = _CFFIBUILD_PY_TEMPLATE.format(
            cdef = ctx.file.cdef.basename,
            source = ctx.file.source.basename,
            ext_name = ctx.attr.module_name,
            libraries = repr(ctx.attr.libraries),
            extra_compile_args = repr(ctx.attr.copts),
            extra_link_args = repr(ctx.attr.linkopts),
            extension = extension,
        ),
    )

    return cffibuild

_SETUP_PY_TEMPLATE = """
from setuptools import setup

setup(
    name="{package_name}",
    version="1",
    cffi_modules=["_cffibuild.py:__ffi__"],
    zip_safe=False,
)
"""

def _gen_setup_py(ctx):
    setup_py = ctx.actions.declare_file("setup.py")
    ctx.actions.write(
        output = setup_py,
        content = _SETUP_PY_TEMPLATE.format(
            package_name = ctx.label.name,
        ),
    )
    return setup_py

def _cffi_module_impl(ctx):
    cffibuild_py = _gen_cffibuild_py(ctx)
    setup_py = _gen_setup_py(ctx)

    return DefaultInfo(
        files = depset([
            ctx.file.cdef,
            ctx.file.source,
            cffibuild_py,
            setup_py,
        ]),
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
            contents["cpython-38"] = [module_name + ".abi3.so"]
    dbx_py_local_piplib(
        name = name,
        provides = [module_name],
        contents = contents,
        srcs = [":" + cffi_name],
        deps = ["//pip/cffi"] + deps,
        visibility = visibility,
        python2_compatible = python2_compatible,
        python3_compatible = python3_compatible,
        setup_requires = ["//pip/cffi"],
        ignore_missing_static_libraries = ignore_missing_static_libraries,
        tags = tags,
        import_test_tags = import_test_tags,
    )
