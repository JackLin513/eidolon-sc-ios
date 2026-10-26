"""What a visit to the bar draws (GLOSSARY.md「光顾」「来意」「话题」「点单」), and how the drinks
served are judged, driven through the backend's external API: who comes, by the user and the
day until they have a visit done that day, then by chance; why she came and what about, none
of her latest visits' again; which drink she orders, never of the flavor she dislikes, none
twice a visit, her first none of what she had the last time. What is drawn is read from her
prompt and the visit records, as the browser is told none of it but who came.

The random source is asked, in order: coming in, who she is if the user has a visit done that
day, her reason (whether it is her job first, if she has one done today), her topic, how many
drinks (0 one, 20 two, 80 three), and her first order: its bucket (0 a favorite, 45 her
liking, 80 any) and which of it; serving, the fixed line the producer says, and, another to
come, her next order likewise."""

import json
import sqlite3
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path

import httpx

from eidolon.bar_visits import BAR_VISITS_FILE, load_bar_visits
from eidolon.config import Settings
from tests.conftest import CharacterConfig, ClientFactory
from tests.fakes import FAKE_JUDGE, FakeClock, FakeLLM, FakeRandom
from tests.test_affinity import keep
from tests.test_bar_visit import (
    COMING_IN,
    MANO_TASTES,
    PARTING,
    REACTING,
    enter,
    mano_alone,
    mixed,
    serve,
)
from tests.test_schedule_saving import WEEK, placed, publish, save
from tests.test_schedule_she_knows import EARLY_MONDAY

ONE_DRINK = [0, 0, 0, 0, 0]
"""Coming in to a user's character of the day: her first reason and topic, one drink, her
first favorite."""


def only_mano(settings: Settings, tmp_path: Path) -> Settings:
    """The settings with Mano the only character, liking what is sweet and girly, Sugar Rush
    best, and disliking what is bitter."""
    return replace(settings, characters_path=mano_alone(tmp_path / "mano-only").path)


async def visit_done(client: httpx.AsyncClient, *drinks: dict) -> str:
    """Come in and be served `drinks`, the visit done: who came."""
    came = await enter(client)
    for drink in drinks:
        await serve(client, came[0]["visit_id"], drink)
    return came[0]["character_id"]


def visit_rows(database: Path) -> list[dict]:
    with sqlite3.connect(database) as db:
        db.row_factory = sqlite3.Row
        rows = [dict(r) for r in db.execute("SELECT * FROM visit_records ORDER BY id")]
    db.close()
    return rows


def about(prompt: list) -> str:
    """What a call's prompt tells of the visit."""
    return prompt[1].content


async def test_her_of_the_day_comes_until_a_visit_is_done_and_then_anyone_does(
    make_client: ClientFactory,
):
    # Three times in as her of the day, the last served and done; then by chance, Kogane
    # (the second) and Mano (the first).
    llm = FakeLLM(COMING_IN, COMING_IN, COMING_IN, PARTING, COMING_IN, COMING_IN)
    client = make_client(llm, random=FakeRandom(*ONE_DRINK * 3, 0, 1, *ONE_DRINK, 0, *ONE_DRINK))

    left = (await enter(client))[0]
    await client.delete(f"/api/bar/visits/{left['visit_id']}")
    done_away_with = (await enter(client))[0]["character_id"]
    done = await visit_done(client, mixed("sugar-rush"))
    by_chance = [(await enter(client))[0]["character_id"] for _ in range(2)]

    assert left["character_id"] == done_away_with == done
    assert by_chance == ["kogane", "mano"]


async def test_her_of_the_day_changes_with_the_day_by_beijing_time(make_client: ClientFactory):
    days = 30
    clock = FakeClock(datetime(2026, 9, 25, 15, 30, tzinfo=UTC))  # 23:30 in Beijing
    llm = FakeLLM(*[COMING_IN] * (days + 1))
    client = make_client(llm, clock=clock, random=FakeRandom(*ONE_DRINK * (days + 1)))

    before_midnight = (await enter(client))[0]["character_id"]
    clock.advance(minutes=29)
    still_that_day = (await enter(client))[0]["character_id"]
    whose = set()
    for _ in range(days - 1):
        clock.advance(days=1)
        whose.add((await enter(client))[0]["character_id"])

    assert before_midnight == still_that_day
    assert whose == {"mano", "kogane"}  # by chance alike for 29 days: one in half a billion


async def test_a_visit_done_after_midnight_is_of_the_day_it_came_in_on(
    make_client: ClientFactory, settings: Settings
):
    clock = FakeClock(datetime(2026, 9, 25, 15, 50, tzinfo=UTC))  # 23:50 in Beijing
    llm = FakeLLM(COMING_IN, PARTING, COMING_IN)
    # The next day it is her of that day who comes: nothing drawn for who.
    client = make_client(llm, clock=clock, random=FakeRandom(*ONE_DRINK, 0, *ONE_DRINK))

    came = await enter(client)
    clock.advance(minutes=20)
    await serve(client, came[0]["visit_id"], mixed("sugar-rush"))
    next_day = await enter(client)

    [row] = visit_rows(settings.database_path)
    assert row["entered_on"] == "2026-09-25"
    assert row["entered_at"] == "2026-09-25T15:50:00+00:00"
    assert row["left_at"] == "2026-09-25T16:10:00+00:00"
    assert next_day[0]["type"] == "visit"


async def test_she_comes_in_a_cooldown_cold_with_the_producer(
    make_client: ClientFactory, settings: Settings
):
    llm = FakeLLM(COMING_IN)
    client = make_client(
        llm, settings=replace(settings, judge=FAKE_JUDGE), random=FakeRandom(*ONE_DRINK)
    )
    now = datetime.now(UTC)
    for character in ("mano", "kogane"):
        keep(settings.database_path, "producer", 5, now, character=character, cooling=True)

    came = await enter(client)

    assert came[0]["type"] == "visit" and came[-1]["type"] == "waiting"
    assert "态度很冷" in about(llm.prompts[0])


async def test_her_latest_three_visits_reasons_and_topics_are_not_drawn_again(
    make_client: ClientFactory, settings: Settings, tmp_path: Path
):
    settings = only_mano(settings, tmp_path)
    listed = load_bar_visits(settings.characters_path.parent / BAR_VISITS_FILE)
    llm = FakeLLM(*[COMING_IN, PARTING] * 5)
    # The first of what is left each time; Mano by chance from the second visit on.
    client = make_client(
        llm, settings=settings, random=FakeRandom(*ONE_DRINK, 0, *[0, *ONE_DRINK, 0] * 4)
    )

    for _ in range(5):
        await visit_done(client, mixed("sugar-rush"))

    drawn = [(r["reason"], r["topic"]) for r in visit_rows(settings.database_path)]
    reasons, topics = listed.reasons, listed.topics
    assert drawn == [(reasons[i].id, topics[i].id) for i in (0, 1, 2, 3, 0)]
    for (reason, topic), prompt in zip(drawn, llm.prompts[::2]):
        assert next(r.note for r in reasons if r.id == reason) in about(prompt)
        assert next(t.note for t in topics if t.id == topic) in about(prompt)


async def test_her_job_done_today_is_her_reason_half_the_time(
    make_client: ClientFactory, settings: Settings, tmp_path: Path
):
    settings = only_mano(settings, tmp_path)
    clock = FakeClock(EARLY_MONDAY)
    llm = FakeLLM(COMING_IN, COMING_IN, COMING_IN)
    # Before it is done, no chance is taken on it; done, heads it is her reason, then tails.
    client = make_client(
        llm, settings=settings, clock=clock, random=FakeRandom(*ONE_DRINK, 0, *ONE_DRINK[1:], 1, *ONE_DRINK)
    )
    publish(settings.database_path, WEEK, ("声乐课", 1, None), ("拍摄广告", 1, None))
    await save(client, WEEK, placed("声乐课", 0, 0), placed("拍摄广告", 1, 0))  # Monday, Tuesday

    await enter(client)
    clock.advance(hours=11)  # Monday 12:00: the lesson done
    await enter(client)
    await enter(client)

    before, heads, tails = (about(p) for p in llm.prompts)
    first = load_bar_visits(settings.characters_path.parent / BAR_VISITS_FILE).reasons[0]
    assert "声乐课" not in before and first.note in before
    assert "你今天完成了制作人排给你的工作「声乐课」（说明）" in heads
    assert first.note not in heads and "拍摄广告" not in heads
    assert "声乐课" not in tails and first.note in tails


async def test_with_schedules_off_she_has_no_job_for_a_reason(
    make_client: ClientFactory, settings: Settings, tmp_path: Path
):
    settings = only_mano(settings, tmp_path)
    clock = FakeClock(EARLY_MONDAY)
    llm = FakeLLM(COMING_IN)
    client = make_client(llm, settings=settings, clock=clock, random=FakeRandom(*ONE_DRINK))
    publish(settings.database_path, WEEK, ("声乐课", 1, None))
    await save(client, WEEK, placed("声乐课", 0, 0))
    off = make_client(
        llm, settings=replace(settings, schedule=False), clock=clock,
        random=FakeRandom(*ONE_DRINK),  # no chance taken on it
    )
    clock.advance(hours=11)

    await enter(off)

    assert "声乐课" not in about(llm.prompts[0])


async def test_reasons_and_topics_not_for_her_are_never_drawn(
    make_client: ClientFactory, settings: Settings, tmp_path: Path
):
    config = CharacterConfig(tmp_path / "hazuki-only")
    entries = [
        f'[[{table}]]\nid = "{table}-{n}"\nnote = "{table} {n}。"\n'
        + ('mood = "calm"\n' if table == "reasons" else "")
        + ('not_for = ["hazuki"]\n' if n == 0 else "")
        for table in ("reasons", "topics") for n in range(5)
    ]
    config.write(BAR_VISITS_FILE, "\n".join(entries))
    config.add("hazuki", "七草はづき", "# 人设\n你是七草はづき。", bar=MANO_TASTES)
    llm = FakeLLM(COMING_IN)
    client = make_client(
        llm, settings=replace(settings, characters_path=config.path), random=FakeRandom(*ONE_DRINK)
    )

    await enter(client)

    assert "reasons 1。" in about(llm.prompts[0]) and "topics 1。" in about(llm.prompts[0])
    assert "reasons 0。" not in about(llm.prompts[0])


def ordered(prompt: list) -> str:
    """The drink her order card in a call's prompt names."""
    card = prompt[-1].content.split("点单卡：")[1]
    return card.split("- 饮品：")[1].split("（")[0]


async def test_she_never_orders_what_she_dislikes_nor_one_drink_twice(
    make_client: ClientFactory, settings: Settings, tmp_path: Path
):
    llm = FakeLLM(COMING_IN, REACTING, REACTING)
    # Three drinks: a favorite, Sugar Rush; the fourth to her liking, past bitter Sunshine
    # Cloud; any but those, bitter and what she had: the fourth, past Sunshine Cloud again.
    client = make_client(
        llm, settings=only_mano(settings, tmp_path),
        random=FakeRandom(0, 0, 80, 0, 0, 0, 45, 3, 0, 80, 3),
    )

    visit_id = (await enter(client))[0]["visit_id"]
    await serve(client, visit_id, mixed("sugar-rush"))
    await serve(client, visit_id, mixed("moonblast"))

    assert [ordered(p) for p in llm.prompts] == ["Sugar Rush", "Moonblast", "Marsblast"]


async def test_her_first_order_is_none_of_what_she_wanted_the_last_time(
    make_client: ClientFactory, settings: Settings, tmp_path: Path
):
    settings = only_mano(settings, tmp_path)
    llm = FakeLLM(COMING_IN, REACTING, PARTING, COMING_IN, REACTING)
    # The last time Sugar Rush, served right, then Sparkle Star, served wrong; this time a
    # favorite falls to her liking, past both, and her second is Sugar Rush again.
    client = make_client(
        llm, settings=settings,
        random=FakeRandom(0, 0, 20, 0, 0, 0, 45, 0, 0, 0, 0, 0, 20, 0, 0, 0, 0, 0),
    )

    await visit_done(client, mixed("sugar-rush"), mixed("blue-fairy"))
    visit_id = (await enter(client))[0]["visit_id"]
    await serve(client, visit_id, mixed("blue-fairy"))

    assert [ordered(p) for p in llm.prompts[3:]] == ["Blue Fairy", "Sugar Rush"]


async def test_ordered_by_name_only_that_drink_is_right_in_any_glass(
    make_client: ClientFactory, settings: Settings, tmp_path: Path
):
    settings = only_mano(settings, tmp_path)
    llm = FakeLLM(COMING_IN, REACTING, REACTING, PARTING, COMING_IN, REACTING, PARTING)
    client = make_client(
        llm, settings=settings,
        # Sugar Rush, Sparkle Star, Blue Fairy; then Fluffy Dream and Sugar Rush.
        random=FakeRandom(
            0, 0, 80, 0, 0, 0, 45, 0, 0, 45, 0, 0,
            0, 0, 0, 20, 0, 0, 0, 0, 0, 0,
        ),
    )

    await visit_done(
        client, mixed("sugar-rush", big=True),
        mixed("brandtini"),  # sweet, classy: not girly
        mixed("fluffy-dream"),  # sour, girly: not sweet
    )
    await visit_done(
        client, mixed("gut-punch"),  # bitter: disliked
        mixed("piano-man"),  # sour, promo: neither
    )

    orders = [json.loads(r["orders"]) for r in visit_rows(settings.database_path)]
    assert orders == [
        [
            {"target": "sugar-rush", "phrasing": "name", "served": "sugar-rush", "big": True, "tier": "right"},
            {"target": "sparkle-star", "phrasing": "name", "served": "brandtini", "big": False, "tier": "wrong"},
            {"target": "blue-fairy", "phrasing": "name", "served": "fluffy-dream", "big": False, "tier": "wrong"},
        ],
        [
            {"target": "fluffy-dream", "phrasing": "name", "served": "gut-punch", "big": False, "tier": "wrong"},
            {"target": "sugar-rush", "phrasing": "name", "served": "piano-man", "big": False, "tier": "wrong"},
        ],
    ]
    told = [p[-1].content for p in llm.prompts[1:4] + llm.prompts[5:]]
    assert "判定：上对了" in told[0]
    assert "口味对了，种类不对" in told[1]
    assert "种类对了，口味不对" in told[2]
    assert "你讨厌的苦口味" in told[3]
    assert "完全不对" in told[4]
    assert "第 1 杯上对了；第 2 杯上错了；第 3 杯上错了" in told[2]
