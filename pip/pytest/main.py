import os
import sys

import pytest

from importlib_metadata import MetadataPathFinder


# The only zip dist we use is the stdlib, which won't have the packages we are looking for.
# Skipping that path saves around 1s on pytest startup time.
class MetadataImporter(MetadataPathFinder):
    def find_distributions(self, context=MetadataPathFinder.Context()):  # type: ignore[no-untyped-def]
        path = [p for p in context.path if not p.endswith(".zip")]
        return super(MetadataImporter, self).find_distributions(
            MetadataPathFinder.Context(name=context.name, path=path)
        )


sys.meta_path = [r for r in sys.meta_path if not hasattr(r, "find_distributions")]
sys.meta_path.insert(0, MetadataImporter())

__file__ = "py.test"
sys.argv[0] = sys.argv[0].replace("main.py", "py.test")

code = pytest.main()
sys.stdout.flush()
sys.stderr.flush()
os._exit(code)
