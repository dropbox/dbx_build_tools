from abc import abstractmethod
from typing import Iterable, Optional, Set


class Generator:
    @abstractmethod
    def regenerate(self, bazel_targets: Iterable[str]) -> Optional[Set[str]]:
        """
        Given a list of bazel targets, generate suffixed intermediate BUILD file fragments
        for those targets so that they may be later merged to a final complete BUILD file.
        Any BUILD file fragments generated should be recorded in the generated_files dictionary
        passed to the constructor.

        If there were changes outside of BUILD fragment generation that might require processing,
        the involved packages/directories should be returned as a Set.

        Most Generators should be exclusively generating BUILD fragments; such Generators should
        follow the convention of specifying a 'None' return type; the Optional return type
        here is to allow them to ignore the uncommon Set return case in their type signatures.
        """
        pass
