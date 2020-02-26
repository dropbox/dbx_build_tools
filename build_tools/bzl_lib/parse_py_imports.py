# mypy: allow-untyped-defs, no-check-untyped-defs
from __future__ import print_function

import ast
import os

from typing import Any, Union

from build_tools.py.python_encoding import decode_python_encoding
from typed_ast import ast27


def normalize_module(src, module_path):
    # type: (str, str) -> str
    if not module_path.startswith("."):
        return module_path

    orig_module_path = module_path

    target_dir = os.path.dirname(src)
    relative_to = target_dir.split("/")
    module_path = module_path[1:]

    while module_path.startswith("."):
        assert len(relative_to) > 0, "Bad relative path (%s) found in //%s" % (
            orig_module_path,
            target_dir,
        )
        relative_to = relative_to[:-1]
        module_path = module_path[1:]

    normalized_path = ".".join(relative_to)
    if module_path:
        normalized_path += "." + module_path

    assert normalized_path, "Programming error (%s, %s) => %s" % (
        src,
        orig_module_path,
        normalized_path,
    )

    return normalized_path


def parse_imports(workspace_dir, src, py3_compatible=True):
    with open(os.path.join(workspace_dir, src), "rb") as f:
        content = f.read()

    if py3_compatible:
        ast_module: Any = ast
        content_to_parse: Union[bytes, str] = content
    else:
        # When using the typed_ast parser we have to manually deal with python encoding.
        content_to_parse = decode_python_encoding(content)
        ast_module = ast27

    try:
        parsed = ast_module.parse(content_to_parse, src)
    except Exception:
        print("Failed to parse", src)
        raise

    import_set = set()
    from_set = set()
    for node in ast_module.walk(parsed):
        if isinstance(node, ast_module.Import):
            for entry in node.names:
                import_set.add(normalize_module(src, entry.name))
        elif isinstance(node, ast_module.ImportFrom):
            if node.module:
                prefix = ("." * node.level) + node.module
            else:
                assert node.level > 0, "Programming error"
                prefix = "." * (node.level - 1)
            for entry in node.names:
                from_set.add(normalize_module(src, prefix + "." + entry.name))

    return import_set, from_set
