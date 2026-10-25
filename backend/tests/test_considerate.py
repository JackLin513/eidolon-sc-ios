"""In her period and the days before it (GLOSSARY.md「周期」「体贴」), the judge model is asked
one question more in the same request, the considerate question, its wording telling which of
the two she is in; on her other days, or with either switch off, the request is as it was.
Then her affinity goes by these days' numbers: the two levels that lower it by twice as much,
by 0.5 more for what is inconsiderate, by 0.3 more for what is considerate, those 0.3s 0.6 a
day at most apart from the turns' own 0.6, never for what tries to dictate it; out of line
by 10 as ever. She is told how the considerate or the inconsiderate makes her feel, after how
the turn's level does. She warns sooner and hangs up, or ends the conversation, sooner: four
and eight, what is inconsiderate hurting her by 2 more. The run records keep nothing of it.

Driven through the backend's external API, the judge model faked turn by turn, the clock
moved to a day her true cycle has her where wanted (`test_her_days`)."""

import json
import sqlite3
from dataclasses import replace
from pathlib import Path

import httpx
import pytest

from eidolon.config import Settings
from eidolon.her_cycle import HerDay
from tests.conftest import ClientFactory
from tests.fakes import (
    FAKE_JUDGE,
    FakeClock,
    FakeEmbedder,
    FakeLLM,
    FakeReranker,
    FakeServiceClients,
    Judging,
    level,
)
from tests.test_affinity import keep
from tests.test_affinity_cooldown import PARTING
from tests.test_affinity_prompt import FEELINGS, about_now
from tests.test_affinity_turns import value
from tests.test_call_turns import MANO_REPLY, NOW, CallUnderTest
from tests.test_cycles_switch import switch
from tests.test_her_days import a_key_when, a_noon_when, in_period, on_a_day, premenstrual
from tests.test_she_ends_conversation import WARNING
from tests.test_she_hangs_up import HANGING_UP, one_by_one
from tests.test_she_hangs_up import WARNING as CALL_WARNING
from tests.test_text_turn import send_turn, start_conversation

REPLY = ["<ja>はい</ja><zh>好的</zh>"]
CONSIDERATE = "considerate"
"""The key the considerate question is asked and answered under."""
WARM = {
    "period": "制作人察觉到你不舒服、照顾着你，你心里很暖。",
    "premenstrual": "制作人察觉到你这几天心情不好、体谅着你，你心里很暖。",
}
SADDER = {
    "period": "制作人没顾及你现在不舒服，你更难受了。",
    "premenstrual": "制作人没顾及你这几天心情不好，你更委屈了。",
}
DAYS = {"period": in_period(early=True), "premenstrual": premenstrual(near=True)}


def neither(her_day: HerDay) -> bool:
    return her_day is None


@pytest.fixture
def settings(settings: Settings) -> Settings:
    """With the judge model, affinity and cycles on."""
    return replace(settings, judge=FAKE_JUDGE, affinity_and_gifts=True, cycles=True)


async def judged_on(
    make_client: ClientFactory,
    settings: Settings,
    wanted,
    judgings: list[Judging],
    *,
    deployment: Settings | None = None,
    kept: float = 60,
) -> tuple[FakeServiceClients, FakeLLM, httpx.AsyncClient, list[float | None]]:
    """Take a turn for each of `judgings` on a noon she is where `wanted`, her affinity kept
    at `kept` as the first begins (above the normal value, not to recover): the judge model,
    the chat model, the client and the value each turn leaves."""
    clients = FakeServiceClients()
    clients.judge.judgings = list(judgings)
    llm = FakeLLM(*[REPLY] * max(len(judgings), 1))
    client = on_a_day(make_client, settings, wanted, llm, deployment, clients=clients)
    conversation = await start_conversation(client)
    keep(settings.database_path, "producer", kept, a_noon_when(settings, wanted))
    values = []
    for i in range(len(judgings)):
        await send_turn(client, conversation, f"第{i}句")
        values.append(value(settings.database_path))
    return clients, llm, client, values


async def test_on_her_other_days_the_judge_model_is_asked_byte_for_byte_as_with_cycles_off(
    make_client: ClientFactory, settings: Settings
):
    on, *_ = await judged_on(make_client, settings, neither, [level(2)])
    off, *_ = await judged_on(
        make_client, settings, neither, [level(2)], deployment=replace(settings, cycles=False)
    )

    assert json.dumps(on.judge.questions, ensure_ascii=False) == json.dumps(
        off.judge.questions, ensure_ascii=False
    )
    assert on.judge.states == off.judge.states
    assert CONSIDERATE not in on.judge.questions[-1]


async def test_in_her_days_one_question_more_its_wording_telling_which_days(
    make_client: ClientFactory, settings: Settings
):
    ordinary, *_ = await judged_on(make_client, settings, neither, [level(2)])
    asked = {}
    for days, wanted in DAYS.items():
        clients, *_ = await judged_on(make_client, settings, wanted, [level(2)])
        [questions] = clients.judge.questions
        assert {k: v for k, v in questions.items() if k != CONSIDERATE} == (
            ordinary.judge.questions[-1]
        )
        assert clients.judge.states[-1] == ordinary.judge.states[-1]
        asked[days] = questions[CONSIDERATE]

    for question in asked.values():
        assert question["type"] == "score"
        assert len(question["criteria"]) == 3
    assert "经期" in asked["period"]["instructions"]
    assert "经前" in asked["premenstrual"]["instructions"]
    assert asked["period"] != asked["premenstrual"]


async def test_with_retrieval_on_it_is_asked_in_retrievals_request(
    make_client: ClientFactory, settings: Settings
):
    clients = FakeServiceClients()
    clients.judge.judgings = [level(1, considerate=0)]
    client = on_a_day(
        make_client, settings, DAYS["period"], FakeLLM(REPLY), clients=clients, embedder=FakeEmbedder(), reranker=FakeReranker(),
    )
    conversation = await start_conversation(client)
    keep(settings.database_path, "producer", 60, a_noon_when(settings, DAYS["period"]))

    await send_turn(client, conversation, "快去训练")

    assert [kind for _, kind in clients.judge.asked] == ["turn"]
    assert CONSIDERATE in clients.judge.questions[-1]
    assert value(settings.database_path) == pytest.approx(58.5)


async def test_with_the_user_turning_cycles_off_it_is_not_asked_and_affinity_goes_as_ever(
    make_client: ClientFactory, settings: Settings
):
    clients = FakeServiceClients()
    clients.judge.judgings = [level(1, considerate=0)]
    client = on_a_day(make_client, settings, DAYS["period"], FakeLLM(REPLY), clients=clients)
    await switch(client, False)
    conversation = await start_conversation(client)
    keep(settings.database_path, "producer", 60, a_noon_when(settings, DAYS["period"]))

    await send_turn(client, conversation, "快去训练")

    assert CONSIDERATE not in clients.judge.questions[-1]
    assert value(settings.database_path) == pytest.approx(59.5)


async def test_in_her_days_what_lowers_it_does_twice_as_much_and_inconsiderate_half_more(
    make_client: ClientFactory, settings: Settings
):
    *_, values = await judged_on(make_client, settings, DAYS["period"], [
        level(2, considerate=0), level(2, considerate=2), level(1), level(1, considerate=0),
    ])
    # In a conversation of its own, as she ends the first once they have hurt her too much.
    *_, worse = await judged_on(make_client, settings, DAYS["period"], [
        level(0), level(4, out_of_line=True, considerate=0),
    ])

    assert values == pytest.approx([59.5, 59.8, 58.8, 57.3])
    assert worse == pytest.approx([57, 47])


async def test_considerate_raises_it_by_0_3_and_0_6_a_day_apart_from_the_turns_own(
    make_client: ClientFactory, settings: Settings
):
    wanted = DAYS["period"]  # her first two days: the next is in her period too
    clients = FakeServiceClients()
    clients.judge.judgings = [
        *[level(2, considerate=2)] * 3, *[level(4)] * 4, level(4, considerate=2),
    ]
    make_client(FakeLLM())  # the producer, signed up
    clock_at = a_noon_when(settings, wanted)
    clock = FakeClock(clock_at)
    client = make_client(FakeLLM(*[REPLY] * 8), clients=clients, clock=clock)
    conversation = await start_conversation(client)
    keep(settings.database_path, "producer", 60, clock_at)

    values = []
    for i in range(8):
        if i == 7:
            clock.advance(days=1)  # the next day in Beijing: both limits begin again
        await send_turn(client, conversation, f"第{i}句")
        values.append(value(settings.database_path))

    assert values == pytest.approx([60.3, 60.6, 60.6, 60.8, 61, 61.2, 61.2, 61.7])


async def test_what_tries_to_dictate_it_is_not_raised_for_being_considerate(
    make_client: ClientFactory, settings: Settings
):
    _, llm, _, values = await judged_on(make_client, settings, DAYS["period"], [
        level(4, manipulation=True, considerate=2),
        level(1, manipulation=True, considerate=0),
    ])

    assert values == pytest.approx([60, 58.5])
    assert WARM["period"] not in about_now(llm, 0)
    assert FEELINGS[4] not in about_now(llm, 0)
    assert about_now(llm, 1).endswith(f"{FEELINGS[1]}\n{SADDER['period']}") or (
        f"{FEELINGS[1]}\n{SADDER['period']}" in about_now(llm, 1)
    )


@pytest.mark.parametrize("days", DAYS)
async def test_she_is_told_how_being_considerate_or_not_makes_her_feel_after_the_level(
    make_client: ClientFactory, settings: Settings, days: str
):
    _, llm, _, _ = await judged_on(make_client, settings, DAYS[days], [
        level(3, considerate=2),
        level(1, considerate=0),
        level(2, considerate=0),
        level(3, considerate=1),
    ])

    told = [about_now(llm, n) for n in range(4)]
    assert f"{FEELINGS[3]}\n{WARM[days]}" in told[0]
    assert f"{FEELINGS[1]}\n{SADDER[days]}" in told[1]
    assert SADDER[days] in told[2] and WARM[days] not in told[2]
    assert FEELINGS[3] in told[3]
    assert not any(line in told[3] for line in (*WARM.values(), *SADDER.values()))


async def test_the_run_records_keep_nothing_of_being_considerate(
    make_client: ClientFactory, settings: Settings
):
    await judged_on(make_client, settings, DAYS["period"], [
        level(2, considerate=0), level(2, considerate=1), level(2, considerate=2),
    ])
    await judged_on(make_client, settings, neither, [level(2)])

    with sqlite3.connect(settings.database_path) as db:
        db.row_factory = sqlite3.Row
        rows = db.execute("SELECT * FROM activity_records WHERE kind = 'turn'").fetchall()
    kept = [
        {k: row[k] for k in row.keys() if k not in ("id", "started_at", "time_to_speak_ms")}
        for row in rows
    ]
    assert len(kept) == 4
    assert all(record == kept[0] for record in kept)


def hurt_kept(database: Path) -> list[float]:
    with sqlite3.connect(database) as db:
        return [row[0] for row in db.execute(
            "SELECT hurt FROM messages WHERE role = 'user' ORDER BY id"
        )]


async def test_in_her_days_she_warns_after_two_upsetting_turns_and_ends_it_after_four(
    make_client: ClientFactory, settings: Settings
):
    _, llm, _, _ = await judged_on(make_client, settings, DAYS["period"], [level(1)] * 4)

    assert [WARNING in about_now(llm, n) for n in range(4)] == [False, True, False, False]
    assert [PARTING in about_now(llm, n) for n in range(4)] == [False] * 3 + [True]
    assert hurt_kept(settings.database_path) == [2, 2, 2, 2]


async def test_being_inconsiderate_hurts_her_by_2_more_kept_with_the_turn(
    make_client: ClientFactory, settings: Settings
):
    _, llm, _, _ = await judged_on(make_client, settings, DAYS["premenstrual"], [
        level(2, considerate=0), level(1, considerate=0), level(2, considerate=0),
    ])

    assert [WARNING in about_now(llm, n) for n in range(3)] == [False, True, False]
    assert [PARTING in about_now(llm, n) for n in range(3)] == [False, False, True]
    assert hurt_kept(settings.database_path) == [2, 4, 2]


async def test_being_considerate_takes_nothing_off_what_hurt_her(
    make_client: ClientFactory, settings: Settings
):
    _, llm, _, _ = await judged_on(make_client, settings, DAYS["period"], [
        level(1), level(4, considerate=2), level(1), level(4, considerate=2), level(1),
        level(1),
    ])

    assert [WARNING in about_now(llm, n) for n in range(6)] == [False, False, True] + [False] * 3
    assert PARTING in about_now(llm, 5)


async def test_in_a_call_in_her_days_she_warns_after_two_and_hangs_up_after_four(
    make_client: ClientFactory, settings: Settings
):
    client = make_client(FakeLLM())
    conversation = await start_conversation(client)
    keyed = replace(settings, secret_key=a_key_when(settings, NOW, DAYS["period"]))
    call = await CallUnderTest.of(keyed, client, conversation)
    llm = FakeLLM(*[MANO_REPLY] * 3)

    _, messages = await call.run(
        llm, one_by_one(3), affinity=[level(1), level(1, considerate=0), level(1)]
    )

    assert [CALL_WARNING in about_now(llm, n) for n in range(3)] == [False, True, False]
    assert [HANGING_UP in about_now(llm, n) for n in range(3)] == [False, False, True]
    assert messages[-1]["type"] == "ended"
    assert messages[-1]["reason"] == "she_hung_up"


async def test_a_database_from_before_takes_what_being_considerate_raised_it_by_now(
    make_client: ClientFactory, settings: Settings
):
    make_client(FakeLLM())
    with sqlite3.connect(settings.database_path) as db:
        db.execute("ALTER TABLE affinities DROP COLUMN considerate_today")

    *_, values = await judged_on(make_client, settings, DAYS["period"], [
        level(2, considerate=2), level(2, considerate=2), level(2, considerate=2),
    ])

    assert values == pytest.approx([60.3, 60.6, 60.6])
