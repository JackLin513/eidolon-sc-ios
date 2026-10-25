"""The calendar's days (GLOSSARY.md「日历」): Japan's national holidays for a year, as the
calendar shows them; and what she knows of them and of birthdays. Her own birthday she always
knows; on the day, by the date in Tokyo, she is told it is hers, whose of the others' it is,
and which holiday, in what she is told of now (「此刻」), typing, in a call or reaching out."""

from dataclasses import replace
from datetime import UTC, datetime, timedelta

import httpx
import pytest

from eidolon.config import Settings
from tests.conftest import CharacterConfig, ClientFactory
from tests.fakes import FakeClock, FakeLLM, FakeRandom, context_of
from tests.test_call_turns import MANO_REPLY, CallUnderTest, spoken
from tests.test_reach_outs import backend_of, last_contact
from tests.test_text_turn import send_turn, start_conversation
from tests.test_world_setting import write_world

REPLY = ["<ja>はいっ</ja><zh>好的</zh>"]
HER_BIRTHDAY = "今天是你的生日。"
TOKYO_MIDNIGHT = datetime(2026, 4, 24, 15, 30, tzinfo=UTC)
"""Mano's birthday (04-25, the fixture's) at 00:30 in Tokyo; still 04-24, 23:30 in Shanghai,
where the producer is."""


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


async def test_her_birthday_begins_at_midnight_in_tokyo_whatever_the_producers_day(
    make_client: ClientFactory,
):
    llm = FakeLLM(REPLY, REPLY)
    clock = FakeClock(TOKYO_MIDNIGHT - timedelta(hours=1))
    client = make_client(llm, clock=clock)

    before = await told_now(client, llm)
    clock.advance(hours=1)
    on_the_day = await told_now(client, llm)

    assert HER_BIRTHDAY not in before
    [line] = [line for line in on_the_day.splitlines() if HER_BIRTHDAY in line]
    assert "不要每句都提" in line and "不向制作人要礼物" in line and "祝福你就接受" in line
    assert on_the_day.startswith("# 此刻\n现在是 2026年4月24日")  # the producer's day still


async def test_on_others_birthdays_she_is_told_whose_herself_not_among_them(
    make_client: ClientFactory, characters: CharacterConfig
):
    """Kogane's birthday is 02-25 (the fixture's); the clerk counts among the others."""
    characters.add("hazuki", "七草はづき", "sheet", idol_id=91, birthday="02-25")
    characters.add("meguru", "八宮めぐる", "sheet", idol_id=3, birthday="02-25")
    llm = FakeLLM(REPLY, REPLY)
    client = make_client(llm, clock=lambda: datetime(2026, 2, 25, 3, tzinfo=UTC))

    with_mano = await told_now(client, llm, "mano")
    with_kogane = await told_now(client, llm, "kogane")

    others = "今天是八宮めぐる、七草はづき、月岡恋鐘的生日。可以顺口提一句，不要替她们向制作人要祝福，也不要催制作人做什么。"
    assert others in with_mano and HER_BIRTHDAY not in with_mano
    assert "今天是八宮めぐる、七草はづき的生日。" in with_kogane and HER_BIRTHDAY in with_kogane


async def test_on_a_holiday_she_is_told_which_right_after_now_in_its_section(
    make_client: ClientFactory,
):
    llm = FakeLLM(REPLY)
    client = make_client(llm, clock=lambda: datetime(2026, 11, 3, 3, tzinfo=UTC))

    told = await told_now(client, llm)

    now, *_ = told.split("\n\n")
    assert now.startswith("# 此刻\n")
    assert now.endswith("今天是日本的节假日：文化の日。可以自然地提到，不必每句都说。")


async def test_on_a_day_that_is_nothing_she_is_told_nothing_of_it(make_client: ClientFactory):
    """No one's birthday nor a holiday in Tokyo: the day before 文化の日, 21:00 there."""
    llm = FakeLLM(REPLY)
    client = make_client(llm, clock=lambda: datetime(2026, 11, 2, 12, tzinfo=UTC))

    told = await told_now(client, llm)

    assert "的生日" not in told and "节假日" not in told


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


ON_THE_DAY = "今天是2年前你站上「THE IDOLM@STER SHINY COLORS 6thLIVE」第1天的日子（2024年3月2日，ベルーナドーム）。"
"""Mano's line on 03-02 two years after (`write_world`'s 6thLIVE)."""


async def test_on_the_day_of_a_live_she_stood_on_years_ago_she_is_told_it_is_past(
    make_client: ClientFactory, characters: CharacterConfig
):
    """In Tokyo 2026-03-02, 09:00; she stood on 6thLIVE's first day, 2024-03-02, and on no
    other live on the day."""
    write_world(characters)
    llm = FakeLLM(REPLY)
    client = make_client(llm, clock=lambda: datetime(2026, 3, 2, 0, tzinfo=UTC))

    told = await told_now(client, llm)

    now, *_ = told.split("\n\n")
    [line] = [line for line in now.splitlines() if "年前你站上" in line]
    assert line.startswith(ON_THE_DAY)
    assert "今天没有这场演出" in line and "当回忆" in line


async def test_on_the_day_of_a_live_she_was_absent_from_or_still_to_come_she_is_told_nothing_of_it(
    make_client: ClientFactory, characters: CharacterConfig
):
    """6thLIVE's second day, 03-03, her CV absent; and 8thLIVE's first day, 2026-11-07,
    which is today, not years ago."""
    write_world(characters)
    llm = FakeLLM(REPLY, REPLY)

    absent = await told_now(make_client(llm, clock=lambda: datetime(2026, 3, 3, 0, tzinfo=UTC)), llm)
    to_come = await told_now(make_client(llm, clock=lambda: datetime(2026, 11, 7, 0, tzinfo=UTC)), llm)

    assert "年前你站上" not in absent and "年前你站上" not in to_come


async def test_reaching_out_on_the_day_of_a_live_years_ago_she_is_told_it_is_past(
    make_client: ClientFactory, settings: Settings, characters: CharacterConfig
):
    """In Tokyo 2026-03-02, 11:00; 10:00 in Shanghai."""
    write_world(characters)
    llm = FakeLLM(REPLY, REPLY)
    clock = FakeClock(datetime(2026, 3, 1, 23, tzinfo=UTC))
    client = make_client(
        llm, clock=clock, random=FakeRandom(0), settings=replace(settings, reach_outs=True)
    )
    conversation = await start_conversation(client)
    await send_turn(client, conversation, "我去练习了")
    last_contact(settings.database_path, conversation, datetime(2026, 3, 1, 6, tzinfo=UTC))
    clock.advance(hours=3)

    await backend_of(client).reach_outs.run_due()

    told = context_of(llm.prompts[-1])
    assert "你们这会儿没在说话" in told and ON_THE_DAY in told
