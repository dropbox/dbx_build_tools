import asyncio
import pytest

from typing import Generator

_ran = False

# If pytest-asyncio isn't working, then the test will "run" but not actually await the
# result. Then pytest will exit before it finishes. But if asyncio is working, then the
# coroutine should finish and _ran should be true.
@pytest.fixture(scope="session", autouse=True)
def assert_asyncio_test_runs() -> Generator[None, None, None]:
    yield
    assert _ran


async def test_asyncio() -> None:
    await asyncio.sleep(1)
    global _ran
    _ran = True
