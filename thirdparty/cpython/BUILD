load("@bazel_tools//tools/python:toolchain.bzl", "py_runtime_pair")
load(
    "//build_tools/py:toolchain.bzl",
    "CPYTHON_38_TOOLCHAIN_NAME",
    "CPYTHON_39_TOOLCHAIN_NAME",
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
    name = "cpython-38",
    build_tag = "cpython-38",
    exe_file = "@org_python_cpython_38//:bin/python",
    headers = "@org_python_cpython_38//:include_headers",
    major_python_version = 3,
    runtime = "@org_python_cpython_38//:runtime",
)

dbx_py_toolchain(
    name = "cpython-38-py_toolchain",
    interpreter = ":cpython-38",
    pyc_compile = "//build_tools/py:py3_compile",
)

toolchain(
    name = "drte-v3-38-toolchain",
    exec_compatible_with = DRTEV3_LINUX64_CONSTRAINTS,
    target_compatible_with = DRTEV3_LINUX64_CONSTRAINTS,
    toolchain = ":cpython-38-py_toolchain",
    toolchain_type = CPYTHON_38_TOOLCHAIN_NAME,
)

toolchain(
    name = "drte-off-38-toolchain",
    toolchain = ":cpython-38-py_toolchain",
    toolchain_type = CPYTHON_38_TOOLCHAIN_NAME,
)

py_binary(
    name = "zip-stdlib",
    srcs = ["zip_stdlib.py"],
    main = "zip_stdlib.py",
    visibility = ["//visibility:public"],
)

dbx_py_interpreter(
    name = "cpython-39",
    build_tag = "cpython-39",
    exe_file = "@org_python_cpython_39//:bin/python",
    headers = "@org_python_cpython_39//:include_headers",
    major_python_version = 3,
    runtime = "@org_python_cpython_39//:runtime",
)

dbx_py_toolchain(
    name = "cpython-39-py_toolchain",
    interpreter = ":cpython-39",
    pyc_compile = "//build_tools/py:py3_compile",
)

toolchain(
    name = "drte-v3-39-toolchain",
    exec_compatible_with = DRTEV3_LINUX64_CONSTRAINTS,
    target_compatible_with = DRTEV3_LINUX64_CONSTRAINTS,
    toolchain = ":cpython-39-py_toolchain",
    toolchain_type = CPYTHON_39_TOOLCHAIN_NAME,
)

toolchain(
    name = "drte-off-39-toolchain",
    toolchain = ":cpython-39-py_toolchain",
    toolchain_type = CPYTHON_39_TOOLCHAIN_NAME,
)

# This is a substitute for Modules/getbuildinfo.c.
cc_library(
    name = "buildinfo",
    srcs = ["bazel_buildinfo.c"],
    linkstamp = "bazel_linkstamp.cc",
    visibility = ["//visibility:public"],
)
