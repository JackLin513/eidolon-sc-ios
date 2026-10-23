"""The daily tasks retired (GLOSSARY.md「运行记录」「看板」「抽奖」「成就」): the activity records
of daily tasks done, and their rollups, deleted once as the backend starts, whatever else is
recorded left as it is, and so is their progress, the rewards given and the achievements
kept; starting again on it, nothing more to delete. A turn or a gift is rewarded with nothing
but the achievements' stages it unlocks, and the gifts' state tells of no daily tasks. What
a database from before has, put straight into it, as the backend starting on it finds it;
the rest driven through the backend's external API, with the clock moved."""

import sqlite3
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager, closing
from dataclasses import replace
from datetime import timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from eidolon import database
from eidolon.activity import ActivityLog
from eidolon.config import Settings
from eidolon.dashboard import SPANS, stretches
from tests.conftest import ClientFactory, activity_in
from tests.fakes import FAKE_JUDGE, START, FakeClock, FakeLLM
from tests.test_gift_draws import state
from tests.test_gift_giving import CAKE, catalog, draw_them, given, holding  # noqa: F401
from tests.test_text_turn import send_turn, start_conversation

REPLY = ["<ja>はい</ja><zh>好的</zh>"]


@pytest.fixture
def settings(settings: Settings) -> Settings:
    """With the judge model, and affinity and gifts on in `.env`."""
    return replace(settings, judge=FAKE_JUDGE, affinity_and_gifts=True)


@asynccontextmanager
async def started(path: Path, clock: FakeClock) -> AsyncIterator[ActivityLog]:
    """The activity log, as the backend starting on the database at `path` opens it."""
    async with activity_in(path, clock) as log:
        await log.tally(clock.now, [clock.now])
        yield log


def kinds(path: Path) -> tuple[list[tuple[str, str]], list[tuple[str, str, int]]]:
    """The kind and result of each record, and of each rollup of them with its count."""
    with closing(database.connect(path)) as db:
        return (
            db.execute("SELECT kind, result FROM activity_records ORDER BY id").fetchall(),
            db.execute(
                "SELECT kind, result, SUM(count) FROM record_rollups GROUP BY 1, 2 ORDER BY 1, 2"
            ).fetchall(),
        )


async def test_the_daily_tasks_records_and_their_rollups_go_and_the_rest_stay(tmp_path: Path):
    path = tmp_path / "eidolon.db"
    clock = FakeClock(START)
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE users (id TEXT PRIMARY KEY)")
        db.execute("INSERT INTO users VALUES ('u1')")
    async with activity_in(path, clock) as log:
        turn = log.begin("turn", "u1", "mano", own_llm=False, exempt=False)
        await turn.finish("success")
        call = log.begin("call", "u1", "mano", own_llm=False, exempt=False)
        await call.finish("success", 120, "hung_up")
        await log.achievement_unlocked("u1", "mano", "turns", 1, clock.now)
        await log.character_complete("u1", "mano", clock.now)
        clock.advance(hours=1)
        span = SPANS["7d"]
        starts = stretches(clock.now, span, ZoneInfo("Asia/Shanghai"))
        before = await log.tally(clock.now - span.length, starts)
    kept = kinds(path)
    with closing(database.connect(path)) as db, db:
        # A daily task done, as a version from before recorded and rolled it up.
        db.execute(
            "INSERT INTO activity_records (kind, user_id, character_id, started_at, result)"
            " VALUES ('daily_task', 'u1', '', ?, 'one_turn')",
            ((START - timedelta(minutes=5)).timestamp(),),
        )
        db.execute(
            "INSERT INTO record_rollups SELECT length, start, 'daily_task', '', 'one_turn',"
            " own_keys, in_call, end_reason, affinity_level, out_of_line, manipulation, cooled,"
            " ended, answered, count FROM record_rollups WHERE kind = 'achievement'"
            " AND result = 'turns:1'"
        )
    assert kinds(path) != kept

    async with started(path, clock) as log:
        assert kinds(path) == kept
        assert await log.tally(clock.now - span.length, starts) == before
    async with started(path, clock) as log:
        assert kinds(path) == kept


async def test_their_progress_goes_and_the_rewards_and_achievements_stay(
    make_client: ClientFactory, settings: Settings
):
    clock = FakeClock()
    client = holding(make_client, clock, CAKE)
    await draw_them(client, clock, 1)
    await given(client, "cake")  # unlocks the first stage of her gifts achievement
    with sqlite3.connect(settings.database_path) as db:
        # Their progress, as a version from before kept it.
        db.execute(
            "CREATE TABLE daily_task_progress (user_id TEXT PRIMARY KEY REFERENCES users(id),"
            " day TEXT NOT NULL, turns INTEGER NOT NULL, gifts INTEGER NOT NULL)"
        )
        db.execute(
            "INSERT INTO daily_task_progress SELECT id, '2026-09-25', 1, 1 FROM users"
        )
    kept = rewards_and_stages(settings.database_path)

    make_client(FakeLLM(), clock=clock)
    gone = tables(settings.database_path)
    make_client(FakeLLM(), clock=clock)

    assert "daily_task_progress" not in gone
    assert "daily_task_progress" not in tables(settings.database_path)
    assert rewards_and_stages(settings.database_path) == kept != ([], [])


def tables(path: Path) -> set[str]:
    with sqlite3.connect(path) as db:
        return {name for (name,) in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}


def rewards_and_stages(path: Path) -> tuple[list[tuple], list[tuple]]:
    """The rewards given, and the achievements' stages unlocked."""
    with sqlite3.connect(path) as db:
        return (
            db.execute("SELECT * FROM gift_rewards ORDER BY 1, 2").fetchall(),
            db.execute("SELECT * FROM achievement_stages ORDER BY 1, 2, 3").fetchall(),
        )


async def test_a_turn_is_rewarded_with_nothing_the_draws_as_they_were(
    make_client: ClientFactory,
):
    client = make_client(FakeLLM(REPLY), clock=FakeClock())
    conversation = await start_conversation(client)
    before = await state(client)

    done = (await send_turn(client, conversation, "你好"))[-1]
    after = await state(client)

    assert done["type"] == "done"
    assert done["rewarded"] is None
    assert after["draws"] == before["draws"]
    assert "daily_tasks" not in after
    assert "renews_at" not in after


async def test_a_gift_is_rewarded_only_with_the_stages_it_unlocks(make_client: ClientFactory):
    clock = FakeClock()
    client = holding(make_client, clock, CAKE, CAKE)
    await draw_them(client, clock, 2)

    at = clock.now
    first = await given(client, "cake")
    clock.advance(days=1)
    draws = (await state(client))["draws"]
    second = await given(client, "cake")

    assert first["rewarded"] == {
        "draws": 1,
        "reset_cards": 0,
        "achievements": [{"achievement": "gifts", "character_id": "mano", "stage": 1, "draws": 1}],
        "completed": [],
        "rewarded_at": at.isoformat(),
    }
    assert second["rewarded"] is None
    assert (await state(client))["draws"] == draws
