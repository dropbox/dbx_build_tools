load(
    "//build_tools/py:toolchain.bzl",
    "CPYTHON_27_TOOLCHAIN_NAME",
    "CPYTHON_37_TOOLCHAIN_NAME",
    "dbx_py_interpreter",
    "dbx_py_toolchain",
)
load(
    "//thirdparty/cpython:constants.bzl",
    "DRTEV3_LINUX64_CONSTRAINTS",
)

exports_files([
    "zip_stdlib.py",
    "symbols.lds",
    "gen_2to3_grammar.py",
])

config_setting(
    name = "use-bazel-cpython",
    values = {
        "define": "cpython=bazel",
    },
)

dbx_py_interpreter(
    name = "cpython-27",
    build_tag = "cpython-27",
    exe_file = "@org_python_cpython_27//:bin/python",
    headers = "@org_python_cpython_27//:include_headers",
    runtime = "@org_python_cpython_27//:runtime",
)

dbx_py_toolchain(
    name = "cpython-27-py_toolchain",
    dbx_importer = "//build_tools/py:dbx_importer",
    interpreter = ":cpython-27",
    pyc_compile = "//build_tools/py:dbx_compile",
)

toolchain(
    name = "drte-v3-27-toolchain",
    exec_compatible_with = DRTEV3_LINUX64_CONSTRAINTS,
    target_compatible_with = DRTEV3_LINUX64_CONSTRAINTS,
    toolchain = ":cpython-27-py_toolchain",
    toolchain_type = CPYTHON_27_TOOLCHAIN_NAME,
)

toolchain(
    name = "drte-off-27-toolchain",
    toolchain = ":cpython-27-py_toolchain",
    toolchain_type = CPYTHON_27_TOOLCHAIN_NAME,
)

dbx_py_interpreter(
    name = "cpython-37",
    build_tag = "cpython-37",
    exe_file = "@org_python_cpython_37//:bin/python",
    headers = "@org_python_cpython_37//:include_headers",
    major_python_version = 3,
    runtime = "@org_python_cpython_37//:runtime",
)

dbx_py_toolchain(
    name = "cpython-37-py_toolchain",
    interpreter = ":cpython-37",
    pyc_compile = "//build_tools/py:py3_compile_37",
)

toolchain(
    name = "drte-v3-37-toolchain",
    exec_compatible_with = DRTEV3_LINUX64_CONSTRAINTS,
    target_compatible_with = DRTEV3_LINUX64_CONSTRAINTS,
    toolchain = ":cpython-37-py_toolchain",
    toolchain_type = CPYTHON_37_TOOLCHAIN_NAME,
)

toolchain(
    name = "drte-off-37-toolchain",
    toolchain = ":cpython-37-py_toolchain",
    toolchain_type = CPYTHON_37_TOOLCHAIN_NAME,
)

py_binary(
    name = "zip-stdlib",
    srcs = ["zip_stdlib.py"],
    main = "zip_stdlib.py",
    visibility = ["//visibility:public"],
)

# This is a substitute for Modules/getbuildinfo.c.
cc_library(
    name = "buildinfo",
    srcs = ["bazel_buildinfo.c"],
    linkstamp = "bazel_linkstamp.c",
    visibility = ["//visibility:public"],
)
