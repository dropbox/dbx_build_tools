import os

from typing import Dict, Optional, Set, Tuple

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
