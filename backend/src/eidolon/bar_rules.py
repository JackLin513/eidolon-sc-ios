"""The bar's rules (GLOSSARY.md「光顾」「点单」): every number a visit is drawn and judged by,
in one place, and how her orders are drawn and the drinks served her judged.

How many drinks she has in a visit is drawn as she comes in (`CUPS`). Each drink she orders
is drawn as the call that has her order it is about to be made: first which of three buckets
(`BUCKETS`), the drinks she loves, those of a flavor she likes or of her kind but for those,
and any at all; then one of the bucket's, each as likely. None is ever of the flavor she
dislikes, nor one she has ordered in this visit; her first order is none of what she had
the last time (`had`). A bucket left empty by that falls to the next; the last too, and it
is drawn from again with what she had the last time let back in.

How she orders it is named (`bar_lines.Phrasing`); for now always by the drink's name, which
only that drink served answers, in any glass, and which has no best (`Tier`). A drink served
wrong is wrong in the first of these ways that is so: of the flavor she dislikes; of the
flavor she ordered but not the kind, or of the kind but not the flavor; quite off.
"""

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import timedelta
from typing import Literal

from eidolon.bar_lines import Phrasing, Tier
from eidolon.bar_visits import Mood
from eidolon.characters import Character
from eidolon.drink_catalog import Drink, DrinkCatalog, Served
from eidolon.randomness import Random

Bucket = Literal["favorite", "liking", "whim"]
"""爱喝的、合口味的、心血来潮."""

BUCKETS: tuple[tuple[Bucket, int], ...] = (("favorite", 45), ("liking", 35), ("whim", 20))
"""Each bucket her order is drawn from, in the order an empty one falls to the next, and how
likely, in percent."""

CUPS: tuple[tuple[int, int], ...] = ((1, 20), (2, 60), (3, 20))
"""How many drinks she has in a visit, and how likely each, in percent."""

REGULAR_VISITS = 5
"""How many visits with the user she has had, done, to be a regular at the bar."""

LONG_AGO = timedelta(days=14)
"""Longer than this since her last visit, she has not been in for a long time."""

Wrong = Literal["disliked", "flavor_only", "kind_only", "off"]
"""How a drink served wrong is: of the flavor she dislikes; of the flavor she ordered but
not the kind; of the kind but not the flavor; quite off."""


@dataclass(frozen=True)
class Reason:
    """Her reason for coming (GLOSSARY.md「来意」): one of the list's, or the job of hers the
    producer scheduled today and she has done."""

    id: str
    """The listed reason's identifier, or the job's name."""
    note: str
    mood: Mood | None
    """How she is as she comes in; None for a job, which she makes of it herself."""
    job: bool = False


@dataclass(frozen=True)
class Order:
    """What she orders: the drink she wants (`target`) and how she says it."""

    target: Drink
    phrasing: Phrasing = "name"

    @property
    def memo(self) -> str:
        """The order memo, the producer's note of what she wants."""
        return f"她要 {self.target.name}。"


@dataclass(frozen=True)
class Serving:
    """A drink served for an order, and how well."""

    order: Order
    served: Served
    tier: Tier
    wrong: Wrong | None = None
    """How it is wrong, if it is."""


@dataclass(frozen=True)
class Had:
    """One of her orders in a visit done, as it is remembered: what she wanted, how she
    said it, what was served her and how well."""

    target: str
    """The drink's identifier."""
    phrasing: Phrasing
    served: str
    big: bool
    tier: Tier

    @property
    def wanted(self) -> str:
        """The drink she wanted, as the producer would know it: the one served, served right
        or best; else the one she ordered."""
        return self.served if self.tier != "wrong" else self.target


def drawn(table: Sequence[tuple[object, int]], random: Random) -> int:
    """Which row of `table`, each as likely as its percent, by `random`."""
    number, upto = random(100), 0
    for i, (_, percent) in enumerate(table):
        upto += percent
        if number < upto:
            return i
    raise AssertionError("the percents add up to less than 100")


def cups(random: Random) -> int:
    """How many drinks she has in a visit."""
    return CUPS[drawn(CUPS, random)][0]


def draw_order(
    character: Character,
    catalog: DrinkCatalog,
    random: Random,
    ordered: Sequence[str],
    had: frozenset[str],
) -> Order:
    """Her next order, having `ordered` these drinks in the visit so far, and, for her first,
    had these the last time."""
    buckets = _buckets(character, catalog)
    start = drawn(BUCKETS, random)
    for avoiding in (had, frozenset()):
        left = [
            [d for d in buckets[bucket] if d.id not in ordered and d.id not in avoiding]
            for bucket, _ in BUCKETS[start:]
        ]
        if bucket := next((b for b in left if b), None):
            return Order(bucket[random(len(bucket))])
    raise AssertionError("every drink but those of the flavor she dislikes has been ordered")


def judged(order: Order, served: Served, character: Character) -> Serving:
    """How well `served` answers `order` for her."""
    target, drink = order.target, served.drink
    if drink.id == target.id:
        return Serving(order, served, "right")
    return Serving(order, served, "wrong", _wrong(target, drink, character))


def _wrong(target: Drink, drink: Drink, character: Character) -> Wrong:
    if drink.flavor == character.bar_disliked_flavor:
        return "disliked"
    if drink.flavor == target.flavor and drink.kind != target.kind:
        return "flavor_only"
    if drink.kind == target.kind and drink.flavor != target.flavor:
        return "kind_only"
    return "off"


def _buckets(character: Character, catalog: DrinkCatalog) -> Mapping[Bucket, list[Drink]]:
    """The drinks of each bucket, in catalog order, none of the flavor she dislikes."""
    drinks = [d for d in catalog.drinks.values() if d.flavor != character.bar_disliked_flavor]
    favorites = set(character.bar_favorites)
    return {
        "favorite": [d for d in drinks if d.id in favorites],
        "liking": [
            d for d in drinks
            if d.id not in favorites
            and (d.flavor in character.bar_flavors or d.kind == character.bar_kind)
        ],
        "whim": drinks,
    }
