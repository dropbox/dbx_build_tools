load("//build_tools/sh:sh.bzl", "dbx_sh_test")

# Used to wrap a test target (passed as bin), and generates a Junit XML file based on results
def dbx_generated_junit_test_wrapper(name, bin, args = [], data = [], fail_stdout = True, fail_stderr = False, size = None):
    wrapper_args = [
        "--junit_suite_name",
        native.package_name(),
        "--junit_class_name",
        native.package_name(),
        "--junit_test_name",
        name,
    ]

    if fail_stdout:
        wrapper_args.append("--fail_stdout")
    if fail_stderr:
        wrapper_args.append("--fail_stderr")

    dbx_sh_test(
        name = name,
        srcs = ["//build_tools/junit:junit_wrapper"],
        args = wrapper_args + [
            "$(location {})".format(bin),
        ] + args,
        data = data + [bin],
        size = size,
    )
