"""Visits to the bar in the activity records and on the dashboard (GLOSSARY.md「运行记录」
「看板」「光顾」): one record for each visit, written as it is over, saying how it turned out
(done, left, done away with by another, failed, or rejected over the limit), whose LLM wrote
it and who came, with the service calls of all its calls under it; nothing of what was said.
The dashboard's「酒吧」section counts those begun, done and failed over its range, where the
bar is open or any were recorded in it. A visit ended stopped before a call that failed is
failed, and given back if nothing was written by then.

Driven through the backend's external API, the records read from the database."""

import asyncio
import sqlite3
from dataclasses import replace
from pathlib import Path

import httpx
import pytest

from eidolon.config import Settings
from eidolon.llm import LLMError
from tests.conftest import CharacterConfig, ClientFactory
from tests.fakes import (
    HANG,
    FakeClock,
    FakeIdentityProvider,
    FakeLLM,
    FakeLLMService,
    FakeRandom,
)
from tests.test_activity_records import dashboard
from tests.test_admin_users import ADMIN, admin_beside
from tests.test_bar_limits import come_in_and_leave, uses, visits_an_hour
from tests.test_bar_visit import (
    COMING_IN,
    PARTING,
    VISITS,
    enter,
    events,
    kinds,
    mano_alone,
    mixed,
    serve,
    streamed,
)
from tests.test_own_llm import LLM

DRAWS = [0] * 40
"""What the random source draws for every visit here: one drink, ordered by name."""


@pytest.fixture
def characters(tmp_path: Path) -> CharacterConfig:
    return mano_alone(tmp_path / "characters")


@pytest.fixture
def settings(settings: Settings) -> Settings:
    return replace(settings, admins=frozenset({ADMIN}))


def visit_records(database: Path) -> list[tuple[str, str, int, int]]:
    """Each visit's record, in the order written: how it turned out, who came, whether on
    the user's own LLM, and how many service calls are under it."""
    with sqlite3.connect(database) as db:
        return db.execute(
            "SELECT r.result, r.character_id, r.own_keys, COUNT(c.id) FROM activity_records r"
            " LEFT JOIN service_calls c ON c.record_id = r.id WHERE r.kind = 'visit'"
            " GROUP BY r.id ORDER BY r.id"
        ).fetchall()


def calls_on_their_own(database: Path) -> int:
    with sqlite3.connect(database) as db:
        return db.execute("SELECT COUNT(*) FROM service_calls WHERE record_id IS NULL").fetchone()[0]


async def test_each_visit_is_recorded_as_it_is_over_with_its_service_calls_under_it(
    make_client: ClientFactory, settings: Settings
):
    llm = FakeLLM(*[COMING_IN] * 4, PARTING)
    client = make_client(llm, settings=visits_an_hour(settings, 4), random=FakeRandom(*DRAWS))
    database = settings.database_path

    await come_in_and_leave(client)
    done_away_with = await enter(client)
    await come_in_and_leave(client)  # in another tab, say
    recorded_before_done = visit_records(database)
    done = await enter(client)
    served = events(await serve(client, done[0]["visit_id"], mixed("sugar-rush")))
    refused = await client.post(VISITS, json={})

    assert done_away_with[-1]["type"] == "waiting" and kinds(served)[-1] == "done"
    assert refused.status_code == 429
    assert recorded_before_done == [("left", "mano", 0, 1)] * 3
    assert visit_records(database) == [
        ("left", "mano", 0, 1), ("left", "mano", 0, 1), ("left", "mano", 0, 1),
        ("success", "mano", 0, 2), ("rejected", "mano", 0, 0),
    ]
    assert calls_on_their_own(database) == 0
    with sqlite3.connect(database) as db:
        columns = db.execute("SELECT * FROM activity_records WHERE kind = 'visit'").fetchall()
    assert not any("Sugar Rush" in str(row) or "晚上好" in str(row) for row in columns)


async def test_a_visit_on_the_users_own_llm_is_recorded_so(
    make_client: ClientFactory, settings: Settings, own_llm: FakeLLMService
):
    own_llm.llm = FakeLLM(COMING_IN)
    client = make_client(FakeLLM(), random=FakeRandom(*DRAWS))

    await come_in_and_leave(client, own_keys={"llm": LLM})

    assert visit_records(settings.database_path) == [("left", "mano", 1, 1)]
    with sqlite3.connect(settings.database_path) as db:
        assert db.execute("SELECT own_key FROM service_calls").fetchall() == [(1,)]


async def test_a_visit_stopped_failing_and_ended_is_failed_given_back_if_nothing_was_written(
    make_client: ClientFactory, settings: Settings
):
    failing = LLMError("模型返回 503: overloaded")
    llm = FakeLLM(*[["她走进店里，点了一杯。"], failing] * 2, COMING_IN, failing, failing)
    # Two visits with one drink, then one with two.
    client = make_client(llm, random=FakeRandom(*[0] * 12, 0, 0, 20, *DRAWS))

    left = await enter(client)
    await client.delete(f"{VISITS}/{left[0]['visit_id']}")
    done_away_with = await enter(client)
    came = await enter(client)
    failed_later = events(await serve(client, came[0]["visit_id"], mixed("sugar-rush")))
    await client.delete(f"{VISITS}/{came[0]['visit_id']}")

    assert kinds(left) == kinds(done_away_with) == ["visit", "retrying", "failed"]
    assert kinds(failed_later)[-1] == "failed"
    assert [r[0] for r in visit_records(settings.database_path)] == ["failed"] * 3
    assert uses(settings.database_path) == [("visit", 0)]  # the third's alone


async def test_a_visit_whose_page_is_gone_while_her_lines_are_written_is_left(
    make_client: ClientFactory, settings: Settings
):
    client = make_client(FakeLLM([COMING_IN[0], HANG]), random=FakeRandom(*DRAWS))
    gone = asyncio.Event()

    came, entering = await streamed(client, VISITS, {}, until="visit", gone=gone)
    gone.set()
    await asyncio.wait_for(entering, timeout=5)
    async with asyncio.timeout(5):  # settled as the page is gone, not waited for
        while not visit_records(settings.database_path):
            await asyncio.sleep(0.05)
    afterwards = await serve(client, came[0]["visit_id"], mixed("sugar-rush"))

    assert [r[0] for r in visit_records(settings.database_path)] == ["left"]
    assert uses(settings.database_path) == [("visit", 0)]  # counted all the same
    assert afterwards.status_code == 410


async def section(client: httpx.AsyncClient, github: FakeIdentityProvider) -> dict | None:
    async with admin_beside(client, github) as admin:
        return (await dashboard(admin))["bar"]


async def test_the_dashboard_counts_the_visits_begun_done_and_failed(
    make_client: ClientFactory, settings: Settings, github: FakeIdentityProvider
):
    failing = LLMError("模型返回 503: overloaded")
    llm = FakeLLM(failing, failing, COMING_IN, COMING_IN, PARTING)
    # The one failed is given back as the next does away with it: three begun, two counted.
    client = make_client(llm, settings=visits_an_hour(settings, 2), random=FakeRandom(*DRAWS))
    none_yet = await section(client, github)

    assert kinds(await enter(client))[-1] == "failed"
    await come_in_and_leave(client)
    done = await enter(client)
    await serve(client, done[0]["visit_id"], mixed("sugar-rush"))
    assert (await client.post(VISITS, json={})).status_code == 429

    assert none_yet == {"visits": 0, "done": 0, "failed": 0}
    assert await section(client, github) == {"visits": 3, "done": 1, "failed": 1}


async def test_with_the_bar_closed_and_no_visit_in_the_range_there_is_no_section(
    make_client: ClientFactory, settings: Settings, github: FakeIdentityProvider
):
    clock = FakeClock()
    client = make_client(FakeLLM(COMING_IN), clock=clock, random=FakeRandom(*DRAWS))
    await come_in_and_leave(client)

    async with admin_beside(client, github) as admin:
        res = await admin.put("/api/admin/config/bar", json={"enabled": False})
        assert res.status_code == 200, res.text
        closed_with_one = (await dashboard(admin))["bar"]
        clock.advance(hours=25)  # out of the last 24 hours
        closed_and_none = (await dashboard(admin))["bar"]

    assert closed_with_one == {"visits": 1, "done": 0, "failed": 0}
    assert closed_and_none is None
