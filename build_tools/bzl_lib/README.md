# bzl
## Development
### Flow
- `bzl.py`
    - `core.py`
        - `<subparsers>`

# bzl gen
## Run the tool
```bash
bzl tool //build_tools:bzl-gen . --verbose # --verbose is to avoid using sqpkg package version and build the actual repo version instead
```

## describe-generator
To learn more about each code generator used by `bzl-gen` use the following command
```bash
bzl tool //build_tools:bzl-gen . --describe_generator
# <lists all available generators>
bzl tool //build_tools:bzl-gen . --describe_generator ProtoGenerator
#ProtoGenerator: This creates intermediate BUILD.gen_build_proto~ files and triggers
#    proto code-gen.  To specific which language(s) to generate proto for,
#    include the following in BUILD.in:
#        GENERATE_PROTO_FOR = [<string list of languages>]
bzl tool //build_tools:bzl-gen . --describe_generator __BuildMarkdownTable
# | name | description | doc_link | file |
# | --- | --- | --- | --- | --- |
# | ProtoGenerator |  This creates intermediate BUILD.gen_build_proto~ files and triggers proto code-gen | https://dropbox-kms.atlassian.net/wiki/spaces/BUILDTOOLCHAINS/pages/697107300/ProtoGenerator | gen_build_proto.py |
# | StoneBuildGenerator |  This creates BUILD files for directories under atlas. |  | gen_build_stone.py |
# | GoBuildGenerator |  This creates intermediate BUILD.gen-build-go files which contains various go targets. bzl gen will consume the intermediate files to generate the fully merged BUILD files. |  | gen_build_go.py |
# | PyBuildGenerator |  This creates intermediate BUILD.gen_build_py files which contains dbx_py targets. The targets' deps are auto-populated if the target has autogen_deps set to True. bzl gen will consume the intermediate files to generate the fully merged BUILD files. | https://dropbox-kms.atlassian.net/wiki/spaces/BUILDTOOLCHAINS/pages/699400327/bzl+gen+-+Python | gen_build_py.py |
# | AllProtoAndDwsDescriptorGenerator |  Create a genrule that concatenates all of the proto descriptors into one big proto, and generates the dws py client |  | gen_build_proto.py |
# | MagicMirrorPipBuildGenerator |  This updates the magic mirror config file given a pip BUILD file | https://dropbox-kms.atlassian.net/wiki/spaces/BUILDTOOLCHAINS/pages/699465818/bzl+gen+-+PIP | gen_build_pip_magic_mirror.py |
# | RustBuildGenerator |  This creates intermediate BUILD.in-gen-rust~ files which contains rust targets with 'srcs' and `deps` attributes populated. bzl gen will consume the intermediate files to generate the fully merged BUILD files. |  | gen_build_rust.py |
```

## Development Guide
https://dropbox-kms.atlassian.net/wiki/spaces/DEVINFRA/pages/686556597/Development+Guides+bzl+gen

## Profiling
The `BZL_DEBUG` command is helpful for getting additional metrics on the various generators that are run.
`BZL_DEBUG=1 bzl gen ... 2>bzl.debug`
### Example Output
```
> cat bzl.debug
installed: team/build-infra-team/bzl.sqfs/20221010T205016Z-7134ba59ce120a18ae79c054ab41f45bf731b1d3ba48afba7ce23adf0e2e0739
Timers:
    total_duration_ms: 1867ms
    bzl_checks_ms: 0ms
    bzl_sqfs_bootstrap_ms: 1775ms
Extra Attributes:
    instance_type: m6i.2xlarge
exec: /sqpkg/team/build-infra-team/bzl/bzl gen ...
Timers:
    total_duration_ms: 45ms
    bzl_bootstrap_ms: 0ms
    bzl_sqpkg_bootstrap_ms: 1775ms
Extra Attributes:
    instance_type: m6i.2xlarge
exec: /sqpkg/team/build-infra-team/bzl/bzl-gen --bazel-path bazel ...
Timers:
    total_duration_ms: 140532ms
Cumulative rates:
    bzl_gen__ProtoGenerator_init_ms: 0
    ...
    bzl_gen_ProtoGenerator_ms: 137803
    bzl_gen_ProtoGenerator_called: 1
Extra Attributes:
    instance_type: m6i.2xlarge
```
