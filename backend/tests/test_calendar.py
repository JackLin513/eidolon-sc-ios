"""The calendar's days (GLOSSARY.md「日历」): Japan's national holidays for a year, as the
calendar shows them; and that what she is told of the day in Tokyo, in what she is told of now
(「此刻」), reaches her prompt typing, in a call and reaching out, once each. What she is told of
the day, line by line, `test_her_now` has."""

from dataclasses import replace
from datetime import UTC, datetime

import httpx
import pytest

from eidolon.config import Settings
from tests.conftest import CharacterConfig, ClientFactory
from tests.fakes import FakeClock, FakeLLM, FakeRandom, context_of
from tests.test_call_turns import MANO_REPLY, CallUnderTest, spoken
from tests.test_reach_outs import backend_of, last_contact
from tests.test_text_turn import send_turn, start_conversation

REPLY = ["<ja>はいっ</ja><zh>好的</zh>"]


async def test_holidays_of_a_year_are_japans_national_ones_by_date_kept_by_the_browser_a_day(
    make_client: ClientFactory,
):
    client = make_client(FakeLLM())

    res = await client.get("/api/calendar/holidays", params={"year": 2026})

    assert res.status_code == 200
    holidays = res.json()
    assert {"date": "2026-11-03", "name": "文化の日"} in holidays
    assert {"date": "2026-05-06", "name": "振替休日"} in holidays  # for 憲法記念日 on a Sunday
    assert {"date": "2026-09-22", "name": "国民の休日"} in holidays
    dates = [h["date"] for h in holidays]
    assert "2026-12-31" not in dates and "2026-01-02" not in dates  # the New Year's break
    assert dates == sorted(dates)
    assert all(d.startswith("2026-") for d in dates)
    assert res.headers["Cache-Control"] == "private, max-age=86400"


@pytest.mark.parametrize("year", ["twenty", "２０２６", "1900"])  # the library knows none in 1900
async def test_holidays_of_a_year_there_are_none_known_for_are_none(
    make_client: ClientFactory, year: str
):
    client = make_client(FakeLLM())

    res = await client.get("/api/calendar/holidays", params={"year": year})

    assert res.status_code == 200
    assert res.json() == []


async def test_holidays_are_for_those_signed_in(make_client: ClientFactory):
    client = make_client(FakeLLM(), user=None)

    res = await client.get("/api/calendar/holidays", params={"year": 2026})

    assert res.status_code == 401


async def told_now(client: httpx.AsyncClient, llm: FakeLLM, character: str = "mano") -> str:
    """What she is told of now in a typed turn with `character`."""
    conversation = await start_conversation(client, character)
    await send_turn(client, conversation, "在吗")
    return context_of(llm.prompts[-1])


async def test_typing_she_is_told_what_the_day_is_in_what_she_knows_of_now(
    make_client: ClientFactory,
):
    """On 文化の日."""
    llm = FakeLLM(REPLY)
    client = make_client(llm, clock=lambda: datetime(2026, 11, 3, 3, tzinfo=UTC))

    told = await told_now(client, llm)

    [now] = [part for part in told.split("\n\n") if part.startswith("# 此刻\n")]
    assert "今天是日本的节假日：文化の日。" in now


async def test_in_a_call_she_is_told_what_the_day_is_too(
    make_client: ClientFactory, settings: Settings, characters: CharacterConfig
):
    """The call is on 09-25 (`test_call_turns.NOW`), Hiori's birthday here."""
    characters.add("hiori", "風野灯織", "sheet", idol_id=2, birthday="09-25")
    client = make_client(FakeLLM())
    conversation = await start_conversation(client)
    call = await CallUnderTest.of(settings, client, conversation)
    call_llm = FakeLLM(MANO_REPLY)

    await call.run(call_llm, [spoken("早上好")])

    assert "今天是風野灯織的生日。" in context_of(call_llm.prompts[-1])


async def test_reaching_out_she_is_told_what_the_day_is_too(
    make_client: ClientFactory, settings: Settings, characters: CharacterConfig
):
    """On 昭和の日, Hiori's birthday here; at 21:00 in Tokyo, 20:00 in Shanghai."""
    characters.add("hiori", "風野灯織", "sheet", idol_id=2, birthday="04-29")
    llm = FakeLLM(REPLY, REPLY)
    clock = FakeClock(datetime(2026, 4, 29, 9, tzinfo=UTC))
    client = make_client(
        llm, clock=clock, random=FakeRandom(0), settings=replace(settings, reach_outs=True)
    )
    conversation = await start_conversation(client)
    await send_turn(client, conversation, "我去练习了")
    last_contact(settings.database_path, conversation, datetime(2026, 4, 28, 13, tzinfo=UTC))
    clock.advance(hours=3)

    await backend_of(client).reach_outs.run_due()

    told = context_of(llm.prompts[-1])
    assert "你们这会儿没在说话" in told
    assert "今天是風野灯織的生日。" in told and "今天是日本的节假日：昭和の日。" in told
