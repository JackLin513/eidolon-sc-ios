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

Her places (`draw_places`): as many as `CANDIDATES`, for her to say she was at one or at
none, of the places right for the season and the time of day she posts at in Tokyo, and none
the user's moments were at within the last `KEPT_APART`. A venue is one only on a day she
stood on it in a year before, and is then hers before any is drawn; the rest are drawn by
weight, one of a kind she likes weighing `LIKED` times as much, her holy site `HOLY` times.

Every draw asks the random source for a number below `PLACES`, so that one giving the same
number each time draws alike wherever it is asked."""

from collections.abc import Collection, Sequence
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta

from eidolon.affinity import Tier
from eidolon.characters import Fact
from eidolon.job_list import Slot
from eidolon.place_pool import SEASONS, Place, Season
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

CANDIDATES = 4
"""How many places she is given to choose from at most, besides none."""

LIKED = 3
"""How much more a place of a kind she likes weighs."""

HOLY = 4
"""How much more a place weighs whose `idols` she is of: her holy site."""

KEPT_APART = timedelta(days=30)
"""How long a place one of the user's moments was at is not drawn again for them."""

_SEASONS: dict[int, Season] = {
    month: season
    for season, months in zip(SEASONS, ((3, 4, 5), (6, 7, 8), (9, 10, 11), (12, 1, 2)), strict=True)
    for month in months
}
"""The season of each month in Tokyo."""


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


def draw_places(
    places: Sequence[Place],
    character_id: str,
    likes: Collection[str] | None,
    venues: Collection[str],
    at: datetime,
    used: Collection[str],
    random: Random,
) -> list[Place]:
    """As many as `CANDIDATES` of `places` for her to choose from as she posts `at`: those
    right for its season and its slot in Tokyo (one with slots none late at night, before 6),
    none of `used` (by identifier); a venue only if `venues` (where her lives on this day in a
    year before were) names it, and then first. The rest are drawn by weight: `LIKED` for
    a kind she `likes`, `HOLY` for one whose `idols` are hers."""
    local = at.astimezone(TOKYO)
    season, slot = _SEASONS[local.month], _slot(local.hour)
    left = [
        p for p in places
        if p.id not in used
        and (p.seasons is None or season in p.seasons)
        and (p.slots is None or (slot is not None and slot in p.slots))
    ]
    drawn = [p for p in left if any(name in venues for name in p.venue_names)][:CANDIDATES]
    left = [p for p in left if p.category != "venue"]
    weights = [
        (LIKED if likes and p.category in likes else 1)
        * (HOLY if character_id in p.idols else 1)
        for p in left
    ]
    while left and len(drawn) < CANDIDATES:
        weighed = _draw(random) * sum(weights)
        index = len(left) - 1  # the last, should rounding leave it past them all
        for i, weight in enumerate(weights):
            if weighed < weight:
                index = i
                break
            weighed -= weight
        drawn.append(left.pop(index))
        weights.pop(index)
    return drawn


def _slot(hour: int) -> Slot | None:
    """The slot an hour in Tokyo is in; None late at night, before 6."""
    return None if hour < 6 else "morning" if hour < 12 else "afternoon" if hour < 18 else "evening"


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
