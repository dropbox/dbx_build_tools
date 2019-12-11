from __future__ import annotations

import os
import py_compile
import sys


def main() -> None:
    allow_failures = sys.argv[1] == "--allow-failures"
    items = sys.argv[2:]
    assert len(items) % 3 == 0
    n = len(items) // 3

    for src_path, short_path, dest_path in zip(
        items[:n], items[n : 2 * n], items[2 * n :]
    ):
        if not os.path.exists(os.path.dirname(dest_path)):
            os.mkdir(os.path.dirname(dest_path))

        try:
            py_compile.compile(
                file=src_path,
                dfile=short_path,
                cfile=dest_path,
                doraise=True,
                # typeshed doesn't know this exists
                invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH,
            )
        except py_compile.PyCompileError:
            if allow_failures:
                open(dest_path, "wb").close()
            else:
                print(src_path, "->", dest_path)
                raise


if __name__ == "__main__":
    main()
