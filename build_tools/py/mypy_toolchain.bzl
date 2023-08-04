load("//build_tools/py:toolchain.bzl", "cpython_310", "cpython_38", "cpython_39")

MYPY_38_TOOLCHAIN_NAME = "@dbx_build_tools//build_tools/py:mypy_toolchain_38"
MYPY_39_TOOLCHAIN_NAME = "@dbx_build_tools//build_tools/py:mypy_toolchain_39"
MYPY_310_TOOLCHAIN_NAME = "@dbx_build_tools//build_tools/py:mypy_toolchain_310"

MYPY_BUILD_TAG_TO_TOOLCHAIN_MAP = {
    cpython_38.build_tag: MYPY_38_TOOLCHAIN_NAME,
    cpython_39.build_tag: MYPY_39_TOOLCHAIN_NAME,
    cpython_310.build_tag: MYPY_310_TOOLCHAIN_NAME,
}

def _dbx_py_mypy_toolchain_impl(ctx):
    return [
        platform_common.ToolchainInfo(
            mypy_stubs = ctx.attr.mypy_stubs,
            typeshed = ctx.attr.typeshed,
            runtime = ctx.attr.runtime,
        ),
    ]

dbx_py_mypy_toolchain = rule(
    _dbx_py_mypy_toolchain_impl,
    attrs = {
        "mypy_stubs": attr.label(mandatory = True),
        "typeshed": attr.label(mandatory = True),
        "runtime": attr.label(mandatory = True),
    },
)
