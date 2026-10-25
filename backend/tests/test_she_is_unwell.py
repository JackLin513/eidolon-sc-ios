"""Her being unwell (GLOSSARY.md「对话事件」「周期」): in her period, the user's first turn
with her in it, typed or in a call, comes after a conversation event saying since when she
has been unwell: the first day of her period, and how many days before that turn's day it
was. Once a period, whichever conversation, never again in it; her reaching out or a gift
given leave none, and a period with no turn has none, never made up for. Neither while the
deployment or the user has cycles off; a turn after they are turned on again, in her period,
has it. She is never told of it.

Driven through the backend's external API, the clock moved to where her true cycle has her
(`test_her_days`)."""

import sqlite3
from collections.abc import Callable
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from eidolon.config import Settings
from eidolon.gift_catalog import GIFTS_FILE
from eidolon.her_cycle import HerDay, Period
from tests.conftest import CharacterConfig, ClientFactory
from tests.fakes import FAKE_JUDGE, FakeClock, FakeLLM, FakeRandom
from tests.test_call_turns import MANO_REPLY, NOW, CallUnderTest, spoken
from tests.test_conversation_events import record, shape
from tests.test_conversation_history import history, told
from tests.test_cycles_switch import switch
from tests.test_gift_catalog import gift
from tests.test_gift_giving import CAKE, given
from tests.test_her_days import (
    SHANGHAI,
    START,
    a_key_when,
    a_noon_when,
    on_a_day,
    where,
)
from tests.test_reach_outs import backend_of, last_contact
from tests.test_text_turn import send_turn, start_conversation

REPLY = ["<ja>はい</ja><zh>好的</zh>"]


@pytest.fixture
def settings(settings: Settings) -> Settings:
    """With cycles on, as the deployment has them unless it turns them off."""
    return replace(settings, cycles=True)


def on_day(day: int) -> Callable[[HerDay], bool]:
    """Day `day` of her period."""
    return lambda d: isinstance(d, Period) and d.day == day


def unwell(database: Path) -> list[tuple[str, int]]:
    """Each time she was recorded unwell, in any conversation: from which day, how many
    days before."""
    with sqlite3.connect(database) as db:
        return db.execute(
            "SELECT first_day, days_ago FROM conversation_events WHERE kind = 'unwell'"
            " ORDER BY id"
        ).fetchall()


def period_on(settings: Settings, noon: datetime) -> Period:
    today = where(settings, noon.astimezone(SHANGHAI).date())
    assert isinstance(today, Period)
    return today


async def test_her_first_turn_in_her_period_comes_after_it_and_no_other_turn_does(
    make_client: ClientFactory, settings: Settings
):
    client = on_a_day(make_client, settings, on_day(3), FakeLLM(REPLY, REPLY, REPLY))
    first_day = (a_noon_when(settings, on_day(3)).astimezone(SHANGHAI) - timedelta(days=2)).date()
    conversation = await start_conversation(client)

    first = await send_turn(client, conversation, "第一句")
    second = await send_turn(client, conversation, "第二句")
    another = await start_conversation(client)
    await send_turn(client, another, "换个对话")

    entries = await record(client, conversation)
    assert shape(entries) == ["unwell", "user:第一句", "character:好的", "user:第二句", "character:好的"]
    assert entries[0] == {
        "type": "event", "id": entries[0]["id"], "kind": "unwell",
        "created_at": entries[0]["created_at"], "affinity": None,
        "first_day": first_day.isoformat(), "days_ago": 2,
    }
    assert first[-1]["unwell"] == entries[0]
    assert second[-1]["unwell"] is None
    assert shape(await record(client, another)) == ["user:换个对话", "character:好的"]
    [latest] = (await client.get("/api/conversations/latest")).json()
    assert latest["last_message"]["role"] == "character"


async def test_in_a_call_her_first_turn_comes_after_it_and_a_typed_one_then_does_not(
    make_client: ClientFactory, settings: Settings
):
    make_client(FakeLLM())  # the producer, signed up
    keyed = replace(settings, secret_key=a_key_when(settings, NOW, on_day(2)))
    client = make_client(FakeLLM(REPLY), clock=FakeClock(NOW), settings=keyed)
    conversation = await start_conversation(client)
    call = await CallUnderTest.of(keyed, client, conversation)

    await call.run(FakeLLM(MANO_REPLY), [spoken("早上好")])
    await send_turn(client, conversation, "挂了再说一句")

    assert shape(await record(client, conversation)) == [
        "unwell", "user:早上好", "character:哇，早上好！今天也", "user:挂了再说一句",
        "character:好的",
    ]


async def test_her_reaching_out_leaves_none(make_client: ClientFactory, settings: Settings):
    """She reaches out at 20:00 in Shanghai on the first day of her period, the user having
    talked to her the evening before, as `test_her_days` has her."""
    make_client(FakeLLM())  # the producer, signed up
    at = datetime(2026, 9, 23, 12, tzinfo=UTC)
    keyed = replace(settings, secret_key=a_key_when(settings, at, on_day(1)), reach_outs=True)
    llm = FakeLLM(REPLY, REPLY)
    clock = FakeClock(at - timedelta(days=1))
    client = make_client(llm, clock=clock, random=FakeRandom(0), settings=keyed)
    conversation = await start_conversation(client)
    await send_turn(client, conversation, "我去练习了")
    last_contact(settings.database_path, conversation, datetime(2026, 9, 22, 13, tzinfo=UTC))
    clock.now = at

    await backend_of(client).reach_outs.run_due()

    assert len(llm.prompts) == 2
    assert unwell(settings.database_path) == []


async def test_a_gift_given_leaves_none(
    make_client: ClientFactory, settings: Settings, characters: CharacterConfig
):
    characters.write(
        GIFTS_FILE,
        gift("cake") + gift("tea", category="drink") + gift("cocoa", "uncommon")
        + gift("plush", "rare", "trinket"),
    )
    make_client(FakeLLM())  # the producer, signed up
    client = make_client(
        FakeLLM(), clock=FakeClock(a_noon_when(settings, on_day(1))), random=FakeRandom(*CAKE),
        settings=replace(settings, judge=FAKE_JUDGE, affinity_and_gifts=True),
    )
    assert (await client.get("/api/gifts")).status_code == 200
    assert (await client.post("/api/gifts/draws", json={})).status_code == 200

    await given(client, "cake")

    assert unwell(settings.database_path) == []


async def test_a_period_with_no_turn_has_none_and_the_next_has_its_own(
    make_client: ClientFactory, settings: Settings
):
    make_client(FakeLLM())  # the producer, signed up
    noons = [START + timedelta(days=n) for n in range(150)]
    firsts = [noon for noon in noons if on_day(1)(where(settings, noon.astimezone(SHANGHAI).date()))]
    talked, missed, talked_again = firsts[:3]
    for noon in (talked, talked_again):
        client = make_client(FakeLLM(REPLY), clock=FakeClock(noon))
        await send_turn(client, await start_conversation(client), "你好")

    assert unwell(settings.database_path) == [
        (period_on(settings, talked).first_day.isoformat(), 0),
        (period_on(settings, talked_again).first_day.isoformat(), 0),
    ]
    assert period_on(settings, missed).first_day not in {
        period_on(settings, n).first_day for n in (talked, talked_again)
    }


async def test_with_the_deployment_turning_cycles_off_there_is_none(
    make_client: ClientFactory, settings: Settings
):
    client = on_a_day(
        make_client, settings, on_day(1), FakeLLM(REPLY), replace(settings, cycles=False)
    )

    await send_turn(client, await start_conversation(client), "你好")

    assert unwell(settings.database_path) == []


async def test_with_the_user_turning_cycles_off_there_is_none_till_they_turn_them_on_again(
    make_client: ClientFactory, settings: Settings
):
    client = on_a_day(make_client, settings, on_day(1), FakeLLM(REPLY, REPLY))
    noon = a_noon_when(settings, on_day(1))
    conversation = await start_conversation(client)

    await switch(client, False)
    await send_turn(client, conversation, "关着")
    assert unwell(settings.database_path) == []
    await switch(client, True)
    await send_turn(client, conversation, "开了")

    assert shape(await record(client, conversation)) == [
        "user:关着", "character:好的", "unwell", "user:开了", "character:好的",
    ]
    assert unwell(settings.database_path) == [(period_on(settings, noon).first_day.isoformat(), 0)]


async def test_she_is_never_told_of_it(make_client: ClientFactory, settings: Settings):
    llm = FakeLLM(REPLY, REPLY)
    client = on_a_day(make_client, settings, on_day(3), llm)
    conversation = await start_conversation(client)

    await send_turn(client, conversation, "第一句")
    await send_turn(client, conversation, "第二句")

    assert history(llm) == [
        ("user", "第一句"), ("assistant", "<ja>はい</ja><zh>好的</zh>"), ("user", "第二句"),
    ]
    assert "不太舒服" not in told(llm)


async def test_the_conversation_lists_last_message_says_since_when_should_it_be_last(
    make_client: ClientFactory, settings: Settings
):
    """As a package imported may have it, after the turns."""
    client = make_client(FakeLLM(REPLY))
    conversation = await start_conversation(client)
    await send_turn(client, conversation, "你好")
    at = datetime.now(UTC).isoformat()
    with sqlite3.connect(settings.database_path) as db:
        db.execute(
            "INSERT INTO conversation_events (conversation_id, kind, created_at, first_day,"
            " days_ago) VALUES (?, 'unwell', ?, '2026-09-21', 7)",
            (conversation, at),
        )

    [latest] = (await client.get("/api/conversations/latest")).json()

    assert latest["last_message"] == {
        "type": "event", "kind": "unwell", "created_at": at, "first_day": "2026-09-21",
        "days_ago": 7,
    }
