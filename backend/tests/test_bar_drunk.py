"""Her getting drunk at the bar (GLOSSARY.md「醉」), driven through the backend's external API:
the Karmotrine of every drink served her adds up, a doubled glass's doubled, a bottle's as
the catalog has it, until it is as much as she holds (`bar_rules.DRUNK_AT`); the call after
that drink has her react to it as ever, then drunk, talk a little and say goodbye, ordering
no more. The visit is written down as one she got drunk in, which she remembers next time.
Nothing of it is sent to the page, and it is no part of how well a drink is served.

Mano is the only character, ordering Sugar Rush by name, then Sparkle Star, then Blue Fairy
(what she likes, once her favorite is had), three drinks planned."""

import json
from pathlib import Path

import pytest

from eidolon.config import Settings
from tests.conftest import MANO_SHEET, CharacterConfig, ClientFactory
from tests.fakes import FakeLLM, FakeRandom
from tests.test_bar_draws import visit_rows
from tests.test_bar_records import remembered
from tests.test_bar_visit import (
    COMING_IN,
    MANO_TASTES,
    PARTING,
    bottle,
    coming_in,
    enter,
    events,
    kinds,
    mixed,
    reacting,
    serve,
)

DRUNK = "从这一段起你醉了"


@pytest.fixture
def tolerance() -> str:
    return "strong"


@pytest.fixture
def characters(tmp_path: Path, tolerance: str) -> CharacterConfig:
    return CharacterConfig(tmp_path / "characters").add(
        "mano", "櫻木真乃", MANO_SHEET, birthday="04-25",
        bar={**MANO_TASTES, "bar_tolerance": tolerance},
    )


def entering(tolerance: str) -> list[int]:
    """Her first reason and topic, three drinks, her favorite by name, wanted with alcohol
    where she may want it without."""
    return [0, 0, 80, 0, 0, 0, *([] if tolerance == "strong" else [99])]


def ordering_next(tolerance: str) -> list[int]:
    """The first fixed line served with, then her next order: the first she likes, by name."""
    return [0, 0, 0, 0, *([] if tolerance == "strong" else [99])]


def asked(llm: FakeLLM) -> str:
    """What the latest call was to write."""
    return llm.prompts[-1][-1].content


@pytest.mark.parametrize(
    ("tolerance", "first", "second"),
    [("weak", 4, 4), ("medium", 7, 7), ("strong", 10, 10)],
)
async def test_she_is_drunk_once_she_has_had_as_much_as_she_holds(
    make_client: ClientFactory, settings: Settings, tolerance: str, first: int, second: int
):
    llm = FakeLLM(COMING_IN, reacting("sparkle-star"), PARTING)
    client = make_client(
        llm, random=FakeRandom(*entering(tolerance), *ordering_next(tolerance), 0)
    )

    came = await enter(client)
    visit_id = came[0]["visit_id"]
    served = [
        events(await serve(client, visit_id, mixed("sugar-rush", karmotrine=first))),
        events(await serve(client, visit_id, mixed("sparkle-star", karmotrine=second))),
    ]

    assert kinds(served[0])[-1] == "waiting"
    assert kinds(served[1])[-1] == "done"  # a drink before the three planned
    assert len(llm.prompts) == 3
    last = asked(llm)
    assert DRUNK in last and "告别" in last
    assert "判定：上对了" in last  # as much Karmotrine as she likes in it, it is what she asked
    assert "点单卡" not in last
    assert "你今晚没有喝醉" not in last
    for evented in (came, *served):
        assert all("drunk" not in json.dumps(e) and "醉" not in json.dumps(e) for e in evented)
    [row] = visit_rows(settings.database_path)
    assert row["drunk"] == 1


@pytest.mark.parametrize(
    ("tolerance", "first", "second"),
    [("weak", 4, 3), ("medium", 7, 6), ("strong", 10, 9)],
)
async def test_a_part_short_of_what_she_holds_she_is_not_drunk(
    make_client: ClientFactory, tolerance: str, first: int, second: int
):
    llm = FakeLLM(COMING_IN, reacting("sparkle-star"), reacting("blue-fairy"))
    client = make_client(
        llm,
        random=FakeRandom(*entering(tolerance), *ordering_next(tolerance), *ordering_next(tolerance)),
    )

    visit_id = (await enter(client))[0]["visit_id"]
    await serve(client, visit_id, mixed("sugar-rush", karmotrine=first))
    second_served = events(await serve(client, visit_id, mixed("sparkle-star", karmotrine=second)))

    assert kinds(second_served)[-1] == "waiting"
    assert "Blue Fairy" in asked(llm)  # her third order
    assert all(DRUNK not in prompt[-1].content for prompt in llm.prompts)


@pytest.mark.parametrize("tolerance", ["weak"])
async def test_a_doubled_glass_has_its_karmotrine_doubled(make_client: ClientFactory):
    llm = FakeLLM(COMING_IN, PARTING)
    client = make_client(llm, random=FakeRandom(*entering("weak"), 0))

    visit_id = (await enter(client))[0]["visit_id"]
    served = events(await serve(client, visit_id, mixed("beer", big=True)))  # 4 parts, doubled

    assert kinds(served)[-1] == "done"
    assert len(llm.prompts) == 2
    assert DRUNK in asked(llm)


@pytest.mark.parametrize("tolerance", ["weak"])
async def test_a_bottle_has_the_karmotrine_the_catalog_says_and_she_remembers_being_drunk(
    make_client: ClientFactory, settings: Settings
):
    llm = FakeLLM(
        COMING_IN, reacting("sparkle-star"), reacting("blue-fairy"), PARTING,
        coming_in("fluffy-dream"),
    )
    # The second visit: the only character, then her first reason and topic, one drink, the
    # first she likes but for what she wanted the last time, by name, with alcohol.
    client = make_client(llm, random=FakeRandom(
        *entering("weak"), *ordering_next("weak"), *ordering_next("weak"), 0,
        0, 0, 0, 0, 0, 0, 0, 99,
    ))

    visit_id = (await enter(client))[0]["visit_id"]
    absinthe = events(await serve(client, visit_id, bottle("absinthe")))  # 6
    mulan_tea = events(await serve(client, visit_id, bottle("mulan-tea")))  # none
    asked_after_mulan_tea = asked(llm)
    last = events(await serve(client, visit_id, mixed("blue-fairy", karmotrine=2)))
    asked_after_last = asked(llm)
    await enter(client)

    assert kinds(absinthe)[-1] == "waiting" and kinds(mulan_tea)[-1] == "waiting"
    assert DRUNK not in asked_after_mulan_tea
    assert kinds(last)[-1] == "done"
    assert DRUNK in asked_after_last  # the last she was to have, and drunk on it
    assert "你今晚喝醉了" in asked_after_last
    [row] = visit_rows(settings.database_path)
    assert row["drunk"] == 1
    assert "上次喝醉了" in remembered(llm.prompts[-1])
    assert "不会因此只点不含酒精的" in remembered(llm.prompts[-1])
