from abc import abstractmethod
from typing import Iterable


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
