"""What she knows of her schedule (GLOSSARY.md「日程」) reaching out: her jobs, in what she is
told of now (「此刻」), and that she may take her week's jobs to reach out about. What she is
told of her jobs, line by line, `test_her_now` has.

Driven through the backend's external API, the week's jobs kept beforehand in the database
(`publish`), saved through the API before the clock is moved on."""

from dataclasses import replace
from datetime import UTC, datetime, timedelta

from eidolon.config import Settings
from tests.conftest import ClientFactory
from tests.fakes import FakeClock, FakeLLM, FakeRandom, context_of
from tests.test_calendar import REPLY
from tests.test_reach_outs import backend_of, last_contact
from tests.test_schedule_saving import WEEK, placed, publish, save
from tests.test_schedule_weeks import MONDAY
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
