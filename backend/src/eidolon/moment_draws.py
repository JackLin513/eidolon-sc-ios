"""The draws behind moments (GLOSSARY.md「朋友圈」): given what they go by and a random
source, what comes of them, reading nothing and writing nothing, so that the background loop
and the eval alike take them as they are.

The day's plan (`plan_day`): each character eligible is drawn for once, by her tier
(`CHANCES`); on her birthday, in Tokyo, she posts whatever is drawn. Over as many as the user
may have a day, those whose birthday it is are kept first, the rest drawn among. Each kept is
then given a time in Tokyo, after the moment planned at: a part of the day drawn by its weight
(`PARTS`), then a time in it, at least `APART` from the user's others; one there is no time
left for posts nothing that day.

Her everyday moment's seeds (`draw_seeds`): `SEEDS` entries of her facts, but for those of
the people she knows (`RELATIONS`), each as likely.

Every draw asks the random source for a number below `PLACES`, so that one giving the same
number each time draws alike wherever it is asked."""

from collections.abc import Sequence
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta

from eidolon.affinity import Tier
from eidolon.characters import Fact
from eidolon.randomness import Random
from eidolon.today import TOKYO

CHANCES: dict[Tier, float] = {"intimate": 0.8, "close": 0.5, "trust": 0.25}
"""How likely she is to post on a day, by her tier; none in the tiers not here."""

PARTS: tuple[tuple[time, time, int], ...] = (
    (time(7), time(9), 2),
    (time(12), time(13), 2),
    (time(18), time(0), 4),
    (time(0), time(2), 1),
)
"""The parts of the day in Tokyo her everyday moment is posted in, from the first to the
second (midnight ending the day), and how much each weighs: the morning, lunch, after work,
late at night."""

APART = timedelta(hours=1)
"""How far apart one user's moments of a day are at least."""

PLACES = 1000
"""How many numbers each draw asks the random source for."""

SEEDS = 3
"""How many entries of her facts her everyday moment is seeded with."""

RELATIONS = "人物关系"
"""The heading of the section of her facts on the people she knows, drawn from for no seed."""


@dataclass(frozen=True)
class Eligible:
    """A character the user may have a moment of today: her tier (trust where affinity is
    off), and whether it is her birthday in Tokyo."""

    character_id: str
    tier: Tier
    birthday: bool


@dataclass(frozen=True)
class Planned:
    """A moment planned: whose, when it is due, and whether on her birthday."""

    character_id: str
    due_at: datetime
    birthday: bool


def plan_day(
    eligible: Sequence[Eligible], day: date, after: datetime, per_day: int, random: Random
) -> list[Planned]:
    """The moments of the user's `day` in Tokyo, planned at `after`, as many as `per_day` at
    most, the earliest first: of the `eligible`, in their order, each drawn for, those kept,
    and a time drawn for each."""
    posting = [e for e in eligible if e.birthday or _draw(random) < CHANCES[e.tier]]
    kept = [e for e in posting if e.birthday][:per_day]
    rest = [e for e in posting if not e.birthday]
    if len(kept) + len(rest) <= per_day:
        kept += rest
    else:
        while len(kept) < per_day:
            kept.append(rest.pop(_index(random, len(rest))))
    planned: list[Planned] = []
    for each in kept:
        at = _time(day, after, [p.due_at for p in planned], random)
        if at is not None:
            planned.append(Planned(each.character_id, at, each.birthday))
    return sorted(planned, key=lambda p: p.due_at)


def draw_seeds(facts: Sequence[Fact], random: Random) -> list[Fact]:
    """`SEEDS` of `facts`, or all if fewer, but for those under `RELATIONS`, in the order
    drawn."""
    left = [f for f in facts if f.title is None or f.title.split(" / ")[0] != RELATIONS]
    return [left.pop(_index(random, len(left))) for _ in range(min(SEEDS, len(left)))]


def _time(
    day: date, after: datetime, taken: Sequence[datetime], random: Random
) -> datetime | None:
    """A time in `day`'s parts, after `after`, `APART` from each `taken`; None if none is."""
    free = [(spans, weight) for start, end, weight in PARTS
            if (spans := _free(_span(day, start, end), after, taken))]
    if not free:
        return None
    weighed = _draw(random) * sum(weight for _, weight in free)
    for spans, weight in free:  # the last, should rounding leave it past them all
        if weighed < weight:
            break
        weighed -= weight
    length = sum((end - start for start, end in spans), timedelta())
    into = timedelta(seconds=int(length.total_seconds() * _draw(random)))
    for start, end in spans:
        if into < end - start:
            return start + into
        into -= end - start
    raise AssertionError("drew a time past the spans")


def _span(day: date, start: time, end: time) -> tuple[datetime, datetime]:
    """The part of `day` in Tokyo from `start` to `end`, midnight ending the day."""
    ends = day + timedelta(days=1) if end == time(0) else day
    return datetime.combine(day, start, TOKYO), datetime.combine(ends, end, TOKYO)


def _free(
    span: tuple[datetime, datetime], after: datetime, taken: Sequence[datetime]
) -> list[tuple[datetime, datetime]]:
    """What is left of `span` after `after`, and `APART` from each `taken`."""
    spans = [(max(span[0], after), span[1])]
    for at in taken:
        spans = [
            piece
            for start, end in spans
            for piece in ((start, min(end, at - APART)), (max(start, at + APART), end))
        ]
    return [(start, end) for start, end in spans if start < end]


def _draw(random: Random) -> float:
    """A number from 0 up to 1."""
    return random(PLACES) / PLACES


def _index(random: Random, length: int) -> int:
    """One of the first `length` places, each as likely."""
    return random(PLACES) * length // PLACES
