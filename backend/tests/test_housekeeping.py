"""Housekeeping: what ages out is deleted as the backend starts and every 10 minutes after,
off the event loop, each apart from the others."""

import asyncio
import threading

import pytest

from eidolon import housekeeping


def test_one_failing_keeps_none_of_the_others_from_tidying_up():
    tidied: list[str] = []

    def failing() -> None:
        raise RuntimeError("database is locked")

    housekeeping.tidy(failing, lambda: tidied.append("activity"))

    assert tidied == ["activity"]


async def test_it_tidies_up_as_it_starts_then_every_tick_off_the_event_loop(
    monkeypatch: pytest.MonkeyPatch,
):
    monkeypatch.setattr(housekeeping, "TICK", housekeeping.timedelta(seconds=0.01))
    loop = threading.get_ident()
    threads: list[int] = []
    tidying = asyncio.create_task(housekeeping.keep_tidy(lambda: threads.append(threading.get_ident())))

    await asyncio.sleep(0.1)
    tidying.cancel()

    assert len(threads) >= 2
    assert loop not in threads
