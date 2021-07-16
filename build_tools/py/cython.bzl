# Copyright (c) 2020 Dropbox, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load("//build_tools/py:py.bzl", "dbx_py_local_piplib")

def _local_new_file(ctx, name):
    """
    Create a new file prefixed with the current label name
    """
    return ctx.actions.declare_file(ctx.label.name + "/" + name)

def _gen_ext_module(ctx):
    # First filter out files that should be run compiled vs. passed through.
    srcs = [src.path for src in ctx.files.srcs]
    py_srcs = []
    pyx_srcs = []
    pxd_srcs = []
    for src in srcs:
        if src.endswith(".pyx") or (src.endswith(".py") and
                                    src[:-3] + ".pxd" in srcs):
            pyx_srcs.append(src)
        elif src.endswith(".py"):
            py_srcs.append(src)
        else:
            pxd_srcs.append(src)

    if len(pyx_srcs) != 1:
        fail("expected to have exactly one pyx file")

    # Invoke cython to produce the shared object libraries.
    pyx_src = pyx_srcs[0]
    module_name = pyx_src.split(".")[0]
    cython_name = module_name + "_cython"
    cpp_src = cython_name + "/" + module_name + ".cpp"

    c_ext_module = _local_new_file(ctx, ctx.attr.module_name + ".cpp")
    ctx.actions.run(
        inputs = ctx.files.srcs,
        outputs = [c_ext_module],
        executable = ctx.executable._cython_binary,
        arguments = [
            "--cplus",
            pyx_src,
            "--output-file",
            c_ext_module.path,
        ],
        env = {
            "PYTHONHASHSEED": "0",
        },
        progress_message = "creating cython {}".format(ctx.attr.module_name),
    )
    return c_ext_module

SETUP_PY = """
from setuptools import find_packages, setup, Extension
setup(
    name='{package_name}',
    version='1',
    ext_modules=[
        Extension(
            name='{module_name}',
            sources=[{c_file}],
            include_dirs=['.'],
        )
    ],
    packages=list(find_packages()),
) """

def _gen_setup_py(ctx, main_c_file, c_files):
    setup_py = _local_new_file(ctx, "setup.py")
    prefix_len = len(setup_py.dirname) + 1

    ctx.actions.write(
        output = setup_py,
        content = SETUP_PY.format(
            package_name = ctx.label.name,
            module_name = ctx.attr.module_name,
            c_file = "'{}'".format(main_c_file.path[prefix_len:]) + "," + ",".join(["'{}'".format(file) for file in c_files]),
        ),
    )
    return setup_py

def _cython_module_impl(ctx):
    c_ext_module = _gen_ext_module(ctx)
    prefix_len = len(ctx.build_file_path) - len("BUILD")
    copies = []
    additional_c_files = []
    for src in ctx.files.srcs:
        if src.path.endswith(".py"):
            file_name = src.path[prefix_len:]
        elif src.path.endswith(".c") or src.path.endswith(".cc") or src.path.endswith(".cpp"):
            file_name = src.path
            additional_c_files.append(src.path)
        elif src.path.endswith(".h") or src.path.endswith(".hh") or src.path.endswith(".hpp"):
            file_name = src.path
        else:
            continue
        copy = _local_new_file(ctx, file_name)
        ctx.actions.run_shell(
            inputs = [src],
            outputs = [copy],
            arguments = [src.path, copy.path],
            command = 'cp "$1" "$2"',
        )
        copies.append(copy)

    setup_py = _gen_setup_py(
        ctx = ctx,
        main_c_file = c_ext_module,
        c_files = additional_c_files,
    )

    return struct(
        files = depset(
            [c_ext_module] +
            [setup_py] + copies,
        ),
    )

_cython_module = rule(
    implementation = _cython_module_impl,
    attrs = {
        "module_name": attr.string(
            mandatory = True,
        ),
        "srcs": attr.label_list(
            allow_files = True,
        ),
        "_cython_binary": attr.label(
            default = Label("@cython//:cython_binary"),
            cfg = "host",
            executable = True,
        ),
    },
)

def dbx_pyx_library(
        name,
        module_name = None,
        hidden_provides = None,
        deps = [],
        py_deps = [],
        srcs = [],
        pip_version = None,
        python3_compatible = True,
        visibility = None,
        **kwargs):
    if module_name == None:
        module_name = name

    py_srcs = []
    for src in srcs:
        if src.endswith(".py"):
            py_srcs.append(src)

    cython_name = module_name + "_cython"
    _cython_module(
        name = cython_name,
        module_name = module_name,
        srcs = srcs,
    )
    dbx_py_local_piplib(
        name = name,
        hidden_provides = hidden_provides,
        srcs = [":" + cython_name],
        deps = deps,
        pip_version = pip_version,
        python3_compatible = python3_compatible,
        visibility = visibility,
    )
