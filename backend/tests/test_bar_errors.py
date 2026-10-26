"""A visit to the bar going wrong (GLOSSARY.md「光顾」): a call that fails, times out or writes
no line is made again at once, the browser told to clear what it sent (`retrying`); failing
again, the visit stops before it (`failed`) until the user tries again, on the order drawn
for it, or leaves. Her farewell, failing twice, is said in fixed lines instead, and the visit
done and rewarded all the same. A visit untouched for `bar.IDLE` is gone.

Driven through the backend's external API, with a clock the tests control."""

import asyncio
from collections.abc import Awaitable
from dataclasses import replace
from pathlib import Path

import httpx
import pytest

from eidolon.bar import FAILED
from eidolon.bar_lines import bar_lines_path, load_bar_lines
from eidolon.config import Settings
from eidolon.llm import LLMError
from tests.conftest import CharacterConfig, ClientFactory
from tests.fakes import FAKE_JUDGE, HANG, FakeClock, FakeLLM, FakeRandom
from tests.test_bar_activity import visit_records
from tests.test_bar_draws import visit_rows
from tests.test_bar_limits import ENTERING, uses
from tests.test_bar_visit import (
    COMING_IN,
    PARTING,
    VISITS,
    enter,
    events,
    her,
    kinds,
    mano_alone,
    mixed,
    producer,
    refused,
    serve,
    streamed,
)
from tests.test_service_status import backend_of

DRAWS = [0] * 40
"""What the random source draws for every visit here: one drink, ordered by name."""

TIMED_OUT = LLMError("请求模型失败: ReadTimeout('')")


@pytest.fixture
def characters(tmp_path: Path) -> CharacterConfig:
    return mano_alone(tmp_path / "characters")


async def test_a_call_that_times_out_is_made_again_at_once(
    make_client: ClientFactory, settings: Settings
):
    llm = FakeLLM(TIMED_OUT, COMING_IN)
    client = make_client(llm, random=FakeRandom(*DRAWS))

    came = await enter(client)

    assert kinds(came) == [
        "visit", "retrying", "line:her", "line:producer", "line:her", "memo", "waiting",
    ]
    assert len(llm.prompts) == 2 and llm.prompts[0] == llm.prompts[1]


def retry(client: httpx.AsyncClient, visit_id: str) -> Awaitable[httpx.Response]:
    return client.post(f"{VISITS}/{visit_id}/retry")


async def test_a_call_failing_twice_stops_till_it_is_tried_again_on_the_order_drawn(
    make_client: ClientFactory, settings: Settings
):
    llm = FakeLLM(TIMED_OUT, LLMError("模型返回 503: overloaded"), COMING_IN, PARTING)
    # As she comes in, and the producer's line as she is served: no order drawn again.
    client = make_client(llm, random=FakeRandom(*ENTERING, 0))

    came = await enter(client)
    visit_id = came[0]["visit_id"]
    too_soon = await serve(client, visit_id, mixed("sugar-rush"))
    tried_again = events(await retry(client, visit_id))
    again_while_waiting = await retry(client, visit_id)
    served = events(await serve(client, visit_id, mixed("sugar-rush")))

    assert came == [
        came[0], {"type": "retrying"}, {"type": "failed", "message": FAILED},
    ]
    refused(too_soon, 409, "not_waiting")
    assert kinds(tried_again) == ["line:her", "line:producer", "line:her", "memo", "waiting"]
    assert tried_again[3] == {"type": "memo", "text": "她要 Sugar Rush。"}
    assert llm.prompts[2] == llm.prompts[0]
    refused(again_while_waiting, 409, "not_failed")
    assert kinds(served)[-1] == "done"
    assert llm.prompts[3][-2].content == "\n".join(COMING_IN)  # the tries that failed are not
    assert uses(settings.database_path) == [("visit", 0)]  # tried again, counted once


async def test_a_call_writing_no_line_it_needs_is_made_again_and_stops_likewise(
    make_client: ClientFactory,
):
    llm = FakeLLM(
        ["她走进店里，点了一杯。"], [producer("欢迎。")],  # no line at all; her order none
        [producer("欢迎光临。")], COMING_IN,
    )
    client = make_client(llm, random=FakeRandom(*DRAWS))

    came = await enter(client)
    tried_again = events(await retry(client, came[0]["visit_id"]))

    assert kinds(came) == ["visit", "retrying", "line:producer", "failed"]
    assert kinds(tried_again) == [
        "line:producer", "retrying", "line:her", "line:producer", "line:her", "memo", "waiting",
    ]


async def test_her_farewell_failing_twice_is_said_in_fixed_lines_and_the_visit_done_rewarded(
    make_client: ClientFactory, settings: Settings
):
    settings = replace(settings, judge=FAKE_JUDGE, affinity_and_gifts=True)
    llm = FakeLLM(
        COMING_IN, TIMED_OUT, [her("ごちそう", "多谢"), LLMError("模型在流式输出中报错: overloaded")]
    )
    # As she comes in; the producer's line as she is served, her fixed reaction, her farewell.
    client = make_client(llm, settings=settings, random=FakeRandom(*ENTERING, 0, 1, 2))
    lines = load_bar_lines(bar_lines_path(settings.characters_path))

    visit_id = (await enter(client))[0]["visit_id"]
    served = events(await serve(client, visit_id, mixed("sugar-rush")))
    afterwards = await serve(client, visit_id, mixed("sugar-rush"))

    reaction, farewell = lines.reactions["right"][1], lines.farewells["sober"][2]
    assert served == [
        served[0], {"type": "retrying"}, served[2], {"type": "retrying"},
        {
            "type": "line", "speaker": "her", "emotion": reaction.emotion, "ja": reaction.ja,
            "zh": reaction.zh,
        },
        {
            "type": "line", "speaker": "her", "emotion": farewell.emotion, "ja": farewell.ja,
            "zh": farewell.zh,
        },
        {"type": "done", "rewarded": {"draws": 1, "affinity_up": True}},
    ]
    assert served[2]["zh"] == "多谢"
    refused(afterwards, 410, "visit_gone")


async def test_a_visit_untouched_for_half_an_hour_is_gone_as_it_is_next_touched(
    make_client: ClientFactory, settings: Settings
):
    clock = FakeClock()
    client = make_client(FakeLLM(COMING_IN), clock=clock, random=FakeRandom(*DRAWS))

    visit_id = (await enter(client))[0]["visit_id"]
    clock.advance(minutes=29)
    not_yet = await retry(client, visit_id)  # refused: touches nothing
    clock.advance(minutes=1)
    gone = await serve(client, visit_id, mixed("sugar-rush"))

    refused(not_yet, 409, "not_failed")
    refused(gone, 410, "visit_gone")
    assert [r[0] for r in visit_records(settings.database_path)] == ["left"]
    assert uses(settings.database_path) == [("visit", 0)]


async def test_a_visit_untouched_for_half_an_hour_is_swept_away_as_it_stopped(
    make_client: ClientFactory, settings: Settings
):
    clock = FakeClock()
    llm = FakeLLM(TIMED_OUT, TIMED_OUT, COMING_IN, TIMED_OUT, TIMED_OUT)
    # The first visit as she comes in; the second with two drinks.
    client = make_client(llm, clock=clock, random=FakeRandom(*ENTERING, 0, 0, 20, *DRAWS))
    bar = backend_of(client).bar

    nothing_written = (await enter(client))[0]["visit_id"]
    clock.advance(minutes=29, seconds=59)
    await bar.sweep()
    kept = visit_records(settings.database_path)
    clock.advance(seconds=1)
    await bar.sweep()
    swept = await retry(client, nothing_written)
    came = await enter(client)
    stopped_later = events(await serve(client, came[0]["visit_id"], mixed("sugar-rush")))
    clock.advance(minutes=30)
    await bar.sweep()

    assert kept == []
    refused(swept, 410, "visit_gone")
    assert kinds(stopped_later)[-1] == "failed"
    assert [r[0] for r in visit_records(settings.database_path)] == ["failed", "failed"]
    assert uses(settings.database_path) == [("visit", 0)]  # the first given back


async def test_her_farewell_left_part_way_is_not_done(
    make_client: ClientFactory, settings: Settings
):
    llm = FakeLLM(COMING_IN, [PARTING[0], HANG])
    client = make_client(llm, random=FakeRandom(*DRAWS))
    gone = asyncio.Event()

    visit_id = (await enter(client))[0]["visit_id"]
    came, serving = await streamed(
        client, f"{VISITS}/{visit_id}/serves", mixed("sugar-rush"), until="line", gone=gone
    )
    gone.set()
    await asyncio.wait_for(serving, timeout=5)
    async with asyncio.timeout(5):  # settled as the page is gone, not waited for
        while not visit_records(settings.database_path):
            await asyncio.sleep(0.05)
    afterwards = await serve(client, visit_id, mixed("sugar-rush"))

    assert "done" not in kinds(came)
    assert [r[0] for r in visit_records(settings.database_path)] == ["left"]
    assert visit_rows(settings.database_path) == []
    refused(afterwards, 410, "visit_gone")


async def test_trying_again_as_the_call_that_failed_is_still_closing_goes_on(
    make_client: ClientFactory,
):
    written = asyncio.Event()
    llm = FakeLLM(
        TIMED_OUT, TIMED_OUT, [*COMING_IN[:2], her("ふふ。"), written, COMING_IN[2]]
    )  # sent up to her latest line, which may be her order, as it is written
    client = make_client(llm, random=FakeRandom(*DRAWS))

    closing = asyncio.Event()

    came, entering = await streamed(client, VISITS, {}, until="failed", held=closing)
    tried, trying = await streamed(
        client, f"{VISITS}/{came[0]['visit_id']}/retry", {}, until="line"
    )
    closing.set()
    await asyncio.wait_for(entering, timeout=5)  # the call that failed closed by now
    written.set()
    await asyncio.wait_for(trying, timeout=5)

    assert kinds(tried) == [
        "line:her", "line:producer", "line:her", "line:her", "memo", "waiting",
    ]
