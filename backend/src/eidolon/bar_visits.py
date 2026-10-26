"""The bar's reasons for coming and topics (GLOSSARY.md「来意」「话题」), loaded from the
configuration beside the characters'.

It is configuration, not data, as the job list is: the maintainer keeps it in the
repository, and neither `.env`, the admin console nor the background model changes it. Both
lists are for every character alike, what a reason or a topic comes to being hers to fill in
from her sheet and facts. Each reason has its identifier, a line for the model saying what
it is, and her mood as she comes in with it; each topic its identifier and its line. Either
may leave out a few characters it does not suit (`not_for`), as one about her unit's other
idols does はづき, who has none.

A visit draws one of each, not one of her `RECENT_VISITS` latest, so every character has to
have more than that many of each to draw from (`check_bar_visits`).

Anything wrong in it keeps the backend from starting (`BarVisitsError`).
"""

import re
import tomllib
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, get_args

from eidolon.characters import Character

Mood = Literal["happy", "annoyed", "tired", "down", "calm"]
"""开心、烦躁、疲惫、低落、平静: how she is as she comes in."""

BAR_VISITS_FILE = "bar_visits.toml"
"""The file's name, in the directory of the character configuration."""

RECENT_VISITS = 3
"""How many of her latest visits with a user a visit's reason and topic are not drawn from
again."""

_VALID_ID = re.compile(r"[a-z0-9_-]+")


class BarVisitsError(RuntimeError):
    """The reasons and topics are missing or broken."""


@dataclass(frozen=True)
class Reason:
    id: str
    note: str
    """One line saying what it is, for the model."""
    mood: Mood
    not_for: frozenset[str] = frozenset()
    """The characters it is not for."""


@dataclass(frozen=True)
class Topic:
    id: str
    note: str
    """One line saying what it is, for the model."""
    not_for: frozenset[str] = frozenset()
    """The characters it is not for."""


@dataclass(frozen=True)
class BarVisits:
    reasons: list[Reason]
    """In file order."""
    topics: list[Topic]
    """In file order."""


def bar_visits_path(characters_path: Path) -> Path:
    """Where the reasons and topics are: beside the character configuration."""
    return characters_path.parent / BAR_VISITS_FILE


def load_bar_visits(path: Path) -> BarVisits:
    """The reasons and topics at `path`. Raises BarVisitsError if they are missing or
    broken."""
    try:
        config = tomllib.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise BarVisitsError(f"找不到来意和话题清单 {path}") from None
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as e:
        raise BarVisitsError(f"来意和话题清单 {path} 格式有误：{e}") from None
    reasons = [_parse_reason(e) for e in _entries(config, "reasons", "来意", path)]
    topics = [_parse_topic(e) for e in _entries(config, "topics", "话题", path)]
    for what, ids in (("来意", [r.id for r in reasons]), ("话题", [t.id for t in topics])):
        if twice := sorted({id for id in ids if ids.count(id) > 1}):
            raise BarVisitsError(f"{what}标识 {'、'.join(twice)} 重复")
    return BarVisits(reasons, topics)


def check_bar_visits(characters: Mapping[str, Character], visits: BarVisits) -> None:
    """Raises BarVisitsError unless every character a reason or topic is not for is one of
    `characters`, and every character has more than `RECENT_VISITS` reasons and as many
    topics for her."""
    for what, entries in (("来意", visits.reasons), ("话题", visits.topics)):
        for entry in entries:
            if unknown := sorted(entry.not_for - characters.keys()):
                raise BarVisitsError(
                    f"{what} {entry.id} 的 not_for 里的 {'、'.join(unknown)} 不是角色"
                )
        for id in characters:
            if (n := sum(id not in e.not_for for e in entries)) <= RECENT_VISITS:
                raise BarVisitsError(
                    f"角色 {id} 能用的{what}只有 {n} 条，至少要 {RECENT_VISITS + 1} 条"
                )


def _entries(config: dict, table: str, what: str, path: Path) -> Sequence[object]:
    entries = config.get(table, [])
    if not isinstance(entries, list):
        raise BarVisitsError(f"来意和话题清单 {path} 里的 {table} 应当是 [[{table}]] 段")
    if not entries:
        raise BarVisitsError(f"来意和话题清单 {path} 里没有{what}（[[{table}]] 段）")
    return entries


def _parse_reason(entry: object) -> Reason:
    fields, id, note, not_for = _parse_entry(entry, "reasons", "来意", ("id", "note", "mood"))
    if (mood := fields["mood"]) not in get_args(Mood):
        raise BarVisitsError(f"来意 {id} 的基调 {mood} 不在 {'、'.join(get_args(Mood))} 之中")
    return Reason(id, note, mood, not_for)


def _parse_topic(entry: object) -> Topic:
    _, id, note, not_for = _parse_entry(entry, "topics", "话题", ("id", "note"))
    return Topic(id, note, not_for)


def _parse_entry(
    entry: object, table: str, what: str, required: tuple[str, ...]
) -> tuple[dict, str, str, frozenset[str]]:
    """A reason's or topic's `[[table]]` section, and its identifier, note and the
    characters it is not for."""
    if not isinstance(entry, dict):
        raise BarVisitsError(f"来意和话题清单里的 {entry!r} 应当是一个 [[{table}]] 段")
    label = entry.get("id", "（没有标识）")
    if missing := [f for f in required if f not in entry]:
        raise BarVisitsError(f"{what} {label} 缺少 {'、'.join(missing)}")
    id, note = entry["id"], entry["note"]
    if not isinstance(id, str) or not _VALID_ID.fullmatch(id):
        raise BarVisitsError(f"{what}标识 {id} 只能用小写字母、数字、- 和 _")
    if not isinstance(note, str) or not note.strip() or any(c in note for c in "\r\n"):
        raise BarVisitsError(f"{what} {id} 的 note 应当是一行文字")
    not_for = entry.get("not_for", [])
    if not isinstance(not_for, list) or any(not isinstance(c, str) for c in not_for):
        raise BarVisitsError(f"{what} {id} 的 not_for 应当是角色标识的列表")
    return entry, id, note, frozenset(not_for)
