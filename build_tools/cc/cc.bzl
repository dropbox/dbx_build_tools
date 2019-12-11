def prefer_pic_library_impl(ctx):
    # When -c opt is specified, cc_library rules produce both .a and .pic.a
    # outputs. We want the .pic.a file, but cc.libs gives us the .a file.
    pic_library_file = None
    for f in ctx.files.library:
        if f.basename.endswith(".pic.a"):
            pic_library_file = f
        elif f.basename.endswith(".a") and pic_library_file == None:
            pic_library_file = f

    return struct(files = depset([pic_library_file]))

prefer_pic_library = rule(
    implementation = prefer_pic_library_impl,
    attrs = {
        "library": attr.label(),
    },
)

# requires at least one "dbx-shelflife-version:name=version" tag. from
# those tags, use a genrule to produce the dep versions file, and then
# generate a native cc_{library,binary} rule with a `data` depedency on the
# generated dep version file.
def _dbx_thirdparty_cc_library_or_binary(is_lib, *args, **kwargs):
    tag_format = "dbx-shelflife-version:name=version"
    bad_tag_msg = 'please use tag format "%s"' % (tag_format)
    versioned_deps = []
    tags = kwargs.get("tags", [])
    for tag in tags:
        if tag.startswith("dbx-shelflife-version"):
            parts = tag.split(":")
            if len(parts) != 2:
                fail(bad_tag_msg)
            parts = parts[-1].split("=")
            if len(parts) != 2:
                fail(bad_tag_msg)
            name = parts[0].strip()
            version = parts[1].strip()
            if (not name) or (not version):
                fail(bad_tag_msg)
            versioned_deps += [
                struct(type = "thirdparty", name = name, version = version).to_json(),
            ]
    target_name = kwargs["name"]
    if not versioned_deps:
        err_msg = "please annotate target %r with at least one %r tag" % (target_name, tag_format)
        fail(err_msg)
    versioned_deps_filename = "%s.dep_versions" % (target_name)
    generate_versioned_deps_rule_name = "generate_%s" % (versioned_deps_filename)
    data = kwargs.get("data", [])
    data.append(generate_versioned_deps_rule_name)
    kwargs["data"] = data
    content = "[" + ",".join(list(versioned_deps)) + "]"
    native.genrule(
        name = generate_versioned_deps_rule_name,
        outs = [versioned_deps_filename],
        cmd = "echo '%s' > $@" % (content),
    )
    if is_lib:
        native.cc_library(*args, **kwargs)
    else:
        native.cc_binary(*args, **kwargs)

def dbx_thirdparty_cc_library(*args, **kwargs):
    _dbx_thirdparty_cc_library_or_binary(True, *args, **kwargs)

def dbx_thirdparty_cc_binary(*args, **kwargs):
    _dbx_thirdparty_cc_library_or_binary(False, *args, **kwargs)
