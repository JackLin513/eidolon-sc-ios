"""Reach-outs (GLOSSARY.md「搭话」): what she says first in her current conversation with the
user, the user not talking to her. The deployer turns them on; then, at every tick, each
current conversation the user has had a turn in, last in touch with her within a week, has
one once its time comes: the last contact (her last turn recorded, or a call that connected
ending) and a time drawn from her tier's range, intimate 3–6 hours, close 8–16, trust 20–36
(trust where affinity is off); none in cold or distant, a cooldown, a conversation she has
ended, or after one since the last contact. Generated on the deployer's chat model as text
turns use it, whoever's LLM the user brings, laid out as a text turn's prompt is; recorded in
the conversation as she would reply, in a group of its own, and the conversation list's last
line; with an activity record of its own, which no count of turns or calls takes in.

Driven through the backend's external API, with the reach-outs' ticks taken by hand
(`ReachOuts.run_due`), the clock moved, chance fixed (`FakeRandom`), and when the last
contact was set in the database directly, as the store writes the time as it is."""

import sqlite3
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
import pytest

from eidolon.assembly import Backend
from eidolon.config import Settings
from eidolon.engine import REACH_OUT_RULES, WANTS_TO_REACH_OUT
from eidolon.llm import LLMError
from tests.conftest import ClientFactory
from tests.fakes import (
    DEPLOYER_KEY,
    FAKE_JUDGE,
    FakeBackgroundLLM,
    FakeClock,
    FakeIdentityProvider,
    FakeLLM,
    FakeLLMService,
    FakeRandom,
    FakeServiceClients,
    context_of,
    system_of,
)
from tests.test_activity_records import dashboard, health
from tests.test_admin_users import ADMIN, admin_beside, details, find
from tests.test_affinity import keep
from tests.test_conversation_titles import TITLE, listed_titles, naming
from tests.test_delete_account import DELETE
from tests.test_own_llm import LLM as OWN_LLM
from tests.test_stats import stats
from tests.test_text_turn import send_turn, start_conversation

REPLY = ["<ja>はい</ja><zh>好的</zh>"]
REACH_OUT = ["<ja>[happily] プロデューサーさん！</ja><zh>制作人！</zh><ja>レッスン終わったよ</ja><zh>练习结束了哦</zh>"]
REACH_OUTS = "/api/admin/config/reach_outs"
MIDDLE = 500
"""Where in her tier's range the time is drawn: halfway (`reach_outs.PLACES`)."""


@pytest.fixture
def settings(settings: Settings) -> Settings:
    """With reach-outs on in `.env`."""
    return replace(settings, reach_outs=True)


def backend_of(client: httpx.AsyncClient) -> Backend:
    return client._transport.app.state.backend  # pyright: ignore[reportAttributeAccessIssue]


def last_contact(database: Path, conversation: str, at: datetime) -> None:
    """Have the conversation's turns have been recorded at `at`, the last contact."""
    with sqlite3.connect(database) as db:
        db.execute(
            "UPDATE messages SET created_at = ? WHERE conversation_id = ?",
            (at.isoformat(), conversation),
        )


async def record(client: httpx.AsyncClient, conversation: str) -> list[dict]:
    res = await client.get(f"/api/conversations/{conversation}/messages")
    assert res.status_code == 200
    return res.json()


def reach_outs(entries: list[dict]) -> list[dict]:
    return [e for e in entries if e.get("type") == "reach_out"]


async def talked(make_client: ClientFactory, *replies: list[str], **services) -> tuple[
    httpx.AsyncClient, FakeLLM, FakeClock, str
]:
    """A client whose user has had a turn with Mano, her chat model replying with `REPLY`
    and then `replies`, on a clock of its own, set to the time it is as the store writes it, so
    that what the store writes and what is set as the last contact come in their order."""
    llm = FakeLLM(REPLY, *replies)
    clock = FakeClock(datetime.now(UTC))
    client = make_client(llm, clock=clock, **services)
    conversation = await start_conversation(client)
    await send_turn(client, conversation, "我去练习了")
    return client, llm, clock, conversation


async def test_once_her_time_comes_she_says_something_first_the_lists_last_line_till_a_turn(
    make_client: ClientFactory, settings: Settings
):
    client, _, clock, conversation = await talked(
        make_client, REACH_OUT, REPLY, random=FakeRandom(MIDDLE)
    )
    last_contact(settings.database_path, conversation, clock.now - timedelta(hours=29))

    await backend_of(client).reach_outs.run_due()

    [said] = reach_outs(await record(client, conversation))
    assert said == {
        "type": "reach_out",
        "id": said["id"],
        "ja": "プロデューサーさん！レッスン終わったよ",
        "zh": "制作人！练习结束了哦",
        "segments": [
            {"ja": "プロデューサーさん！", "zh": "制作人！"},
            {"ja": "レッスン終わったよ", "zh": "练习结束了哦"},
        ],
        "created_at": said["created_at"],
    }
    shown = {
        "role": "character", "text": None, "ja": "プロデューサーさん！レッスン終わったよ",
        "zh": "制作人！练习结束了哦", "created_at": said["created_at"], "reach_out": True,
    }
    [latest] = (await client.get("/api/conversations/latest")).json()
    [listed] = (await client.get("/api/conversations", params={"character_id": "mano"})).json()
    assert latest["last_message"] == shown
    assert listed["last_message"] == shown

    await send_turn(client, conversation, "辛苦了")

    [latest] = (await client.get("/api/conversations/latest")).json()
    assert "reach_out" not in latest["last_message"]
    assert (await record(client, conversation))[-3]["type"] == "reach_out"


async def test_the_closer_she_is_the_sooner_she_comes(
    make_client: ClientFactory, settings: Settings
):
    client, _, clock, conversation = await talked(
        make_client, REACH_OUT,
        settings=replace(settings, judge=FAKE_JUDGE), random=FakeRandom(MIDDLE),
    )
    keep(settings.database_path, "producer", 90, clock.now)  # intimate: 3–6 hours, halfway
    last_contact(settings.database_path, conversation, clock.now)
    reach_out = backend_of(client).reach_outs

    clock.advance(hours=4, minutes=29)
    await reach_out.run_due()
    before = reach_outs(await record(client, conversation))
    clock.advance(minutes=1)
    await reach_out.run_due()
    after = reach_outs(await record(client, conversation))

    assert (len(before), len(after)) == (0, 1)


async def test_where_affinity_is_off_she_comes_as_in_trust(
    make_client: ClientFactory, settings: Settings
):
    client, _, clock, conversation = await talked(
        make_client, REACH_OUT,
        settings=replace(settings, judge=FAKE_JUDGE, affinity_and_gifts=False),
        random=FakeRandom(0),
    )
    keep(settings.database_path, "producer", 90, clock.now)  # kept, but off
    last_contact(settings.database_path, conversation, clock.now)
    reach_out = backend_of(client).reach_outs

    clock.advance(hours=19, minutes=59)
    await reach_out.run_due()
    before = reach_outs(await record(client, conversation))
    clock.advance(minutes=1)
    await reach_out.run_due()

    assert (len(before), len(reach_outs(await record(client, conversation)))) == (0, 1)


def write_event(database: Path, conversation: str, kind: str, at: datetime) -> None:
    """Record a conversation event at `at`, as the store would: a gift of cake, if a gift."""
    with sqlite3.connect(database) as db:
        db.execute(
            "INSERT INTO conversation_events (conversation_id, kind, created_at, gift_id)"
            " VALUES (?, ?, ?, ?)",
            (conversation, kind, at.isoformat(), "cake" if kind == "gift" else None),
        )


def connected_call(database: Path, conversation: str, at: datetime, seconds: float) -> None:
    """Keep a call in the conversation that connected at `at` and lasted `seconds`."""
    with sqlite3.connect(database) as db:
        db.execute(
            "INSERT INTO calls (conversation_id, connected_at, duration_s) VALUES (?, ?, ?)",
            (conversation, at.isoformat(), seconds),
        )


async def test_she_waits_for_the_user_to_answer_before_she_comes_again(
    make_client: ClientFactory, settings: Settings
):
    client, llm, clock, conversation = await talked(
        make_client, REACH_OUT, REPLY, REACH_OUT, REACH_OUT,
        random=FakeRandom(0, 0, 0),
    )
    database = settings.database_path
    last_contact(database, conversation, clock.now - timedelta(hours=20))
    reach_out = backend_of(client).reach_outs
    await reach_out.run_due()

    clock.advance(hours=30)  # unanswered, and a gift is no answer
    write_event(database, conversation, "gift", clock.now)
    await reach_out.run_due()
    unanswered = len(reach_outs(await record(client, conversation)))

    await send_turn(client, conversation, "我回来了")  # answered by a turn
    last_contact(database, conversation, clock.now - timedelta(hours=20))
    await reach_out.run_due()
    after_a_turn = len(reach_outs(await record(client, conversation)))

    connected_call(database, conversation, clock.now - timedelta(hours=21), 3600)  # by a call
    await reach_out.run_due()
    after_a_call = len(reach_outs(await record(client, conversation)))

    assert (unanswered, after_a_turn, after_a_call) == (1, 2, 3)
    assert len(llm.prompts) == 5  # the turns' two, and three reach-outs


async def test_she_reaches_out_only_in_her_current_conversation_once_it_has_a_turn(
    make_client: ClientFactory, settings: Settings
):
    client, _, clock, conversation = await talked(make_client, REACH_OUT, random=FakeRandom(0))
    last_contact(settings.database_path, conversation, clock.now - timedelta(days=2))
    newer = await start_conversation(client)  # begun since, still without a turn
    connected_call(settings.database_path, newer, clock.now - timedelta(days=2), 600)

    await backend_of(client).reach_outs.run_due()

    assert reach_outs(await record(client, conversation)) == []
    assert reach_outs(await record(client, newer)) == []


@pytest.mark.parametrize("why", ["off", "ended", "a week ago", "cold", "cooldown"])
async def test_she_does_not_reach_out(make_client: ClientFactory, settings: Settings, why: str):
    on = replace(settings, judge=FAKE_JUDGE, reach_outs=why != "off")
    client, _, clock, conversation = await talked(make_client, settings=on, random=FakeRandom())
    database = settings.database_path
    ago = timedelta(days=7, minutes=1) if why == "a week ago" else timedelta(days=2)
    last_contact(database, conversation, clock.now - ago)
    if why == "ended":
        write_event(database, conversation, "ended", clock.now - ago)
    if why in ("cold", "cooldown"):
        keep(database, "producer", {"cold": 15, "cooldown": 5}[why], clock.now,
             cooling=why == "cooldown")

    await backend_of(client).reach_outs.run_due()

    assert reach_outs(await record(client, conversation)) == []


async def test_her_tier_now_is_what_she_goes_by(make_client: ClientFactory, settings: Settings):
    client, _, clock, conversation = await talked(
        make_client, REACH_OUT,
        settings=replace(settings, judge=FAKE_JUDGE), random=FakeRandom(0),
    )
    database = settings.database_path
    last_contact(database, conversation, clock.now - timedelta(hours=20))
    keep(database, "producer", 39, clock.now)  # distant: no
    reach_out = backend_of(client).reach_outs
    await reach_out.run_due()
    distant = reach_outs(await record(client, conversation))

    clock.advance(hours=3)  # recovered to trust, 20 hours and more since the last contact
    await reach_out.run_due()

    assert (len(distant), len(reach_outs(await record(client, conversation)))) == (0, 1)


async def test_she_is_asked_as_in_a_text_turn_but_told_they_are_not_talking(
    make_client: ClientFactory, settings: Settings
):
    client, llm, clock, conversation = await talked(
        make_client, REPLY, REACH_OUT,
        settings=replace(settings, judge=FAKE_JUDGE), random=FakeRandom(0),
    )
    database = settings.database_path
    keep(database, "producer", 90, clock.now)
    await send_turn(client, conversation, "今天好累")
    last_contact(database, conversation, clock.now - timedelta(hours=3))
    write_event(database, conversation, "gift", clock.now - timedelta(hours=1))

    await backend_of(client).reach_outs.run_due()

    turn, reaching_out = llm.prompts[-2], llm.prompts[-1]
    assert system_of(reaching_out) == system_of(turn)
    assert [(m.role, m.content) for m in reaching_out if m.role != "system"] == [
        ("user", "我去练习了"), ("assistant", "<ja>はい</ja><zh>好的</zh>"),
        ("user", "今天好累"), ("assistant", "<ja>はい</ja><zh>好的</zh>"),
        ("user", f"（制作人送给你一份蛋糕。）\n{WANTS_TO_REACH_OUT}"),
    ]
    told = context_of(reaching_out)
    assert "你们这会儿没在说话" in told and "正在用文字和你聊天" not in told
    assert "现在是" in told and "非常信赖" in told
    assert REACH_OUT_RULES in told
    assert (llm.tools[-1], llm.forbidden[-1]) == ([], False)


async def test_she_reaches_out_on_the_deployers_chat_model_whatever_the_user_brings(
    make_client: ClientFactory, settings: Settings, own_llm: FakeLLMService
):
    llm = FakeLLM(REACH_OUT)
    own_llm.llm = FakeLLM(REPLY)
    clients = FakeServiceClients(llm)
    client = make_client(llm, clock=(clock := FakeClock(datetime.now(UTC))),
                         clients=clients, random=FakeRandom(0))
    conversation = await start_conversation(client)
    await send_turn(client, conversation, "在吗", own_llm=OWN_LLM)
    last_contact(settings.database_path, conversation, clock.now - timedelta(hours=20))

    await backend_of(client).reach_outs.run_due()

    assert llm.keys == [DEPLOYER_KEY]
    assert clients.efforts == [settings.chat_llm.reasoning_effort]  # as text turns, not calls
    assert len(reach_outs(await record(client, conversation))) == 1


def records(database: Path) -> list[tuple[str, str, str, int]]:
    """Every activity record, oldest first: its kind, character, result and whether on the
    user's own keys."""
    with sqlite3.connect(database) as db:
        return db.execute(
            "SELECT kind, character_id, result, own_keys FROM activity_records ORDER BY id"
        ).fetchall()


async def test_each_has_an_activity_record_of_its_own_which_no_turn_or_call_counts_take_in(
    make_client: ClientFactory, settings: Settings, github: FakeIdentityProvider
):
    settings = replace(settings, admins=frozenset({ADMIN}))
    llm = FakeLLM(REPLY, REPLY, REACH_OUT, LLMError("模型返回 503: overloaded"), tokens=(1000, 200))
    client = make_client(
        llm, settings=settings, clock=(clock := FakeClock(datetime.now(UTC))),
        random=FakeRandom(0, 0),
    )
    database = settings.database_path
    mano, kogane = await start_conversation(client), await start_conversation(client, "kogane")
    for conversation in (mano, kogane):
        await send_turn(client, conversation, "在吗")
    clock.advance(hours=25)  # the turns out of the dashboard's last 24 hours
    for conversation in (mano, kogane):
        last_contact(database, conversation, clock.now - timedelta(hours=20))

    await backend_of(client).reach_outs.run_due()

    assert records(database)[2:] == [
        ("reach_out", "mano", "success", 0), ("reach_out", "kogane", "failed", 0),
    ]
    assert len(reach_outs(await record(client, mano))) == 1
    assert reach_outs(await record(client, kogane)) == []
    async with admin_beside(client, github) as admin:
        board = await dashboard(admin)
        week = await dashboard(admin, "7d")
        user = await find(admin, "producer")
        shown = await details(admin, user["id"])
    assert (board["turns"]["total"], board["calls"]["total"], board["active_users"]) == (0, 0, 0)
    assert sum(point["turns"] + point["calls"] + point["active_users"]
               for point in board["trend"]) == 0
    assert board["characters"] == []
    assert {(c["character_id"], c["turns"], c["calls"]) for c in week["characters"]} == {
        ("mano", 1, 0), ("kogane", 1, 0),
    }
    chat = health(board, "chat_llm")
    assert chat is not None and (chat["calls"], chat["errors"]) == (2, 1)
    [cost] = [r for r in board["cost"]["rows"] if r["service"] == "chat_llm"]
    assert (cost["provider"], cost["calls"], cost["input"], cost["output"]) == (
        "llm.invalid", 2, 1000, 200,
    )
    assert user["usage_24h"] == {"turns": 0, "calls": 0}
    assert shown["usage"]["7d"]["turns"] == {"deployer": 2, "own_keys": 0}
    assert sum(sum(counted.values()) for counted in shown["usage"]["7d"].values()) == 2


async def test_one_she_could_say_nothing_in_fails_is_not_recorded_nor_tried_again(
    make_client: ClientFactory, settings: Settings
):
    client, _, clock, conversation = await talked(
        make_client, ["<photo>selfie</photo>"], random=FakeRandom(0)
    )
    last_contact(settings.database_path, conversation, clock.now - timedelta(hours=20))

    reach_out = backend_of(client).reach_outs
    await reach_out.run_due()
    clock.advance(hours=1)
    await reach_out.run_due()  # not tried again

    assert reach_outs(await record(client, conversation)) == []
    assert records(settings.database_path)[1:] == [("reach_out", "mano", "failed", 0)]


async def test_titles_and_stats_take_no_account_of_her_reach_outs(
    make_client: ClientFactory, settings: Settings
):
    background = FakeBackgroundLLM(TITLE)
    client, _, clock, conversation = await talked(
        make_client, REPLY, REACH_OUT, REPLY, background_llm=background, random=FakeRandom(0)
    )
    await send_turn(client, conversation, "第二句")
    last_contact(settings.database_path, conversation, clock.now - timedelta(hours=20))
    before = await stats(client)
    await backend_of(client).reach_outs.run_due()
    after = await stats(client)

    await send_turn(client, conversation, "第三句")

    assert await listed_titles(client) == [TITLE]
    [prompt] = naming(background.prompts)
    assert "练习结束了哦" not in prompt and "第三句" in prompt
    assert after == before


async def test_off_by_default_the_admin_turns_them_on_with_how_many_a_day(
    make_client: ClientFactory, settings: Settings, github: FakeIdentityProvider
):
    off = replace(settings, reach_outs=False, admins=frozenset({ADMIN}))
    client, _, clock, conversation = await talked(
        make_client, REACH_OUT, settings=off, random=FakeRandom(0)
    )
    last_contact(settings.database_path, conversation, clock.now - timedelta(hours=20))
    reach_out = backend_of(client).reach_outs

    async with admin_beside(client, github) as admin:
        described = (await admin.get("/api/admin/config")).json()["reach_outs"]
        await reach_out.run_due()
        before = reach_outs(await record(client, conversation))
        refused = [
            await admin.put(REACH_OUTS, json=body)
            for body in (
                {"enabled": "yes", "per_day": 3}, {"enabled": True, "per_day": 0},
                {"enabled": True, "per_day": True}, {"enabled": True, "per_day": 1.5},
                {"enabled": True},
            )
        ]
        turned_on = await admin.put(REACH_OUTS, json={"enabled": True, "per_day": 5})
        await reach_out.run_due()

    assert described == {
        "status": "env", "env": {"enabled": False, "per_day": 3},
        "effective": {"enabled": False, "per_day": 3}, "override": None, "failure": None,
    }
    assert before == []
    assert [r.status_code for r in refused] == [422] * 5
    assert turned_on.status_code == 200
    assert turned_on.json()["reach_outs"]["effective"] == {"enabled": True, "per_day": 5}
    assert len(reach_outs(await record(client, conversation))) == 1


async def test_deleting_the_user_deletes_them_and_when_she_was_to_come(
    make_client: ClientFactory, settings: Settings
):
    client, _, clock, conversation = await talked(make_client, REACH_OUT, random=FakeRandom(0))
    last_contact(settings.database_path, conversation, clock.now - timedelta(hours=20))
    await backend_of(client).reach_outs.run_due()

    assert (await client.post("/api/account/delete", json=DELETE)).status_code == 204

    with sqlite3.connect(settings.database_path) as db:
        left = [db.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
                for t in ("reach_outs", "reach_out_schedules")]
    assert left == [0, 0]
