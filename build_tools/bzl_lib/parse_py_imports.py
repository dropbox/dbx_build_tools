# mypy: allow-untyped-defs, no-check-untyped-defs
from __future__ import print_function

import ast
import os


def normalize_module(src, module_path):
    # type: (str, str) -> str
    if not module_path.startswith("."):
        return module_path

    orig_module_path = module_path

    target_dir = os.path.dirname(src)
    relative_to = target_dir.split(os.path.sep)
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


def parse_imports(workspace_dir, src):
    with open(os.path.join(workspace_dir, src), "rb") as f:
        content = f.read()

    try:
        parsed = ast.parse(content, src)
    except Exception:
        print("Failed to parse", src)
        raise

    import_set = set()
    from_set = set()
    for node in ast.walk(parsed):
        if isinstance(node, ast.Import):
            for entry in node.names:
                import_set.add(normalize_module(src, entry.name))
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                prefix = ("." * node.level) + node.module
            else:
                assert node.level > 0, "Programming error"
                prefix = "." * (node.level - 1)
            for entry in node.names:
                from_set.add(normalize_module(src, prefix + "." + entry.name))

    return import_set, from_set
