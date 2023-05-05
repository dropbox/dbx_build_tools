"""_summary_ This module contains functions for supporting the go:embed directive in our custom go rules
"""

def add_embedded_src(ctx, compile_args, compile_inputs_direct):
    """_summary_ Writes the contents of "embed_config" to a file annd adds it as a flag to the compiler

    Args:
        ctx:
        compile_args: The arguments passed to the Go Compiler
        compile_inputs_direct: The files that are inputs to the Go Compiler
    """

    # To avoid conflicts if there are multiple `dbx_go_*` rules in the same Bazel package
    embed_config_filename = "embed_config_{0}.json".format(ctx.label.name)
    embed_config_file = ctx.actions.declare_file(embed_config_filename)
    ctx.actions.write(embed_config_file, ctx.attr.embed_config)

    # NOTE: This is an undocumented API in
    # https://cs.opensource.google/go/go/+/refs/tags/go1.19:src/cmd/compile/internal/base/flag.go;l=127
    # It could potentially change as we migrate to higher Go versions
    compile_args.add("-embedcfg", embed_config_file.path)

    # Add the file as a necessary "src" file since it's needed for compilation
    compile_inputs_direct.append(embed_config_file)
