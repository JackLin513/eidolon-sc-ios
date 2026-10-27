"""What she knows of her schedule (GLOSSARY.md「日程」): in what she is told of now (「此刻」), her
jobs the producer saved of their week and the next, each by its day as from today where the
producer is, its slots, and whether done; the one under way apart, none before 6 in the
morning; and how to go by them. Nothing of the others' jobs, nor of last week's; nothing
without any saved, or while schedules are off. Typing, in a call or reaching out alike, and
reaching out she may take her week's jobs to reach out about.

Driven through the backend's external API, the week's jobs kept beforehand in the database
(`publish`), saved through the API before the clock is moved on."""

from dataclasses import replace
from datetime import UTC, datetime, timedelta

from eidolon.config import Settings
from tests.conftest import ClientFactory
from tests.fakes import FakeClock, FakeLLM, FakeRandom, context_of
from tests.test_calendar import REPLY, told_now
from tests.test_call_turns import MANO_REPLY, CallUnderTest, spoken
from tests.test_reach_outs import backend_of, last_contact
from tests.test_schedule_saving import WEEK, placed, publish, save
from tests.test_schedule_weeks import MONDAY, live_in
from tests.test_text_turn import send_turn, start_conversation

HER_JOBS = "制作人给你排了这些工作（日程定了就不会再变；制作人在对话里说取消或改期，你还是按日程上的来）："
ABOUT_THEM = (
    "这些是你的制作人排的，你可以按你们的关系抱怨或期待；私人的安排也算他给你留出的时间。"
    "做完的工作你可以自己说过程和感受（顺不顺、累不累、小插曲），"
    "不要编后续的安排和结果（补拍、播出日期、因此接到的新工作、和别人的合作）。"
    "只在相关的时候提起，不在开头就说；同一项在这段对话里说过就不再主动提。别的偶像的安排你不清楚。"
)
UNDER_WAY = "说话可以带着这个状态（抽空回、在休息），不用每句都提，说过就不再反复说。"
EARLY_MONDAY = MONDAY + timedelta(hours=1)
"""Monday 01:00 in Shanghai: the whole week still to come."""


async def test_she_is_told_her_jobs_by_day_from_today_the_one_under_way_apart(
    make_client: ClientFactory, settings: Settings
):
    llm = FakeLLM(REPLY)
    clock = FakeClock(EARLY_MONDAY)
    client = make_client(llm, clock=clock)
    publish(
        settings.database_path, WEEK,
        ("声乐课", 1, None), ("拍摄广告", 2, None), ("开会", 1, None), ("外景", 3, None),
        ("访谈", 1, None), ("晚饭", 1, ["evening"]),
    )
    publish(settings.database_path, WEEK, ("组合排练", 1, None), character="kogane")
    res = await save(
        client, WEEK,
        placed("声乐课", 0, 0), placed("拍摄广告", 1, 0), placed("开会", 2, 1),
        placed("外景", 3, 0), placed("访谈", 4, 1), placed("晚饭", 6, 2),
        placed("组合排练", 4, 0),
    )
    assert len(res.json()["saved"]) == 7
    clock.advance(days=2, hours=13)  # Wednesday 14:00

    told = await told_now(client, llm)

    now, *_ = told.split("\n\n")
    assert now.startswith("# 此刻\n")
    assert now.endswith("\n".join([
        HER_JOBS,
        "周一（前天）上午：声乐课——说明（做完了）",
        "周二（昨天）上午到下午：拍摄广告——说明（做完了）",
        "周四（明天）一整天：外景——说明",
        "周五（后天）下午：访谈——说明",
        "周日晚上：晚饭——说明",
        f"现在（下午 12–18 点）你正在开会：说明。{UNDER_WAY}",
        ABOUT_THEM,
    ]))
    assert "组合排练" not in told


async def test_west_of_beijing_she_knows_next_week_saved_already_on_their_sunday(
    make_client: ClientFactory, settings: Settings
):
    """Beijing's Monday 01:00 is Los Angeles' Sunday 10:00: this week there is the one
    before Beijing's."""
    llm = FakeLLM(REPLY)
    clock = FakeClock(EARLY_MONDAY)
    client = make_client(llm, clock=clock)
    await live_in(client, "America/Los_Angeles")
    publish(settings.database_path, WEEK, ("声乐课", 1, None), ("晚饭", 1, None))
    await save(client, WEEK, placed("声乐课", 4, 0), placed("晚饭", 6, 2))
    clock.advance(days=7)
    publish(settings.database_path, "2026-09-28", ("录音", 1, None), ("访谈", 1, None))
    await save(client, "2026-09-28", placed("录音", 0, 2), placed("访谈", 3, 1))

    told = await told_now(client, llm)

    assert "\n".join([
        HER_JOBS,
        "周五（前天）上午：声乐课——说明（做完了）",
        "周日（今天）晚上：晚饭——说明",
        "下周一（明天）晚上：录音——说明",
        "下周四下午：访谈——说明",
        ABOUT_THEM,
    ]) in told


async def test_before_6_in_the_morning_no_job_is_under_way(
    make_client: ClientFactory, settings: Settings
):
    llm = FakeLLM(REPLY)
    clock = FakeClock(EARLY_MONDAY)
    client = make_client(llm, clock=clock)
    publish(settings.database_path, WEEK, ("拍摄广告", 1, None), ("声乐课", 1, None))
    await save(client, WEEK, placed("拍摄广告", 1, 2), placed("声乐课", 2, 0))
    clock.advance(days=2, hours=2)  # Wednesday 03:00

    told = await told_now(client, llm)

    assert "\n".join([
        HER_JOBS,
        "周二（昨天）晚上：拍摄广告——说明（做完了）",
        "周三（今天）上午：声乐课——说明",
        ABOUT_THEM,
    ]) in told
    assert "现在（" not in told


async def test_with_only_the_one_under_way_she_is_told_it_stands_all_the_same(
    make_client: ClientFactory, settings: Settings
):
    llm = FakeLLM(REPLY)
    clock = FakeClock(EARLY_MONDAY)
    client = make_client(llm, clock=clock)
    publish(settings.database_path, WEEK, ("拍摄广告", 2, None))
    await save(client, WEEK, placed("拍摄广告", 0, 1))
    clock.advance(hours=18)  # Monday 19:00, its second slot

    told = await told_now(client, llm)

    assert "\n".join([
        HER_JOBS, f"现在（晚上 18–24 点）你正在拍摄广告：说明。{UNDER_WAY}", ABOUT_THEM,
    ]) in told


async def test_with_none_of_hers_saved_she_is_told_nothing_of_a_schedule(
    make_client: ClientFactory, settings: Settings
):
    llm = FakeLLM(REPLY)
    clock = FakeClock(EARLY_MONDAY)
    client = make_client(llm, clock=clock)
    publish(settings.database_path, WEEK, ("组合排练", 1, None), character="kogane")
    await save(client, WEEK, placed("组合排练", 0, 1))
    clock.advance(hours=12)  # Monday 13:00, Kogane's job under way

    told = await told_now(client, llm)

    assert "工作" not in told and "组合排练" not in told and "现在（" not in told


async def test_last_weeks_jobs_are_not_told(make_client: ClientFactory, settings: Settings):
    llm = FakeLLM(REPLY)
    clock = FakeClock(EARLY_MONDAY)
    client = make_client(llm, clock=clock)
    publish(settings.database_path, WEEK, ("晚饭", 1, None))
    await save(client, WEEK, placed("晚饭", 6, 2))
    clock.advance(days=7)

    told = await told_now(client, llm)

    assert HER_JOBS not in told and "晚饭" not in told


async def test_off_she_is_told_nothing_of_what_was_saved(
    make_client: ClientFactory, settings: Settings
):
    clock = FakeClock(EARLY_MONDAY)
    on = make_client(FakeLLM(), clock=clock)
    publish(settings.database_path, WEEK, ("声乐课", 1, None))
    await save(on, WEEK, placed("声乐课", 0, 2))
    clock.advance(hours=12)
    llm = FakeLLM(REPLY)
    off = make_client(llm, clock=clock, settings=replace(settings, schedule=False))

    told = await told_now(off, llm)

    assert HER_JOBS not in told and "声乐课" not in told


async def test_in_a_call_she_is_told_her_jobs_too(make_client: ClientFactory, settings: Settings):
    """The call is on Friday 20:30 in Shanghai (`test_call_turns.NOW`)."""
    client = make_client(FakeLLM(), clock=FakeClock(EARLY_MONDAY))
    publish(settings.database_path, WEEK, ("声乐课", 1, None), ("晚饭", 1, None))
    await save(client, WEEK, placed("声乐课", 4, 0), placed("晚饭", 4, 2))
    conversation = await start_conversation(client)
    call = await CallUnderTest.of(settings, client, conversation)
    call_llm = FakeLLM(MANO_REPLY)

    await call.run(call_llm, [spoken("早上好")])

    told = context_of(call_llm.prompts[-1])
    assert f"{HER_JOBS}\n周五（今天）上午：声乐课——说明（做完了）\n" in told
    assert f"现在（晚上 18–24 点）你正在晚饭：说明。{UNDER_WAY}\n{ABOUT_THEM}" in told


async def test_reaching_out_she_is_told_her_jobs_and_may_reach_out_about_them(
    make_client: ClientFactory, settings: Settings
):
    """Saved on Wednesday 17:00 in Shanghai, where her profile has the producer; she reaches
    out at 20:00, dinner under way."""
    llm = FakeLLM(REPLY, REPLY)
    clock = FakeClock(datetime(2026, 9, 23, 9, tzinfo=UTC))
    client = make_client(
        llm, clock=clock, random=FakeRandom(0), settings=replace(settings, reach_outs=True)
    )
    publish(settings.database_path, WEEK, ("晚饭", 1, None), ("外景", 3, None))
    await save(client, WEEK, placed("晚饭", 2, 2), placed("外景", 3, 0))
    conversation = await start_conversation(client)
    await send_turn(client, conversation, "我去练习了")
    last_contact(settings.database_path, conversation, datetime(2026, 9, 22, 13, tzinfo=UTC))
    clock.advance(hours=3)

    await backend_of(client).reach_outs.run_due()

    told = context_of(llm.prompts[-1])
    assert "你们这会儿没在说话" in told
    assert f"{HER_JOBS}\n周四（明天）一整天：外景——说明\n现在（晚上 18–24 点）你正在晚饭" in told
    assert (
        "- 由头你自己挑：先接着你们最近聊过的事，或者他最近的近况；其次是你这周的工作（如果有）；"
        "再其次才是现在的时间、他的生日。"
    ) in told
    assert "- 别人的生日、节假日、往年今天的演出不拿来当由头；组合伙伴的生日可以顺口提一句。" in told
    assert (
        "- 说到你自己那边：日程里有的就说日程里的；没有的话只说练习、拍摄、事务所的工作这类平常的事，"
        "或者世界设定里快到的 live 和新歌，已经过去的只当回忆说，先对照现在的年份；"
        "不要编具体的剧情，也不要说别的偶像做了什么。"
    ) in told
