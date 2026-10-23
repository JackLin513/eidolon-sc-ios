"""A producer's schedule is theirs (GLOSSARY.md「日程」): deleted with all their data, while
each week's jobs, the same for everyone, stay; deleting one of their conversations leaves it
be."""

import sqlite3
from pathlib import Path

from eidolon.config import Settings
from tests.conftest import ClientFactory
from tests.fakes import FakeClock, FakeLLM
from tests.test_conversation_events import hang_up
from tests.test_schedule_saving import WEDNESDAY_AFTERNOON, WEEK, placed, publish, save
from tests.test_schedule_weeks import schedule
from tests.test_text_turn import send_turn, start_conversation

REPLY = ["<ja>はいっ</ja><zh>好的</zh>"]


def counts(database: Path) -> tuple[int, int]:
    """How many placements there are, and how many of the weeks' jobs."""
    with sqlite3.connect(database) as db:
        return tuple(
            db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            for table in ("schedule_placements", "weekly_jobs")
        )


async def test_deleting_the_user_deletes_their_schedule_and_leaves_the_weeks_jobs(
    make_client: ClientFactory, settings: Settings
):
    clock = FakeClock(WEDNESDAY_AFTERNOON)
    client = make_client(FakeLLM(), clock=clock)
    friend = make_client(FakeLLM(), "friend", clock=clock)
    publish(settings.database_path, WEEK, ("lesson", 1, None))
    for each in (client, friend):
        await save(each, WEEK, placed("lesson", 4, 0))

    res = await client.post("/api/account/delete", json={"confirm": True})

    assert res.status_code == 204
    assert counts(settings.database_path) == (1, 1)
    assert (await schedule(friend))["this_week"]["placements"] == [placed("lesson", 4, 0)]


async def test_deleting_a_conversation_leaves_the_schedule(
    make_client: ClientFactory, settings: Settings
):
    client = make_client(FakeLLM(REPLY), clock=FakeClock(WEDNESDAY_AFTERNOON))
    publish(settings.database_path, WEEK, ("lesson", 1, None))
    await save(client, WEEK, placed("lesson", 4, 0))
    past = await start_conversation(client)
    await send_turn(client, past, "周五上午有课吧")
    hang_up(settings.database_path, past)
    await start_conversation(client)

    assert (await client.delete(f"/api/conversations/{past}")).status_code == 204
    assert (await schedule(client))["this_week"]["placements"] == [placed("lesson", 4, 0)]
