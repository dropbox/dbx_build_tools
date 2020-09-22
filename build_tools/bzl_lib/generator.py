import dataclasses

from abc import abstractmethod
from typing import Iterable


@dataclasses.dataclass(frozen=True)
class Config:
    """
    Shared configuration for Generators.
    """

    # Enable verbose logging output.
    verbose: bool

    # Don't do recursive dependency generation; only generate BUILD files for the specified packages.
    skip_deps_generation: bool

    # Run as completely as possible without actually making changes.
    # NOTE: No reliable guarantee that all generators honor dry_run.
    dry_run: bool

    # Whether Magic Mirror should be used instead of external package sources.
    use_magic_mirror: bool

    # Path to the bazel tool. Should not be necessary in any reasonable case; generators
    # should be built with any required dependnecy already, and they exist to create BUILD files,
    # so they shouldn't be assuming a correct or complete BUILD graph when they run.
    bazel_path: str


class Generator:
    @abstractmethod
    def regenerate(self, bazel_targets: Iterable[str]) -> None:
        """
        Given a list of bazel targets, generate suffixed intermediate BUILD file fragments
        for those targets so that they may be later merged to a final complete BUILD file.
        Any BUILD file fragments generated should be recorded in the generated_files dictionary
        passed to the constructor.
        """
        pass
