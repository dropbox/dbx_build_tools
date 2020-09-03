from abc import abstractmethod
from typing import Iterable, Sequence


class Generator:
    def preprocess_targets(self, bazel_targets: Sequence[str]) -> Sequence[str]:
        """ Given the list of targets we plan to generate, do any preprocessing needed and return a new list of targets.  Preprocessing could including making folders with BUILD.in files for non-existant packages.
        """
        return bazel_targets

    @abstractmethod
    def regenerate(self, bazel_targets: Iterable[str]) -> None:
        """
        Given a list of bazel targets, generate suffixed intermediate BUILD file fragments
        for those targets so that they may be later merged to a final complete BUILD file.
        Any BUILD file fragments generated should be recorded in the generated_files dictionary
        passed to the constructor.
        """
        pass
