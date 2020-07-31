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
