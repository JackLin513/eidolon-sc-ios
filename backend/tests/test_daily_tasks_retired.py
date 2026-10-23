"""The daily tasks retired (GLOSSARY.md「运行记录」「看板」): the activity records of daily tasks
done, and their rollups, deleted once as the backend starts, whatever else is recorded left
as it is; starting again on it, nothing more to delete. The records of a database from
before, put straight into it, as the backend starting on it finds them."""

import sqlite3
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager, closing
from datetime import timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from eidolon import database
from eidolon.activity import ActivityLog
from eidolon.dashboard import SPANS, stretches
from tests.conftest import activity_in
from tests.fakes import START, FakeClock


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
