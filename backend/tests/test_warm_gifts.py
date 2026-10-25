"""Warm gifts in her days (GLOSSARY.md「礼物」「周期」): given in her period or the days before
it, with cycles on, a warm gift raises her affinity by more, on top of whether she likes it,
however many are given; in a cooldown, by the same as any gift; and she is told, of each one,
that it warmed her, as where she was as it was given is told again each turn, so not while
cycles are off now. On her other days, or while the deployment or the user has cycles off,
it is as any other gift. Nothing the user is shown of giving it tells of it.

Driven through the backend's external API, the random source giving what is drawn. The
store keeps when a gift was given by the time it really is, so the clock is that time, and a
secret key is found that has her where the test wants that day, as `test_her_days` has it
for a call."""

from collections.abc import Callable
from dataclasses import replace
from datetime import UTC, datetime

import httpx
import pytest

from eidolon.config import Settings
from eidolon.gift_catalog import GIFTS_FILE
from eidolon.her_cycle import HerDay
from tests.conftest import CharacterConfig, ClientFactory
from tests.fakes import FAKE_JUDGE, FakeClock, FakeLLM, FakeRandom
from tests.test_affinity import keep
from tests.test_affinity_turns import value
from tests.test_conversation_events import record
from tests.test_conversation_history import history
from tests.test_cycles_switch import switch
from tests.test_gift_backpack import COMMON, FIRST, SECOND, UNCOMMON
from tests.test_gift_catalog import gift
from tests.test_gift_giving import draw_them, given, happier
from tests.test_her_days import a_key_when, in_period, premenstrual
from tests.test_text_turn import send_turn, start_conversation

SAID = "<ja>はい</ja><zh>好的</zh>"
REPLY = [SAID]
WARMED = "这几天你不太舒服，收到暖的东西，你心里很暖。"
RESPOND = "（先回应制作人说的话，再在合适的时候用你自己的方式回应收到的礼物，一次就够。）"

LIKED_WARM, COCOA, TEA = (UNCOMMON, FIRST), (UNCOMMON, SECOND), (COMMON, FIRST)
"""The numbers that draw each gift: `liked_warm` is uncommon, warm and liked by every test
character, cocoa uncommon and warm, tea common and neither."""

KEPT = 60.0
"""Her affinity as the gift is given: above the normal value, not to recover."""


def neither(her_day: HerDay) -> bool:
    return her_day is None


@pytest.fixture
def settings(settings: Settings) -> Settings:
    """With the judge model, affinity and gifts, and cycles on."""
    return replace(settings, judge=FAKE_JUDGE, affinity_and_gifts=True, cycles=True)


@pytest.fixture(autouse=True)
def catalog(characters: CharacterConfig) -> None:
    # The test characters like cake: here it is the liked warm one.
    characters.write(
        GIFTS_FILE,
        gift("cake", "uncommon", "drink", warm=True) + gift("cocoa", "uncommon", "drink", warm=True)
        + gift("tea", category="drink") + gift("plush", "rare", "trinket"),
    )


async def holding_on(
    make_client: ClientFactory,
    settings: Settings,
    wanted: Callable[[HerDay], bool],
    *gifts: tuple[int, int],
    llm: FakeLLM | None = None,
    deployment: Settings | None = None,
) -> tuple[httpx.AsyncClient, FakeClock]:
    """A client of the producer's, now, with a secret key that has Mano where `wanted`
    today, the deployment otherwise as `settings` has it unless `deployment` is given, having
    drawn `gifts` (up to 2), her affinity kept at `KEPT`; and its clock."""
    make_client(FakeLLM())  # the producer, signed up
    clock = FakeClock(datetime.now(UTC))
    key = a_key_when(settings, clock.now, wanted)
    client = make_client(
        llm or FakeLLM(REPLY), clock=clock,
        settings=replace(deployment or settings, secret_key=key),
        random=FakeRandom(*[n for g in gifts for n in g]),
    )
    await draw_them(client, clock, len(gifts))
    keep(settings.database_path, "producer", KEPT, clock.now)
    return client, clock


@pytest.mark.parametrize(
    "wanted", [in_period(early=True), in_period(early=False), premenstrual(near=True)],
    ids=["period-first-two-days", "period-from-the-third", "premenstrual"],
)
async def test_in_her_days_a_warm_gift_raises_it_by_more_on_top_of_her_liking_it(
    make_client: ClientFactory, settings: Settings, wanted: Callable[[HerDay], bool]
):
    client, _ = await holding_on(make_client, settings, wanted, COCOA, LIKED_WARM)

    await given(client, "cocoa")
    after_cocoa = value(settings.database_path)
    await given(client, "cake")

    assert after_cocoa == pytest.approx(KEPT + 0.5 + 0.3)
    assert value(settings.database_path) == pytest.approx(KEPT + 0.8 + 0.5 + 0.3 + 0.3)


async def test_in_her_days_a_gift_not_warm_raises_it_as_ever(
    make_client: ClientFactory, settings: Settings
):
    client, _ = await holding_on(make_client, settings, in_period(early=True), TEA)

    await given(client, "tea")

    assert value(settings.database_path) == pytest.approx(KEPT + 0.3)


async def test_on_her_other_days_a_warm_gift_raises_it_as_any_other(
    make_client: ClientFactory, settings: Settings
):
    client, _ = await holding_on(make_client, settings, neither, COCOA)

    await given(client, "cocoa")

    assert value(settings.database_path) == pytest.approx(KEPT + 0.5)


async def test_in_a_cooldown_a_warm_gift_in_her_days_raises_it_as_any_gift(
    make_client: ClientFactory, settings: Settings
):
    client, clock = await holding_on(make_client, settings, in_period(early=True), COCOA)
    keep(settings.database_path, "producer", 0, clock.now, cooling=True)

    result = await given(client, "cocoa")

    assert result["change"] is None
    assert value(settings.database_path) == pytest.approx(3.0)


async def test_with_the_deployment_turning_cycles_off_a_warm_gift_raises_it_as_any_other(
    make_client: ClientFactory, settings: Settings
):
    client, _ = await holding_on(
        make_client, settings, in_period(early=True), COCOA,
        deployment=replace(settings, cycles=False),
    )

    await given(client, "cocoa")

    assert value(settings.database_path) == pytest.approx(KEPT + 0.5)


async def test_with_the_user_turning_cycles_off_a_warm_gift_raises_it_as_any_other(
    make_client: ClientFactory, settings: Settings
):
    client, _ = await holding_on(make_client, settings, in_period(early=True), COCOA)
    await switch(client, False)

    await given(client, "cocoa")

    assert value(settings.database_path) == pytest.approx(KEPT + 0.5)


@pytest.mark.parametrize(
    "wanted", [in_period(early=True), premenstrual(near=True)], ids=["period", "premenstrual"]
)
async def test_in_her_days_she_is_told_a_warm_gift_warmed_her_and_not_one_not_warm(
    make_client: ClientFactory, settings: Settings, wanted: Callable[[HerDay], bool]
):
    llm = FakeLLM(REPLY)
    client, _ = await holding_on(make_client, settings, wanted, LIKED_WARM, TEA, llm=llm)
    conversation = await start_conversation(client)

    await given(client, "cake")
    await given(client, "tea")
    await send_turn(client, conversation, "尝尝看")

    assert history(llm) == [(
        "user",
        f"（制作人送给你一份cake。这是你喜欢的东西。{WARMED}）\n（制作人送给你一份tea。）\n"
        f"{RESPOND}\n尝尝看",
    )]


async def test_on_her_other_days_she_is_told_of_a_warm_gift_as_of_any_other(
    make_client: ClientFactory, settings: Settings
):
    llm = FakeLLM(REPLY)
    client, _ = await holding_on(make_client, settings, neither, COCOA, llm=llm)
    conversation = await start_conversation(client)

    await given(client, "cocoa")
    await send_turn(client, conversation, "尝尝看")

    assert history(llm) == [("user", f"（制作人送给你一份cocoa。）\n{RESPOND}\n尝尝看")]


async def test_with_the_user_turning_cycles_off_she_is_no_longer_told_it_warmed_her(
    make_client: ClientFactory, settings: Settings
):
    llm = FakeLLM(REPLY, REPLY)
    client, _ = await holding_on(make_client, settings, in_period(early=True), COCOA, llm=llm)
    conversation = await start_conversation(client)
    await given(client, "cocoa")
    await send_turn(client, conversation, "尝尝看")
    told_on = history(llm)[0]

    await switch(client, False)
    await send_turn(client, conversation, "好喝吗")

    assert told_on == ("user", f"（制作人送给你一份cocoa。{WARMED}）\n{RESPOND}\n尝尝看")
    assert history(llm)[0] == ("user", "（制作人送给你一份cocoa。）\n尝尝看")


async def test_nothing_the_user_is_shown_of_giving_it_tells_it_warmed_her(
    make_client: ClientFactory, settings: Settings
):
    client, _ = await holding_on(make_client, settings, in_period(early=True), COCOA)

    shown = await given(client, "cocoa")
    [event] = await record(client, shown["conversation_id"])

    assert set(shown) == {"conversation_id", "change", "affinity", "left", "rewarded"}
    assert shown["change"] == happier("trust")
    assert shown["affinity"] == {"tier": "trust", "cooling": False, "cooldown_until": None}
    assert {k: v for k, v in event.items() if k not in {"id", "created_at"}} == {
        "type": "event", "kind": "gift", "gift_id": "cocoa", "gift_name": "cocoa",
        "affinity": happier("trust"),
    }
