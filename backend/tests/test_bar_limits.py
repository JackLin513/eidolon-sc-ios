"""How many visits to the bar a user may begin (GLOSSARY.md「限额」「光顾」): five an hour
unless the deployer or an admin says otherwise, counted apart from text turns and calls. A
visit counts as she comes in, left part-way or not; one on the user's own LLM counts towards
nothing, but is recorded. Over the limit, coming in is refused (429) with when to come back.
A character in a cooldown with the user comes all the same.

Driven through the backend's external API, with a clock the tests control."""

import sqlite3
from dataclasses import replace
from datetime import datetime, timedelta
from pathlib import Path

import httpx
import pytest

from eidolon.config import Settings, UsageLimits
from tests.browser import open_browser
from tests.conftest import CharacterConfig, ClientFactory
from tests.fakes import (
    DEPLOYER_KEY,
    START,
    FakeClock,
    FakeIdentityProvider,
    FakeLLM,
    FakeLLMService,
    FakeRandom,
    FakeSpeech,
)
from tests.test_admin_users import ADMIN, admin_beside, admin_client, find
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
)
from tests.test_live_config import CONFIG
from tests.test_live_config_limits import LIMITS
from tests.test_own_llm import LLM, MINE, THINKING
from tests.test_rate_limit import REPLY
from tests.test_text_turn import send_turn, start_conversation
from tests.test_user_limits import set_limits

ENTERING = (0, 0, 0, 0, 0, 0)
"""What the random source draws as she comes in: her reason, topic, drinks and first order."""


@pytest.fixture
def characters(tmp_path: Path) -> CharacterConfig:
    return mano_alone(tmp_path / "characters")


def visits_an_hour(settings: Settings, visits: int | None, **others: int | None) -> Settings:
    return replace(settings, usage_limits=UsageLimits(visits_per_hour=visits, **others))


async def come_in_and_leave(client: httpx.AsyncClient, **body: object) -> None:
    came = await enter(client, **body)
    assert came[-1]["type"] == "waiting", came
    left = await client.delete(f"{VISITS}/{came[0]['visit_id']}")
    assert left.status_code == 204


async def test_the_sixth_visit_in_an_hour_is_refused_until_the_first_ages_out(
    make_client: ClientFactory, settings: Settings
):
    clock = FakeClock()
    llm = FakeLLM(*[COMING_IN] * 6)
    client = make_client(llm, clock=clock, random=FakeRandom(*ENTERING * 6))
    for _ in range(5):
        await come_in_and_leave(client)  # left part-way: counted all the same
        clock.advance(minutes=10)

    refused = await client.post(VISITS, json={})

    assert refused.status_code == 429
    body = refused.json()
    assert "光顾" in body["detail"] and "每小时 5 次" in body["detail"]
    assert datetime.fromisoformat(body["retry_at"]) == START + timedelta(hours=1)
    assert refused.headers["Retry-After"] == str(10 * 60)
    assert len(llm.prompts) == 5  # the model was never asked

    clock.advance(minutes=10)
    assert (await enter(client))[-1]["type"] == "waiting"


def uses(database: Path) -> list[tuple[str, int]]:
    with sqlite3.connect(database) as db:
        return db.execute("SELECT kind, exempt FROM usage ORDER BY id").fetchall()


async def test_a_visit_on_the_users_own_llm_runs_on_it_and_counts_towards_nothing(
    make_client: ClientFactory, settings: Settings, own_llm: FakeLLMService
):
    own_llm.llm = FakeLLM(COMING_IN, PARTING, COMING_IN)
    deployers = FakeLLM(COMING_IN)
    client = make_client(
        deployers, settings=visits_an_hour(settings, 1),
        random=FakeRandom(*[0] * 30),  # each visit with one drink, as `ENTERING` has it
    )

    came = await enter(client, own_keys={"llm": THINKING})
    served = events(await serve(client, came[0]["visit_id"], mixed("sugar-rush")))
    await come_in_and_leave(client, own_keys={"llm": THINKING})
    await come_in_and_leave(client)  # the one the hour has
    refused = await client.post(VISITS, json={})

    assert kinds(served)[-1] == "done"
    assert "告别" in own_llm.llm.prompts[1][-1].content  # on the keys the visit came in with
    assert set(own_llm.llm.keys) == {MINE} and set(deployers.keys) == {DEPLOYER_KEY}
    # Her lines are written at the effort the user set for text turns, not calls.
    assert {s.reasoning_effort for s in own_llm.opened} == {"high"}
    assert refused.status_code == 429
    assert uses(settings.database_path) == [("visit", 1), ("visit", 1), ("visit", 0)]


@pytest.mark.parametrize(("own", "visits"), [(1, 1), ("unlimited", 6), (0, 0)])
# How many visits the user may begin in the hour: for unlimited, more than the deployment's.
async def test_an_admin_may_set_a_users_own_visits_an_hour(
    make_client: ClientFactory,
    settings: Settings,
    github: FakeIdentityProvider,
    own_llm: FakeLLMService,
    own: int | str,
    visits: int,
):
    settings = replace(settings, admins=frozenset({ADMIN}))
    admin = await admin_client(make_client, github, settings=settings)
    own_llm.llm = FakeLLM(COMING_IN)
    llm = FakeLLM(*[COMING_IN] * visits)
    client = make_client(
        llm, settings=settings, clock=FakeClock(),
        random=FakeRandom(*ENTERING * (visits + 1)),
    )
    await client.get("/api/bar")
    producer_id = (await find(admin, "producer"))["id"]

    shown = await set_limits(admin, producer_id, visits_per_hour=own)
    for _ in range(visits):
        await come_in_and_leave(client)
    refused = await client.post(VISITS, json={}) if own != "unlimited" else None
    on_own_llm = await enter(client, own_keys={"llm": LLM})

    assert shown["limits"]["visits_per_hour"] == own
    assert (shown["limits"]["turns_per_hour"], shown["limits"]["photos_per_hour"]) == (None, None)
    if refused is not None:
        assert refused.status_code == 429
    if own == 0:
        assert refused is not None
        assert "自带密钥" in refused.json()["detail"] and refused.json()["retry_at"] is None
    assert on_own_llm[-1]["type"] == "waiting"  # never over the limit, even of 0


async def test_visits_take_nothing_of_the_turns_or_calls_an_hour_nor_they_of_visits(
    make_client: ClientFactory, settings: Settings, speech: FakeSpeech
):
    client = make_client(
        FakeLLM(COMING_IN, REPLY),
        settings=visits_an_hour(settings, 1, turns_per_hour=1, calls_per_hour=1),
        random=FakeRandom(*ENTERING),
    )
    conversation_id = await start_conversation(client)

    await come_in_and_leave(client)
    turned = await send_turn(client, conversation_id, "在吗")
    async with open_browser() as browser:
        called = await browser.call(client, conversation_id=conversation_id)
        await browser.connect()
    visits_used_up = await client.post(VISITS, json={})

    assert turned[-1]["type"] == "done"
    assert called.status_code == 200
    assert visits_used_up.status_code == 429 and "光顾" in visits_used_up.json()["detail"]
    assert [kind for kind, _ in uses(settings.database_path)] == ["visit", "turn", "call"]


async def test_the_visits_an_hour_saved_in_the_admin_console_hold_from_the_next_visit(
    make_client: ClientFactory, settings: Settings, github: FakeIdentityProvider
):
    llm = FakeLLM(*[COMING_IN] * 2)
    client = make_client(
        llm, settings=replace(settings, admins=frozenset({ADMIN})), clock=FakeClock(),
        random=FakeRandom(*ENTERING * 2),
    )

    async with admin_beside(client, github) as admin:
        before = (await admin.get(CONFIG)).json()["limits"]
        saved = await admin.put(LIMITS, json=before["env"] | {"visits_per_hour": 1})
        await come_in_and_leave(client)
        refused = await client.post(VISITS, json={})
        unlimited = await admin.put(LIMITS, json=before["env"] | {"visits_per_hour": 0})
        await come_in_and_leave(client)

    assert before["env"]["visits_per_hour"] == 5
    assert saved.status_code == 200, saved.text
    assert saved.json()["limits"]["override"] == {"visits_per_hour": 1}
    assert refused.status_code == 429
    assert unlimited.json()["limits"]["effective"]["visits_per_hour"] == 0
