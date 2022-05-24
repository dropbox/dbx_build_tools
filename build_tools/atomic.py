from __future__ import annotations

import os
import time

from typing import Text


# Write a small file mostly atomically. Don't bother to sync directory
# metadata.
def atomic_write(fname: Text, data: bytes) -> None:
    tmpname = fname + "-%s" % int(time.time() * 1e9)
    with open(tmpname, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.rename(tmpname, fname)
