"""Her facts at the bar (GLOSSARY.md「光顾」): as she comes in, her character facts are looked
up by what the visit's topic says, the best few after reranking told her in this visit's
part of the prompt; looked up once for her and that topic while the server runs, and not at
all, nor remembered, when that cannot be done. The shared part tells her not to make up the
people and events of her past.

Driven through the backend's external API, embedding and reranking on fakes."""

import sqlite3
from pathlib import Path

import pytest

from eidolon.bar_visits import BAR_VISITS_FILE, load_bar_visits
from eidolon.config import Settings
from tests.conftest import MANO_SHEET, CharacterConfig, ClientFactory
from tests.fakes import FakeEmbedder, FakeLLM, FakeRandom, FakeReranker
from tests.test_bar_limits import come_in_and_leave
from tests.test_bar_visit import COMING_IN, MANO_TASTES, enter

FACTS = """\
# 人物关系
## 風野灯織
illumination STARS 的伙伴，真乃叫她「灯織ちゃん」。
## 八宮めぐる
illumination STARS 的伙伴，真乃叫她「めぐるちゃん」。
# 家人
真乃和父母以及鸽子ピーちゃん住在一起。
# 小时候
真乃小时候就喜欢偶像。
"""

DRAWS = [0] * 40
"""Every draw the first: the same reason and topic each visit, one drink, by name."""


@pytest.fixture
def characters(tmp_path: Path) -> CharacterConfig:
    return CharacterConfig(tmp_path / "characters").add(
        "mano", "櫻木真乃", MANO_SHEET, birthday="04-25", bar=MANO_TASTES, facts=FACTS
    )


def topic_note(characters: CharacterConfig) -> str:
    """What the topic every visit here is drawn says."""
    return load_bar_visits(characters.directory / BAR_VISITS_FILE).topics[0].note


async def test_she_comes_in_told_the_facts_of_hers_the_topic_finds_best_after_reranking(
    make_client: ClientFactory, characters: CharacterConfig, settings: Settings
):
    llm = FakeLLM(COMING_IN)
    embedder, reranker = FakeEmbedder(), FakeReranker(prefer="ピーちゃん")
    client = make_client(llm, random=FakeRandom(*DRAWS), embedder=embedder, reranker=reranker)

    await come_in_and_leave(client)

    note = topic_note(characters)
    assert embedder.queries == [note]
    assert [query for query, _ in reranker.calls] == [note]
    shared, about = (m.content for m in llm.prompts[0][:2])
    facts = about[about.index("# 角色资料"):]
    assert facts.index("ピーちゃん") < facts.index("illumination STARS")  # best first
    assert sum(f in facts for f in ("灯織ちゃん", "めぐるちゃん", "ピーちゃん", "喜欢偶像")) == 3
    assert "# 角色资料" not in shared
    with sqlite3.connect(settings.database_path) as db:  # under the visit's record, once over
        assert db.execute(
            "SELECT c.service FROM service_calls c JOIN activity_records r"
            " ON c.record_id = r.id WHERE r.kind = 'visit' ORDER BY c.id"
        ).fetchall() == [("embedding",), ("embedding",), ("rerank",), ("chat_llm",)]


async def test_her_facts_for_a_topic_are_looked_up_once(make_client: ClientFactory):
    llm = FakeLLM(COMING_IN, COMING_IN)
    embedder, reranker = FakeEmbedder(), FakeReranker(prefer="ピーちゃん")
    client = make_client(llm, random=FakeRandom(*DRAWS), embedder=embedder, reranker=reranker)

    await enter(client)
    await enter(client)  # again, the same topic drawn

    assert len(embedder.queries) == 1 and len(reranker.calls) == 1
    assert "ピーちゃん" in llm.prompts[1][1].content


async def test_she_comes_in_without_facts_when_they_cannot_be_looked_up_and_they_are_next_time(
    make_client: ClientFactory,
):
    llm = FakeLLM(COMING_IN, COMING_IN)
    embedder, reranker = FakeEmbedder(), FakeReranker(prefer="ピーちゃん")
    embedder.down = True
    client = make_client(llm, random=FakeRandom(*DRAWS), embedder=embedder, reranker=reranker)

    first = await enter(client)
    embedder.down = False
    await enter(client)

    assert first[-1]["type"] == "waiting"
    assert "# 角色资料" not in llm.prompts[0][1].content
    assert "ピーちゃん" in llm.prompts[1][1].content  # the failure was not remembered


async def test_she_comes_in_without_facts_when_reranking_fails(make_client: ClientFactory):
    llm = FakeLLM(COMING_IN)
    reranker = FakeReranker()
    reranker.down = True
    client = make_client(
        llm, random=FakeRandom(*DRAWS), embedder=FakeEmbedder(), reranker=reranker
    )

    came_in = await enter(client)

    assert came_in[-1]["type"] == "waiting"
    assert "# 角色资料" not in llm.prompts[0][1].content


async def test_she_comes_in_without_facts_without_embedding(make_client: ClientFactory):
    llm = FakeLLM(COMING_IN)
    client = make_client(llm, random=FakeRandom(*DRAWS))

    came_in = await enter(client)

    assert came_in[-1]["type"] == "waiting"
    assert "# 角色资料" not in llm.prompts[0][1].content


async def test_she_is_told_not_to_make_up_the_people_and_events_of_her_past(
    make_client: ClientFactory,
):
    llm = FakeLLM(COMING_IN)
    client = make_client(llm, random=FakeRandom(*DRAWS))

    await enter(client)

    shared = llm.prompts[0][0].content
    assert "不编具体的名字和事件" in shared
