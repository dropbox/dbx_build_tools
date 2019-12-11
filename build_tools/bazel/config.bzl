DbxStringValue = provider(fields = ["value"])

def _dbx_string_value_impl(ctx):
    return [DbxStringValue(value = ctx.attr.value)]

dbx_string_value = rule(
    implementation = _dbx_string_value_impl,
    attrs = {
        "value": attr.string(mandatory = True),
    },
)
"""A trivial rule that simply exports a string attribute as a provider. This is
useful for injecting configuration into Starlark rules.

Args:
  value: Any string you want.
"""
