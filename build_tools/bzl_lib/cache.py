import json
import os
import sys
import time

from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

from build_tools import build_parser
from build_tools.bzl_lib.cfg import ALT_BUILD, BUILD_INPUT, DEFAULT_BUILD


class ParsedBuildFileCache(object):
    """keeps track of parsed BUILD and BUILD.in files"""

    def __init__(self, workspace_dir: str):
        self.workspace_dir = os.path.realpath(workspace_dir) + os.path.sep

        # (real or symlink) dir path -> (real_build_file, parsed entry)
        self.parsed_builds: Dict[str, Tuple[str, build_parser.BuildParser]] = {}
        self.parsed_bzls: Dict[str, Tuple[str, build_parser.BuildParser]] = {}

        # dir paths without BUILD(.bzl)
        self.empty_build_dirs: Set[str] = set()
        self.empty_bzl_dirs: Set[str] = set()

    def get_build(
        self, directory: str
    ) -> Tuple[str, Optional[build_parser.BuildParser]]:
        if directory in self.parsed_builds:
            return self.parsed_builds[directory]

        if directory in self.empty_build_dirs:
            return "", None

        build_file = os.path.join(directory, DEFAULT_BUILD)
        assert directory.startswith(
            self.workspace_dir
        ), "Trying to read {} outside of workspace: {}".format(DEFAULT_BUILD, directory)

        if not os.path.isfile(build_file):
            build_file = os.path.join(directory, ALT_BUILD)
            if not os.path.isfile(build_file):
                self.empty_build_dirs.add(directory)
                return "", None

        real_build_file = os.path.realpath(build_file)

        if build_file != real_build_file:  # symlink
            _, entry = self.get_build(os.path.dirname(real_build_file))
        else:
            entry = build_parser.parse_file(real_build_file)

        if entry:
            self.parsed_builds[directory] = (real_build_file, entry)
        else:
            self.empty_build_dirs.add(directory)

        return real_build_file, entry

    def get_bzl(self, directory: str) -> Tuple[str, Optional[build_parser.BuildParser]]:
        if not directory.endswith(os.path.sep):
            directory += os.path.sep

        if directory in self.parsed_bzls:
            return self.parsed_bzls[directory]

        if directory in self.empty_bzl_dirs:
            return "", None

        bzl_file = os.path.join(directory, BUILD_INPUT)
        assert directory.startswith(
            self.workspace_dir
        ), "Trying to read {} outside of workspace: {}".format(BUILD_INPUT, directory)

        if not os.path.isfile(bzl_file):
            self.empty_bzl_dirs.add(directory)
            return "", None

        real_bzl_file = os.path.realpath(bzl_file)

        if bzl_file != real_bzl_file:  # symlink
            _, entry = self.get_bzl(os.path.dirname(real_bzl_file))
        else:
            entry = build_parser.parse_file(real_bzl_file)

        if entry:
            self.parsed_bzls[directory] = (real_bzl_file, entry)
        else:
            self.empty_bzl_dirs.add(directory)

        return real_bzl_file, entry

    def get_bzl_or_build(
        self, directory: str
    ) -> Tuple[str, Optional[build_parser.BuildParser]]:
        filename, parsed = self.get_bzl(directory)
        if filename:
            return filename, parsed

        return self.get_build(directory)


_CACHE_BY_WORKSPACE: Dict[str, ParsedBuildFileCache] = {}


def get_build_file_cache(workspace_dir: str) -> ParsedBuildFileCache:
    if workspace_dir not in _CACHE_BY_WORKSPACE:
        _CACHE_BY_WORKSPACE[workspace_dir] = ParsedBuildFileCache(workspace_dir)

    return _CACHE_BY_WORKSPACE[workspace_dir]


def clear_build_file_cache(workspace_dir: str) -> None:
    if workspace_dir in _CACHE_BY_WORKSPACE:
        _CACHE_BY_WORKSPACE.pop(workspace_dir)


class JsonCache:
    ASSERT_KEYS_NAME = "__assert_keys__"

    def __init__(self, name: str, assert_keys: Dict[str, str] = {}) -> None:
        """
        Simple Json based cache. Cache files located in ~/.cache/bzl/
        NAME file name of the cache
        ASSERT_KEYS key values that are used to validate the cache.
                    They are compared against the cached values after loading,
                    if any of them differ the entire cache is cleared.
        """
        cache_dir = Path.home() / ".cache" / "bzl"
        Path(cache_dir).mkdir(parents=True, exist_ok=True)
        self.name = name
        self.file_name = cache_dir / name
        self._assert_keys = assert_keys
        self._cache: Dict[str, Any] = {}
        self._dirty = False

    def _read_cache_file(self) -> Dict[str, Any]:
        ret: Dict[str, Any] = {}
        self._dirty = True
        try:
            with open(self.file_name, "r") as f:
                ret = json.loads(f.read())
                self._dirty = False
        except FileNotFoundError:
            pass
        except json.JSONDecodeError:
            corrupted_filename = self.file_name.with_suffix(
                time.strftime(".%m_%d_%Y_%H_%M_%S_corrupted")
            )
            self.file_name.rename(corrupted_filename)
            print(
                f"ERROR: Corrupted cache file. Saved as: {corrupted_filename}",
                file=sys.stderr,
            )
        return ret

    def load(self) -> None:
        cache = self._read_cache_file()
        # invalidate cache if any value in assert_keys does not match
        assert_keys: Dict[str, str] = cache.get(JsonCache.ASSERT_KEYS_NAME, {})
        invalid = [
            name
            for name, val in self._assert_keys.items()
            if assert_keys.get(name) != val
        ]
        if assert_keys:
            del cache[JsonCache.ASSERT_KEYS_NAME]
        if invalid:
            print(f"{self.name} cache invalidated due to stale values for: {invalid}")
            self.delete_all()
        else:
            self._cache = cache

    def save(self) -> None:
        if not self._dirty:
            return
        cache = self._cache
        cache[JsonCache.ASSERT_KEYS_NAME] = self._assert_keys
        with open(self.file_name, "w") as f:
            f.write(json.dumps(cache, indent=1))
        self._dirty = False

    def __enter__(self) -> "JsonCache":
        self.load()
        return self

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        self.save()
        return None

    def get(self, key: str) -> Any:
        return self._cache.get(key)

    def get_all(self, keys: List[str]) -> List[Optional[str]]:
        return [self._cache.get(k) for k in keys]

    def put(self, key: str, value: Any) -> None:
        if self._cache.get(key) == value:
            return
        self._dirty = True
        self._cache[key] = value

    def put_all(self, values: Dict[str, str]) -> None:
        self._dirty = True
        self._cache.update(values)

    def delete(self, key: str) -> None:
        if key in self._cache:
            self._dirty = True
            del self._cache[key]

    def delete_all(self) -> None:
        self._dirty = True
        self._cache = {}
