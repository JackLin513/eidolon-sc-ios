"""Forcing where her cycle has her, in development only (`EIDOLON_DEV_LOGIN=1`): the user's
character in her period on a day, premenstrual some days before it, or neither, whatever her
true cycle says, until cleared; the switches still hold. Without development sign-in, there
is no such route.

Driven through the backend's external API, what she is told of now read from her prompt."""

from dataclasses import replace

import pytest

from eidolon.config import Settings
from tests.conftest import ClientFactory
from tests.fakes import FakeClock, FakeLLM
from tests.test_calendar import REPLY, told_now
from tests.test_her_days import (
    BEFORE_IT,
    IN_PERIOD,
    NOTHING_OF_IT,
    PERIOD_LATE,
    PREMENSTRUAL_NEAR,
    START,
    a_noon_when,
    in_period,
)

FORCE = "/api/dev/cycles/mano"


@pytest.fixture
def settings(settings: Settings) -> Settings:
    """With cycles on, and development sign-in as the tests have it."""
    return replace(settings, cycles=True)


async def test_forced_she_is_told_how_she_feels_there_until_cleared(
    make_client: ClientFactory, settings: Settings
):
    llm = FakeLLM(*[REPLY] * 4)
    clock = FakeClock(START)
    client = make_client(llm, clock=clock)
    clock.now = a_noon_when(settings, lambda d: d is None)

    in_her_period = await client.put(FORCE, json={"phase": "period", "day": 3})
    told_in_period = await told_now(client, llm)
    await client.put(FORCE, json={"phase": "premenstrual", "day": 2})
    told_before = await told_now(client, llm)
    cleared = await client.delete(FORCE)
    told_cleared = await told_now(client, llm)

    assert in_her_period.status_code == 204
    assert f"\n{PERIOD_LATE}\n{IN_PERIOD}" in told_in_period
    assert f"\n{PREMENSTRUAL_NEAR}\n{BEFORE_IT}" in told_before
    assert cleared.status_code == 204
    assert not any(words in told_cleared for words in NOTHING_OF_IT)


async def test_forced_to_neither_she_is_told_nothing_in_her_true_period(
    make_client: ClientFactory, settings: Settings
):
    llm = FakeLLM(REPLY)
    clock = FakeClock(START)
    client = make_client(llm, clock=clock)
    clock.now = a_noon_when(settings, in_period(early=True))

    await client.put(FORCE, json={"phase": "neither"})
    told = await told_now(client, llm)

    assert not any(words in told for words in NOTHING_OF_IT)


async def test_forced_the_deployment_turning_cycles_off_still_holds(
    make_client: ClientFactory, settings: Settings
):
    llm = FakeLLM(REPLY)
    client = make_client(llm, settings=replace(settings, cycles=False))

    await client.put(FORCE, json={"phase": "period", "day": 1})
    told = await told_now(client, llm)

    assert not any(words in told for words in NOTHING_OF_IT)


@pytest.mark.parametrize(
    "body", [{"phase": "period", "day": 9}, {"phase": "premenstrual", "day": 6}]
)
async def test_a_day_she_cannot_be_on_is_refused(make_client: ClientFactory, body: dict):
    client = make_client(FakeLLM())

    assert (await client.put(FORCE, json=body)).status_code == 422


async def test_a_character_not_configured_is_not_found(make_client: ClientFactory):
    client = make_client(FakeLLM())

    res = await client.put("/api/dev/cycles/nobody", json={"phase": "neither"})

    assert res.status_code == 404


async def test_without_development_sign_in_there_is_no_such_route(
    make_client: ClientFactory, settings: Settings
):
    client = make_client(FakeLLM(), settings=replace(settings, dev_login=False))

    forced = await client.put(FORCE, json={"phase": "period", "day": 1})
    cleared = await client.delete(FORCE)

    assert (forced.status_code, cleared.status_code) == (404, 404)
