from __future__ import annotations

import ast
import importlib
import os
import sys

DOCSTRING_STRIP_EXCEPTIONS = [
]


def main() -> None:
    allow_failures = sys.argv[1] == "--allow-failures"
    items = sys.argv[2:]
    assert len(items) % 3 == 0
    n = len(items) // 3

    for src_path, short_path, dest_path in zip(
        items[:n], items[n : 2 * n], items[2 * n :]
    ):
        try:
            if not os.path.exists(os.path.dirname(dest_path)):
                os.mkdir(os.path.dirname(dest_path))

            with open(src_path, "r") as f:
                src = f.read()

            if not any(lib in src_path for lib in DOCSTRING_STRIP_EXCEPTIONS):
                # Strip the docstrings to reduce binary size and memory usage.
                root = ast.parse(src)
                for node in ast.walk(root):
                    # https://github.com/python/cpython/blob/3.7/Lib/ast.py#L207
                    if (
                        isinstance(
                            node,
                            (
                                ast.AsyncFunctionDef,
                                ast.FunctionDef,
                                ast.ClassDef,
                                ast.Module,
                            ),
                        )
                        and node.body
                        and isinstance(node.body[0], ast.Expr)
                    ):
                        # These libraries assume the existence of docstrings on their own methods
                        # and provide decorators that deprecate methods by munging their docstring.
                        # TODO: remove these exceptions after sending patches upstream
                        if (
                            "pylons" in src_path
                            or "paste" in src_path
                            or "weberror" in src_path
                            or "notebook" in src_path
                        ):
                            new_docstring = " "
                        elif "scipy" in src_path:
                            # TODO remove if https://github.com/scipy/scipy/pull/10848 is merged
                            new_docstring = "Parameters\n%s"
                        else:
                            new_docstring = ""

                        if isinstance(node.body[0].value, ast.Str):
                            node.body[0].value.s = new_docstring
                        elif isinstance(node, ast.Constant) and isinstance(
                            node.body[0].value, str
                        ):
                            node.body[0].value = new_docstring

            co = compile(root, dest_path, "exec", dont_inherit=True)

            source_hash = importlib.util.source_hash(  # type: ignore
                src.encode("utf-8")
            )
            bytecode = importlib._bootstrap_external._code_to_hash_pyc(  # type: ignore
                co, source_hash, False
            )

            mode = importlib._bootstrap_external._calc_mode(src_path)  # type: ignore
            importlib._bootstrap_external._write_atomic(  # type: ignore
                dest_path, bytecode, mode
            )
        except Exception:
            if allow_failures:
                open(dest_path, "wb").close()
            else:
                print(src_path, "->", dest_path)
                raise


if __name__ == "__main__":
    main()
