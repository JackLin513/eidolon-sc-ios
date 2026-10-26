"""What the bar writes down (GLOSSARY.md「光顾」): a row for each visit done, the moment her
farewell is written, and nothing of a visit left before it; nothing of what was said. It is
what she remembers next time: how often she has come, how long ago the last time was, what
she had then and how well it was served, whether she got drunk; and only the bar remembers
it, never the conversations. The rows are the user's (`database.USER_DATA`): deleted with
them, not with a conversation, and in no data package.

Driven through the backend's external API, the rows read from the database."""

import io
import sqlite3
import zipfile
from dataclasses import replace
from pathlib import Path

import pytest

from eidolon import data_package
from eidolon.bar_visits import BAR_VISITS_FILE, load_bar_visits
from eidolon.config import Settings
from tests.conftest import CharacterConfig, ClientFactory
from tests.fakes import FakeClock, FakeLLM, FakeRandom
from tests.test_bar_draws import ONE_DRINK, about, visit_done, visit_rows
from tests.test_bar_visit import (
    COMING_IN,
    PARTING,
    coming_in,
    enter,
    mano_alone,
    mixed,
    reacting,
    serve,
)
from tests.test_data_package import export, import_package
from tests.test_delete_account import user_id
from tests.test_text_turn import send_turn, start_conversation


@pytest.fixture
def characters(tmp_path: Path) -> CharacterConfig:
    return mano_alone(tmp_path / "characters")


def remembered(prompt: list) -> str:
    """What a call's prompt tells her of her visits before."""
    return about(prompt).split("# 你在 VA-283 的记录\n")[1].split("\n\n")[0]


async def test_a_visit_done_is_written_down_and_remembered_next_time_without_a_word_said(
    make_client: ClientFactory, settings: Settings
):
    clock = FakeClock()
    llm = FakeLLM(
        COMING_IN, reacting("sparkle-star"), PARTING, coming_in("blue-fairy"),
        coming_in("blue-fairy"),
    )
    # Sugar Rush, then Sparkle Star; a visit left; three days on, her of the day again; Blue
    # Fairy both times, what she wanted the last time avoided.
    client = make_client(
        llm, clock=clock,
        random=FakeRandom(0, 0, 20, 0, 0, 0, 0, 45, 0, 0, 0, 0, *ONE_DRINK, *ONE_DRINK),
    )

    came = await enter(client)
    clock.advance(minutes=5)
    for drink in (mixed("sugar-rush", big=True), mixed("blue-fairy")):
        await serve(client, came[0]["visit_id"], drink)
    left = await enter(client)
    await client.delete(f"/api/bar/visits/{left[0]['visit_id']}")
    clock.advance(days=3)
    await enter(client)

    [row] = visit_rows(settings.database_path)
    assert row == {
        "id": row["id"], "user_id": user_id(settings.database_path, "producer"),
        "character_id": "mano", "entered_at": "2026-09-25T12:00:00+00:00",
        "left_at": "2026-09-25T12:05:00+00:00", "entered_on": "2026-09-25",
        "reason": row["reason"], "topic": row["topic"], "orders": row["orders"],
        "drunk": 0, "rewarded": 0,
    }
    with sqlite3.connect(settings.database_path) as db:
        dumped = "\n".join(db.iterdump())
    db.close()
    assert "こんばんは" not in dumped and "晚上好" not in dumped
    assert remembered(llm.prompts[0]) == "这是你第一次来 VA-283。"
    assert remembered(llm.prompts[4]) == "\n".join([
        "你来过 1 次了。",
        "上次来是 3 天前。",
        "上次点的：第 1 杯要的是 Sugar Rush，制作人上的是 Sugar Rush（大杯），上对了；"
        "第 2 杯要的是 Sparkle Star，制作人上的是 Blue Fairy，上错了。",
        "上次没有喝醉。",
        "聊过什么你不记得了。",
    ])


async def test_five_visits_draw_no_reason_or_topic_of_the_last_three_and_make_her_a_regular(
    make_client: ClientFactory, settings: Settings
):
    listed = load_bar_visits(settings.characters_path.parent / BAR_VISITS_FILE)
    clock = FakeClock()
    sugar_rush, sparkle_star = COMING_IN, coming_in("sparkle-star")
    llm = FakeLLM(
        *[sugar_rush, PARTING, sparkle_star, PARTING] * 2, sugar_rush, PARTING, sparkle_star,
        sparkle_star,
    )
    # Five visits that day, of one drink each, the first of what is left each time, she by
    # chance from the second on; two weeks on, and a minute more. Served Sugar Rush each
    # time, she wants Sugar Rush and Sparkle Star by turns, avoiding what she wanted last.
    client = make_client(
        llm, clock=clock,
        random=FakeRandom(*ONE_DRINK, 0, *[0, *ONE_DRINK, 0] * 4, *ONE_DRINK, *ONE_DRINK),
    )

    for _ in range(5):
        await visit_done(client, mixed("sugar-rush"))
    clock.advance(days=14)
    two_weeks = await enter(client)
    await client.delete(f"/api/bar/visits/{two_weeks[0]['visit_id']}")
    clock.advance(minutes=1)
    await enter(client)

    drawn = [(r["reason"], r["topic"]) for r in visit_rows(settings.database_path)]
    reasons, topics = listed.reasons, listed.topics
    assert drawn == [(reasons[i].id, topics[i].id) for i in (0, 1, 2, 3, 0)]
    for (reason, topic), prompt in zip(drawn, llm.prompts[::2]):
        assert next(r.note for r in reasons if r.id == reason) in about(prompt)
        assert next(t.note for t in topics if t.id == topic) in about(prompt)
    fifth, then, later = (remembered(llm.prompts[i]) for i in (8, 10, 11))
    assert fifth.startswith("你来过 4 次了。\n上次来是今天早些时候。\n")
    assert then.startswith("你是这里的常客，已经来过 5 次了。\n上次来是 14 天前。\n上次点的")
    assert later.startswith("你是这里的常客，已经来过 5 次了。\n上次来是 14 天前。\n很久没来了")


async def test_the_conversations_know_nothing_of_the_bar(make_client: ClientFactory):
    llm = FakeLLM(COMING_IN, PARTING, ["<ja>はい</ja><zh>好的</zh>"])
    client = make_client(llm, random=FakeRandom(*ONE_DRINK, 0))

    await visit_done(client, mixed("sugar-rush"))
    await send_turn(client, await start_conversation(client), "昨晚喝了什么？")

    told = "\n".join(m.content for m in llm.prompts[2])
    for word in ("VA-283", "酒吧", "光顾", "Sugar Rush", "シュガーラッシュ", "こんばんは"):
        assert word not in told, word


async def test_deleted_with_the_user_not_with_a_conversation(
    make_client: ClientFactory, settings: Settings
):
    client = make_client(FakeLLM(COMING_IN, PARTING), random=FakeRandom(*ONE_DRINK, 0))
    await visit_done(client, mixed("sugar-rush"))
    past = await start_conversation(client)
    await start_conversation(client)  # hers now, the other past

    deleted_conversation = await client.delete(f"/api/conversations/{past}")
    kept = visit_rows(settings.database_path)
    deleted_user = await client.post("/api/account/delete", json={"confirm": True})

    assert deleted_conversation.status_code == 204 and len(kept) == 1
    assert deleted_user.status_code == 204
    assert visit_rows(settings.database_path) == []


async def test_neither_exported_nor_imported(
    make_client: ClientFactory, settings: Settings, tmp_path: Path
):
    here = make_client(FakeLLM(COMING_IN, PARTING), random=FakeRandom(*ONE_DRINK, 0))
    there_settings = replace(settings, database_path=tmp_path / "other.db")
    there = make_client(
        FakeLLM(COMING_IN, PARTING), settings=there_settings, random=FakeRandom(*ONE_DRINK, 0)
    )
    await visit_done(here, mixed("sugar-rush"))
    await visit_done(there, mixed("sparkle-star"))
    [row] = visit_rows(settings.database_path)

    package = await export(here, ",".join(data_package.CATEGORIES))
    res = await import_package(there, package, ",".join(data_package.CATEGORIES))

    with zipfile.ZipFile(io.BytesIO(package)) as unzipping:
        assert not any(row["orders"].encode() in unzipping.read(f) for f in unzipping.namelist())
        assert not any(b"sugar-rush" in unzipping.read(f) for f in unzipping.namelist())
    assert res.status_code == 200, res.text
    [theirs] = visit_rows(there_settings.database_path)
    assert '"served": "sparkle-star"' in theirs["orders"]
