""" This file is separate from build_tools.bazel_utils because it is owned by web-platform

This would be within build_tools/bzl_lib/dbx/ but we need this logic when validating our targets for bzl gen, and the logic for that is in build_tools/bazel_utils.py
"""

MYPY = False
if MYPY:
    from typing import Optional, Text


def target_to_npm_name(target):
    # type: (Text) -> Optional[Text]
    if "/npm/" not in target:
        return None

    end = target.index(":") if ":" in target else len(target)

    npm_name = target[target.index("/npm/") + len("/npm/") : end]
    if npm_name.startswith("at_"):
        npm_name = "@" + npm_name[3:]

    if _looks_like_npm_name(npm_name):
        return npm_name
    else:
        return None


def _looks_like_npm_name(npm_name):
    # type: (Text) -> bool
    """Names of npm packages are either of the form <foo> or @<foo>/<bar>"""

    return (npm_name.startswith("@") and npm_name.count("/") == 1) or (
        not npm_name.startswith("@") and npm_name.count("/") == 0
    )
