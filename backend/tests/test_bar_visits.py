"""The bar's reasons for coming and topics (GLOSSARY.md「来意」「话题」) come from configuration
beside the characters', as the job list does: some 30 reasons and 12 topics for every
character alike, checked as the backend starts."""

from collections import Counter

import pytest

from eidolon.bar_visits import BAR_VISITS_FILE, check_bar_visits, load_bar_visits
from eidolon.characters import load_characters

from tests.conftest import REPO_BAR_VISITS, CharacterConfig, ClientFactory
from tests.fakes import FakeLLM


def test_the_repositorys_lists_are_right_for_its_characters():
    characters = load_characters(REPO_BAR_VISITS.parent / "characters.toml")
    visits = load_bar_visits(REPO_BAR_VISITS)

    check_bar_visits(characters, visits)
    moods = Counter(r.mood for r in visits.reasons)
    assert 26 <= len(visits.reasons) <= 34
    assert 10 <= len(visits.topics) <= 14
    assert set(moods) == {"happy", "annoyed", "tired", "down", "calm"}
    assert max(moods.values()) <= len(visits.reasons) * 0.3
    notes = [e.note for e in (*visits.reasons, *visits.topics)]
    assert not any("演出" in n for n in notes)
    for c in characters.values():
        assert not any(c.name in n for n in notes), c.id
    assert 0 < sum(bool(e.not_for) for e in (*visits.reasons, *visits.topics)) <= 5  # only a few


def reason(id: str, mood: str = "calm", not_for: str | None = None) -> str:
    entry = f'[[reasons]]\nid = "{id}"\nnote = "说明"\nmood = "{mood}"\n'
    return entry + (f"not_for = {not_for}\n" if not_for is not None else "")


def topic(id: str, not_for: str | None = None) -> str:
    entry = f'[[topics]]\nid = "{id}"\nnote = "说明"\n'
    return entry + (f"not_for = {not_for}\n" if not_for is not None else "")


REASONS = "".join(reason(f"reason-{n}") for n in range(4))
TOPICS = "".join(topic(f"topic-{n}") for n in range(4))


def test_lists_of_its_own_with_just_enough_for_each_character_are_loaded(
    make_client: ClientFactory, characters: CharacterConfig
):
    characters.write(BAR_VISITS_FILE, REASONS + reason("late", not_for='["mano"]') + TOPICS)

    make_client(FakeLLM())


@pytest.mark.parametrize(
    ("visits", "named"),
    [
        ('[[reasons]]\nid = "late"\nnote = "说明"\n' + REASONS + TOPICS, "late.*mood"),
        (reason("late", mood="sleepy") + REASONS + TOPICS, "sleepy"),
        (REASONS + reason("reason-0") + TOPICS, "reason-0"),
        (REASONS + reason("Late") + TOPICS, "Late"),
        (REASONS + TOPICS + topic("topic-0").replace("说明", "说\\n明"), "topic-0"),
        (REASONS + reason("late", not_for='["hiori"]') + TOPICS, "hiori"),
        (REASONS + TOPICS + topic("bar", not_for='"mano"'), "bar.*not_for"),
        (REASONS.replace("\n[", '\nnot_for = ["mano"]\n[', 1) + TOPICS, "mano.*来意"),
        (REASONS, "话题"),
        ("[[reasons]\n", BAR_VISITS_FILE),
    ],
    ids=[
        "missing-mood", "mood-misspelt", "id-twice", "id-invalid", "note-two-lines",
        "not-for-no-one", "not-for-not-a-list", "too-few", "no-topics", "not-toml",
    ],
)
def test_broken_lists_keep_the_backend_from_starting_naming_what_is_wrong(
    make_client: ClientFactory, characters: CharacterConfig, visits: str, named: str
):
    characters.write(BAR_VISITS_FILE, visits)

    with pytest.raises(RuntimeError, match=named):
        make_client(FakeLLM())


def test_missing_lists_keep_the_backend_from_starting(
    make_client: ClientFactory, characters: CharacterConfig
):
    (characters.directory / BAR_VISITS_FILE).unlink()

    with pytest.raises(RuntimeError, match=BAR_VISITS_FILE):
        make_client(FakeLLM())
