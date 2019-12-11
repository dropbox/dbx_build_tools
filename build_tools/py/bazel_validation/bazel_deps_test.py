from contextlib import contextmanager
from io import BytesIO
from pathlib import Path
from typing import Any, cast, ContextManager, Generator

from build_tools.py.bazel_validation.bazel_deps import (
    flatten_provides,
    Import,
    parse_imports,
    SourceLocation,
    validate_bazel_deps,
)


def test_flatten_provides() -> None:
    assert flatten_provides(
        "//target", [("//foo", "main.py"), ("//foo", "lib.py"), ("//target", "main.py")]
    ) == {"main.py": "//target", "lib.py": "//foo"}


def test_validate_bazel_deps_valid() -> None:
    result = validate_bazel_deps(
        py2_compatible=False,
        py3_compatible=True,
        imports=[
            Import(
                module="dropbox.runfiles",
                location=SourceLocation(source_file=Path("foo.py"), lineno=5),
                is_from=False,
            ),
            Import(
                module="asyncio",
                location=SourceLocation(source_file=Path("foo.py"), lineno=6),
                is_from=False,
            ),
            Import(
                module="grpc.codes",
                location=SourceLocation(source_file=Path("foo.py"), lineno=7),
                is_from=False,
            ),
        ],
        primary_target="//target",
        provides_map={"dropbox.runfiles": "//dropbox/runfiles"},
        prefix_provides_map={"grpc": "//pip/grpc"},
    )
    assert not result.unresolved_imports
    assert not result.unused_targets


def test_validate_bazel_deps_valid_with_identifier() -> None:
    result = validate_bazel_deps(
        py2_compatible=False,
        py3_compatible=True,
        imports=[
            Import(
                module="dropbox.runfiles.data_path",
                location=SourceLocation(source_file=Path("foo.py"), lineno=5),
                is_from=True,
            ),
            Import(
                module="asyncio",
                location=SourceLocation(source_file=Path("foo.py"), lineno=6),
                is_from=False,
            ),
        ],
        primary_target="//target",
        provides_map={"dropbox.runfiles": "//dropbox/runfiles"},
        prefix_provides_map={},
    )
    assert not result.unresolved_imports
    assert not result.unused_targets


def test_validate_bazel_deps_invalid_with_identifier() -> None:
    result = validate_bazel_deps(
        py2_compatible=False,
        py3_compatible=True,
        imports=[
            Import(
                module="dropbox.runfiles.data_path",
                location=SourceLocation(source_file=Path("foo.py"), lineno=5),
                is_from=False,
            ),
            Import(
                module="asyncio",
                location=SourceLocation(source_file=Path("foo.py"), lineno=6),
                is_from=False,
            ),
        ],
        primary_target="//target",
        provides_map={"dropbox.runfiles": "//dropbox/runfiles"},
        prefix_provides_map={},
    )
    assert [i.module for i in result.unresolved_imports] == [
        "dropbox.runfiles.data_path"
    ]
    assert result.unused_targets == {"//dropbox/runfiles"}


def test_validate_bazel_deps_unused_target() -> None:
    result = validate_bazel_deps(
        py2_compatible=False,
        py3_compatible=True,
        imports=[
            Import(
                module="asyncio",
                location=SourceLocation(source_file=Path("foo.py"), lineno=6),
                is_from=False,
            ),
            Import(
                module="grpc.codes",
                location=SourceLocation(source_file=Path("foo.py"), lineno=7),
                is_from=False,
            ),
        ],
        primary_target="//target",
        provides_map={"dropbox.runfiles": "//dropbox/runfiles"},
        prefix_provides_map={"grpc": "//pip/grpc"},
    )
    assert not result.unresolved_imports
    assert result.unused_targets == {"//dropbox/runfiles"}


def test_validate_bazel_deps_unused_target_prefix() -> None:
    result = validate_bazel_deps(
        py2_compatible=False,
        py3_compatible=True,
        imports=[
            Import(
                module="dropbox.runfiles",
                location=SourceLocation(source_file=Path("foo.py"), lineno=5),
                is_from=False,
            ),
            Import(
                module="asyncio",
                location=SourceLocation(source_file=Path("foo.py"), lineno=6),
                is_from=False,
            ),
        ],
        primary_target="//target",
        provides_map={"dropbox.runfiles": "//dropbox/runfiles"},
        prefix_provides_map={"grpc": "//pip/grpc"},
    )
    assert not result.unresolved_imports
    assert result.unused_targets == {"//pip/grpc"}


def test_validate_bazel_deps_unresolved_import() -> None:
    result = validate_bazel_deps(
        py2_compatible=False,
        py3_compatible=True,
        imports=[
            Import(
                module="dropbox.runfiles",
                location=SourceLocation(source_file=Path("foo.py"), lineno=5),
                is_from=False,
            ),
            Import(
                module="asyncio",
                location=SourceLocation(source_file=Path("foo.py"), lineno=6),
                is_from=False,
            ),
            Import(
                module="grpc.codes",
                location=SourceLocation(source_file=Path("foo.py"), lineno=7),
                is_from=False,
            ),
        ],
        primary_target="//target",
        provides_map={},
        prefix_provides_map={"grpc": "//pip/grpc"},
    )
    assert [i.module for i in result.unresolved_imports] == ["dropbox.runfiles"]
    assert not result.unused_targets


PY2_FILE_CONTENT = b"""
from dropbox.runfiles import data_path
import grpc

print('py2 only')
"""


PY3_FILE_CONTENT = b"""
from dropbox.runfiles import data_path
import grpc

async def foo() -> None:
    pass
"""


class MockPath:
    def __init__(self, file_content: bytes):
        self.file_content = file_content

    def open(self, mode: str = "r") -> ContextManager[BytesIO]:
        @contextmanager
        def c(*args: Any, **kwargs: Any) -> Generator[BytesIO, None, None]:
            yield BytesIO(self.file_content)

        return c()


def test_parse_imports_py2() -> None:
    imports = parse_imports(
        source_file=cast(Path, MockPath(PY2_FILE_CONTENT)),
        py2_compatible=True,
        py3_compatible=False,
    )
    assert set(i.module for i in imports) == set(["dropbox.runfiles.data_path", "grpc"])


def test_parse_imports_py3() -> None:
    imports = parse_imports(
        source_file=cast(Path, MockPath(PY3_FILE_CONTENT)),
        py2_compatible=False,
        py3_compatible=True,
    )
    assert set(i.module for i in imports) == set(["dropbox.runfiles.data_path", "grpc"])
