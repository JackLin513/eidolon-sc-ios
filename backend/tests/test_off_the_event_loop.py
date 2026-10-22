"""As many as `assembly.THREADS` may wait on threads at once."""

import asyncio
import threading

from eidolon.assembly import THREADS
from tests.conftest import ClientFactory
from tests.fakes import FakeLLM
from tests.test_live_config import start


async def test_as_many_as_32_wait_on_threads_at_once(make_client: ClientFactory):
    """However few the server's cores: a backup or data package taking minutes keeps no
    turn waiting for a thread."""
    client = make_client(FakeLLM())
    await start(client)
    all_there = threading.Barrier(THREADS, timeout=5)

    await asyncio.gather(*[asyncio.to_thread(all_there.wait) for _ in range(THREADS)])
