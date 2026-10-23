"""A job of hers done raises her affinity (GLOSSARY.md「日程」「好感度」): by `JOB_DONE_STEP`,
whatever the job, once its last slot has ended where the producer is then, not part-way. It is
counted as the producer's schedule is next read, by them or for a turn's prompt, once each
however often it is read or wherever the producer moves; only while affinity and schedules
are both on, those done while either was off counted once both are. As a gift does, it raises
her in a cooldown too, out of it at the thaw line, beyond the day's limit; told of to no one:
no conversation event, no activity record.

Driven through the backend's external API, the week's jobs kept beforehand in the database
(`publish`) and saved through the API before the clock is moved on; her affinity read from
the database, as only its tier is shown."""

import sqlite3
from dataclasses import replace
from datetime import timedelta
from pathlib import Path

import httpx
import pytest

from eidolon.affinity import NORMAL
from eidolon.config import Settings
from tests.conftest import ClientFactory
from tests.fakes import FAKE_JUDGE, FakeClock, FakeLLM
from tests.test_affinity import keep, status
from tests.test_delete_account import user_id
from tests.test_schedule_saving import WEEK, placed, publish, save
from tests.test_schedule_she_knows import EARLY_MONDAY
from tests.test_schedule_weeks import live_in
from tests.test_text_turn import send_turn, start_conversation

REPLY = ["<ja>はい</ja><zh>好的</zh>"]


@pytest.fixture
def settings(settings: Settings) -> Settings:
    """With the judge model, and affinity on in `.env`."""
    return replace(settings, judge=FAKE_JUDGE, affinity_and_gifts=True)


def affinity(database: Path, character: str = "mano") -> float:
    """The producer's affinity with the character as kept, the normal value if none is."""
    with sqlite3.connect(database) as db:
        row = db.execute(
            "SELECT value FROM affinities WHERE user_id = ? AND character_id = ?",
            (user_id(database, "producer"), character),
        ).fetchone()
    return row[0] if row else NORMAL


def count(database: Path, table: str) -> int:
    with sqlite3.connect(database) as db:
        return db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]


async def read(client: httpx.AsyncClient) -> None:
    assert (await client.get("/api/schedule")).status_code == 200


async def scheduled(
    make_client: ClientFactory,
    settings: Settings,
    clock: FakeClock,
    *jobs: tuple[str, int, int, int],
    character: str = "mano",
) -> httpx.AsyncClient:
    """A client that has saved the character's `jobs`, each its name, length, day and slot,
    on Monday early in the morning."""
    client = make_client(FakeLLM(REPLY, REPLY), clock=clock)
    publish(settings.database_path, WEEK, *((n, length, None) for n, length, _, _ in jobs),
            character=character)
    res = await save(client, WEEK, *(placed(n, day, slot) for n, _, day, slot in jobs))
    assert len(res.json()["saved"]) == len(jobs)
    return client


async def test_done_as_its_last_slot_ends_it_raises_her_once_and_tells_no_one(
    make_client: ClientFactory, settings: Settings
):
    database = settings.database_path
    clock = FakeClock(EARLY_MONDAY)
    client = await scheduled(make_client, settings, clock, ("拍摄广告", 2, 2, 0))
    events, records = count(database, "conversation_events"), count(database, "activity_records")

    clock.advance(days=2, hours=10)  # Wednesday 11:00, its first slot
    await read(client)
    first_slot = affinity(database)
    clock.advance(hours=6, minutes=59)  # 17:59, its second
    await read(client)
    second_slot = affinity(database)
    clock.advance(minutes=1)
    await read(client)
    done = affinity(database)
    await read(client)

    assert (first_slot, second_slot, done, affinity(database)) == (50.0, 50.0, 50.5, 50.5)
    assert count(database, "conversation_events") == events
    assert count(database, "activity_records") == records


async def test_a_turns_prompt_counts_it_too_before_her_affinity_is_read(
    make_client: ClientFactory, settings: Settings
):
    database = settings.database_path
    clock = FakeClock(EARLY_MONDAY)
    client = await scheduled(make_client, settings, clock, ("声乐课", 1, 0, 0))
    conversation = await start_conversation(client)
    clock.advance(hours=11)  # Monday 12:00

    await send_turn(client, conversation, "在吗")
    once = affinity(database)
    await send_turn(client, conversation, "还在吗")

    assert (once, affinity(database)) == (50.5, 50.5)
    assert count(database, "conversation_events") == 0


async def test_each_job_done_raises_her_the_same_whatever_its_length(
    make_client: ClientFactory, settings: Settings
):
    clock = FakeClock(EARLY_MONDAY)
    client = await scheduled(
        make_client, settings, clock, ("声乐课", 1, 0, 0), ("拍摄广告", 2, 0, 1), ("外景", 3, 1, 0)
    )
    clock.advance(days=2)

    await read(client)

    assert affinity(settings.database_path) == 51.5


async def test_done_while_affinity_is_off_it_is_counted_once_it_is_on(
    make_client: ClientFactory, settings: Settings
):
    clock = FakeClock(EARLY_MONDAY)
    await scheduled(make_client, settings, clock, ("声乐课", 1, 0, 0))
    clock.advance(days=1)
    off = make_client(FakeLLM(), clock=clock, settings=replace(settings, affinity_and_gifts=False))

    await read(off)
    while_off = affinity(settings.database_path)
    clock.advance(days=3)
    await read(make_client(FakeLLM(), clock=clock))

    assert (while_off, affinity(settings.database_path)) == (50.0, 50.5)


async def test_done_while_schedules_are_off_it_is_counted_once_they_are_on(
    make_client: ClientFactory, settings: Settings
):
    clock = FakeClock(EARLY_MONDAY)
    await scheduled(make_client, settings, clock, ("声乐课", 1, 0, 0))
    clock.advance(days=1)
    off = make_client(FakeLLM(REPLY), clock=clock, settings=replace(settings, schedule=False))

    await off.get("/api/schedule")
    await send_turn(off, await start_conversation(off), "在吗")
    while_off = affinity(settings.database_path)
    await read(make_client(FakeLLM(), clock=clock))

    assert (while_off, affinity(settings.database_path)) == (50.0, 50.5)


async def test_in_a_cooldown_it_raises_her_the_same_out_of_it_at_the_thaw_line(
    make_client: ClientFactory, settings: Settings
):
    database = settings.database_path
    clock = FakeClock(EARLY_MONDAY)
    client = await scheduled(make_client, settings, clock, ("声乐课", 1, 0, 0))
    await scheduled(make_client, settings, clock, ("组合排练", 1, 0, 1), character="kogane")
    clock.advance(days=1)
    keep(database, "producer", 9.6, clock.now, cooling=True)
    keep(database, "producer", 0, clock.now, character="kogane", cooling=True)

    await read(client)

    assert (affinity(database), affinity(database, "kogane")) == (10.1, 0.5)
    assert (await status(client)).json() == {"tier": "cold", "cooldown_until": None}
    assert (await status(client, "kogane")).json() == {
        "tier": "cold", "cooldown_until": (clock.now + timedelta(days=0.95)).isoformat(),
    }


async def test_it_is_done_where_the_producer_is_then_and_counted_once_wherever_they_move(
    make_client: ClientFactory, settings: Settings
):
    """Wednesday 20:00 in Shanghai is Thursday 00:00 in Auckland."""
    database = settings.database_path
    clock = FakeClock(EARLY_MONDAY)
    client = await scheduled(make_client, settings, clock, ("晚饭", 1, 2, 2))
    clock.advance(days=2, hours=19)

    await read(client)
    in_shanghai = affinity(database)
    await live_in(client, "Pacific/Auckland")
    await read(client)
    in_auckland = affinity(database)
    await live_in(client, "Asia/Shanghai")
    clock.advance(days=1)
    await read(client)

    assert (in_shanghai, in_auckland, affinity(database)) == (50.0, 50.5, 50.5)
