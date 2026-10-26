"""The bar's rules (GLOSSARY.md「光顾」「点单」): every number a visit is drawn and judged by,
in one place, and how her orders are drawn, said and the drinks served her judged.

How many drinks she has in a visit is drawn as she comes in (`CUPS`). Each drink she orders
is drawn as the call that has her order it is about to be made: first which of three buckets
(`BUCKETS`), the drinks she loves, those of a flavor she likes or of her kind but for those,
and any at all; then one of the bucket's, each as likely. None is ever of the flavor she
dislikes, nor one she has ordered in this visit; her first order is none of what she wanted
the last time (`Known.usual`). A bucket left empty by that falls to the next; the last too,
and it is drawn from again with what she had the last time let back in.

Then how she says it (`PHRASINGS`), of the ways she can for that drink, each as likely as its
percent among them: a novice at the bar (`NOVICE_VISITS`) is spared conditions and analogies;
she asks for her favorite, or the usual, only once she has a visit done with the user, her
favorite only for a drink she loves; by name and big only for a drink with a doubled glass;
in conditions only for a drink with one beside its flavor and kind (`EXTRAS`). The usual is
one of what she wanted the last time, whatever she was to have, and none she has ordered in
this visit. A drink that may be made without alcohol she may want so, by how well she holds
her drink (`NO_ALCOHOL`), unless it is the usual.

What is right for an order, and what is best, follow from its drink and how she says it, and
are never told her: what she says of it (`Order.said`) a drink must all be, and
- by name, or by an analogy, only that drink, in any glass; by name and big, best big;
- the usual, any she wanted the last time;
- her favorite, any she loves, or of a flavor she likes or of her kind; best one she loves;
- else, any, best one she loves.
None of the flavor she dislikes is ever right. A drink served wrong is wrong in the first of
these ways that is so: of the flavor she dislikes; with alcohol, wanted without; not the
usual; of the flavor of the drink she meant but not its kind, or of the kind but not the
flavor; quite off.

What she says ordering is checked for names (`names_rightly`); where it is not right even
rewritten, she says one of the fixed lines for it instead (`fixed_order`). The order memo is
the producer's note of what she wants (`Order.memo`).
"""

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, replace
from datetime import timedelta
from typing import Literal

from eidolon.bar_lines import BarLines, Line, Phrasing, Tier, folded
from eidolon.bar_reply import BarLine
from eidolon.bar_visits import Mood
from eidolon.characters import Character
from eidolon.drink_catalog import Drink, DrinkCatalog, Flavor, Kind, Served
from eidolon.randomness import Random

Bucket = Literal["favorite", "liking", "whim"]
"""Where her order is drawn from: the drinks she loves (爱喝的), those to her liking (合口味的),
any at all (心血来潮)."""

BUCKETS: tuple[tuple[Bucket, int], ...] = (("favorite", 45), ("liking", 35), ("whim", 20))
"""Each bucket her order is drawn from, in the order an empty one falls to the next, and how
likely, in percent."""

PHRASINGS: tuple[tuple[Phrasing, int], ...] = (
    ("name", 40), ("name_big", 7), ("flavor", 12), ("kind", 12), ("conditions", 8),
    ("analogy", 8), ("my_favorite", 4), ("your_call", 4), ("usual", 5),
)
"""Each way she says her order, and how likely, in percent of all; those she cannot say an
order in are left out, and the rest drawn from by their percents."""

NAMING: frozenset[Phrasing] = frozenset({"name", "name_big"})
"""The ways of ordering that name the drink."""

NOVICE_VISITS = 3
"""How many visits done, with anyone, a user has before the hardest ways of ordering."""

NO_ALCOHOL: dict[str, int] = {"weak": 40, "medium": 10, "strong": 0}
"""How likely she wants a drink that may be made without alcohol so, in percent, by how well
she holds her drink."""

CUPS: tuple[tuple[int, int], ...] = ((1, 20), (2, 60), (3, 20))
"""How many drinks she has in a visit, and how likely each, in percent."""

REGULAR_VISITS = 5
"""How many visits with the user she has had, done, to be a regular at the bar."""

LONG_AGO = timedelta(days=14)
"""Longer than this since her last visit, she has not been in for a long time."""

Condition = Literal["flavor", "kind", "ice", "big", "no_alcohol"]
"""What she may say of the drink she wants: its flavor, its kind, on ice, in a big glass,
without alcohol."""

EXTRAS: tuple[Condition, ...] = ("ice", "big", "no_alcohol")
"""What she may say of a drink beside its flavor or kind, in the order she says them."""

Wrong = Literal["disliked", "alcohol", "not_usual", "flavor_only", "kind_only", "off"]
"""How a drink served wrong is: of the flavor she dislikes; with alcohol, wanted without; not
the usual; of the flavor she meant but not the kind; of the kind but not the flavor; quite
off."""

FLAVORS: dict[str, str] = {"sweet": "甜", "bitter": "苦", "sour": "酸", "spicy": "辣", "bubbly": "发泡"}
KINDS: dict[str, str] = {
    "girly": "女性化", "manly": "男性化", "classic": "经典", "classy": "时尚", "promo": "宣传",
}
"""As the recipe book's menu names them."""

_FLAVORS_JA: dict[Flavor, str] = {
    "sweet": "甘いの", "bitter": "苦いの", "sour": "酸っぱいの", "spicy": "辛いの",
    "bubbly": "シュワシュワの",
}
_KINDS_JA: dict[Kind, str] = {
    "girly": "かわいい系の", "manly": "男らしいの", "classic": "定番の", "classy": "おしゃれなの",
    "promo": "キャンペーンの",
}
_EXTRAS_SAID: dict[Condition, tuple[str, str]] = {
    "ice": ("加冰", "氷入り"), "big": ("大杯", "大きいサイズ"), "no_alcohol": ("不要酒精", "アルコール抜き"),
}
"""Each condition but the flavor and kind as she says it, in Chinese and in Japanese."""

_MEMOS: dict[Phrasing, str] = {
    "my_favorite": "她要她喜欢的", "your_call": "她让你拿主意", "usual": "她要上次那款",
}


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
class Known:
    """What her orders are drawn knowing of the user and her."""

    novice: bool
    """Whether the user has fewer than `NOVICE_VISITS` visits done, with anyone."""
    usual: frozenset[str]
    """What she wanted on her last visit with the user (`Had.wanted`); none before one."""


@dataclass(frozen=True)
class Order:
    """What she orders: the drink she means (`target`), how she says it and what of it."""

    target: Drink
    phrasing: Phrasing = "name"
    said: tuple[Condition, ...] = ()
    """What she says of it, all of which a drink must be to be right: as the target is."""
    usual: frozenset[str] = frozenset()
    """For the usual, what she wanted the last time."""

    @property
    def mentioned(self) -> tuple[Condition, ...]:
        """What she is to say of it: `said`, after a big glass where she asks for it by name."""
        return ("big", *self.said) if self.phrasing == "name_big" else self.said

    def words(self, *, ja: bool = False) -> list[str]:
        """What she is to say of it, each as she says it, in Chinese or in Japanese."""
        return [_word(c, self.target, ja) for c in self.mentioned]

    def memo(self, subtitle: str) -> str:
        """The order memo, the producer's note of what she wants; for an analogy, her order's
        `subtitle` itself."""
        if self.phrasing == "analogy":
            return subtitle
        if self.phrasing in ("flavor", "kind", "conditions"):
            return f"她要{'，'.join(self.words())}。"
        head = _MEMOS.get(self.phrasing, f"她要 {self.target.name}")
        return "，".join([head, *self.words()]) + "。"


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
    """Which row of `table`, each as likely as its share of the percents, by `random`."""
    number, upto = random(sum(percent for _, percent in table)), 0
    for i, (_, percent) in enumerate(table):
        upto += percent
        if number < upto:
            return i
    raise AssertionError("unreachable: the number is below the percents' sum")


def cups(random: Random) -> int:
    """How many drinks she has in a visit."""
    return CUPS[drawn(CUPS, random)][0]


def draw_order(
    character: Character,
    catalog: DrinkCatalog,
    random: Random,
    ordered: Sequence[str],
    known: Known,
    *,
    first: bool,
) -> Order:
    """Her next order, having `ordered` these drinks in the visit so far, `first` if none."""
    target, bucket = _target(
        _buckets(character, catalog), random, ordered, known.usual if first else frozenset()
    )
    usuals = [
        d for d in catalog.drinks.values()
        if d.id in known.usual and d.id not in ordered
        and d.flavor != character.bar_disliked_flavor
    ]
    can: dict[Phrasing, bool] = {
        "name": True, "name_big": _doubles(target), "flavor": True, "kind": True,
        "conditions": not known.novice and bool(_extras(target)),
        "analogy": not known.novice and bool(target.description),
        "my_favorite": bucket == "favorite" and bool(known.usual),
        "your_call": True, "usual": bool(usuals),
    }
    phrasings: list[tuple[Phrasing, int]] = [(p, n) for p, n in PHRASINGS if can[p]]
    phrasing = phrasings[drawn(phrasings, random)][0]
    if phrasing == "usual":
        return Order(usuals[random(len(usuals))], "usual", usual=known.usual)
    said: tuple[Condition, ...] = ()
    if phrasing in ("flavor", "kind"):
        said = ("flavor",) if phrasing == "flavor" else ("kind",)
    elif phrasing == "conditions":
        said = _conditions(target, random)
    if "no_alcohol" not in said and _wants_it_without_alcohol(character, target, random):
        said = (*said, "no_alcohol")
    return Order(target, phrasing, said)


def judged(order: Order, served: Served, character: Character) -> Serving:
    """How well `served` answers `order` for her."""
    drink = served.drink
    right = (
        drink.flavor != character.bar_disliked_flavor
        and all(_meets(c, order.target, served) for c in order.said)
        and _among(order, drink, character)
    )
    if not right:
        return Serving(order, served, "wrong", _wrong(order, served, character))
    return Serving(order, served, "best" if _best(order, served, character) else "right")


def names_rightly(order: Order, lines: Sequence[BarLine], catalog: DrinkCatalog) -> bool:
    """Whether `lines`, her order, name drinks as they should: the drink she means, in Chinese
    by its English name or in Japanese by its Japanese one, where she orders by name; else
    none of the catalog's in either, whatever the case or width."""
    if order.phrasing in NAMING:
        target = order.target
        return any(
            folded(target.name) in folded(line.zh) or folded(target.name_ja) in folded(line.ja)
            for line in lines
        )
    names = [folded(n) for d in catalog.drinks.values() for n in (d.name, d.name_ja)]
    said = [folded(text) for line in lines for text in (line.ja, line.zh)]
    return not any(name in text for name in names for text in said)


def fixed_order(order: Order, lines: BarLines, random: Random) -> tuple[Order, list[BarLine]]:
    """Her order said in one of the fixed lines for how she says it, and the line she adds
    for it without alcohol where she wants it so but cannot say it in that line; with the
    order as it is now: an analogy, which a fixed line cannot make, said and judged as
    conditions, the drink's flavor and kind."""
    group = lines.orders[order.phrasing]
    if order.phrasing == "analogy":
        order = replace(
            order, phrasing="conditions",
            said=("flavor", "kind", *(c for c in order.said if c == "no_alcohol")),
        )
    line = group[random(len(group))]
    said = [_filled(line, order)]
    if "no_alcohol" in order.said and order.phrasing != "conditions":
        added = lines.no_alcohol[random(len(lines.no_alcohol))]
        said.append(BarLine("her", added.zh, added.ja, added.emotion, order=True))
    return order, said


def _filled(line: Line, order: Order) -> BarLine:
    """`line` with what `order` names filled in."""
    target = order.target
    in_ja = {
        "name_ja": target.name_ja, "flavor": _word("flavor", target, True),
        "kind": _word("kind", target, True), "conditions": "、".join(order.words(ja=True)),
    }
    in_zh = {
        "name": target.name, "flavor": _word("flavor", target, False),
        "kind": _word("kind", target, False), "conditions": "、".join(order.words()),
    }
    return BarLine("her", line.zh.format(**in_zh), line.ja.format(**in_ja), line.emotion, order=True)


def _word(condition: Condition, drink: Drink, ja: bool) -> str:
    if condition == "flavor":
        return _FLAVORS_JA[drink.flavor] if ja else f"{FLAVORS[drink.flavor]}的"
    if condition == "kind":
        return _KINDS_JA[drink.kind] if ja else f"{KINDS[drink.kind]}的"
    zh, in_ja = _EXTRAS_SAID[condition]
    return in_ja if ja else zh


def _target(
    buckets: Mapping[Bucket, list[Drink]],
    random: Random,
    ordered: Sequence[str],
    avoiding: frozenset[str],
) -> tuple[Drink, Bucket]:
    """The drink she means, and the bucket it is of."""
    start = drawn(BUCKETS, random)
    for avoided in (avoiding, frozenset()):
        for bucket, _ in BUCKETS[start:]:
            left = [d for d in buckets[bucket] if d.id not in ordered and d.id not in avoided]
            if left:
                return left[random(len(left))], bucket
    raise AssertionError("every drink but those of the flavor she dislikes has been ordered")


def _doubles(drink: Drink) -> bool:
    """Whether `drink` has a doubled glass: mixed, and not big already."""
    return drink.recipe is not None and not drink.recipe.big


def _extras(drink: Drink) -> tuple[Condition, ...]:
    """What she may say of `drink` beside its flavor and kind."""
    recipe = drink.recipe
    can: dict[Condition, bool] = {
        "ice": recipe is not None and recipe.ice,
        "big": _doubles(drink),
        "no_alcohol": (
            recipe.karmotrine in (None, 0) if recipe is not None
            else drink.bottled_karmotrine == 0
        ),
    }
    return tuple(c for c in EXTRAS if can[c])


def _conditions(target: Drink, random: Random) -> tuple[Condition, ...]:
    """Its flavor or its kind, and one or two of what else she may say of it."""
    first: Condition = "flavor" if random(2) == 0 else "kind"
    left = list(_extras(target))
    picked = [left.pop(random(len(left))) for _ in range(1 + random(2) if len(left) > 1 else 1)]
    return (first, *(c for c in EXTRAS if c in picked))


def _wants_it_without_alcohol(character: Character, target: Drink, random: Random) -> bool:
    """Whether she wants `target` without alcohol, which it may be made with or without."""
    percent = NO_ALCOHOL.get(character.bar_tolerance or "", 0)
    if target.recipe is None or target.recipe.karmotrine is not None or not percent:
        return False
    return random(100) < percent


def _meets(condition: Condition, target: Drink, served: Served) -> bool:
    """Whether `served` is as `target` is in `condition`."""
    drink = served.drink
    match condition:
        case "flavor":
            return drink.flavor == target.flavor
        case "kind":
            return drink.kind == target.kind
        case "ice":
            return drink.recipe is not None and drink.recipe.ice
        case "big":  # a drink big already is served in a big glass
            return served.big or (drink.recipe is not None and drink.recipe.big)
        case "no_alcohol":
            return not served.alcoholic


def _among(order: Order, drink: Drink, character: Character) -> bool:
    """Whether `drink` is one of those `order` may be answered with, by how she says it."""
    match order.phrasing:
        case "name" | "name_big" | "analogy":
            return drink.id == order.target.id
        case "usual":
            return drink.id in order.usual
        case "my_favorite":
            return (
                drink.id in character.bar_favorites or drink.flavor in character.bar_flavors
                or drink.kind == character.bar_kind
            )
        case _:
            return True


def _best(order: Order, served: Served, character: Character) -> bool:
    """Whether `served`, right for `order`, is best for it."""
    match order.phrasing:
        case "name" | "analogy" | "usual":
            return False
        case "name_big":
            return served.big
        case _:
            return served.drink.id in character.bar_favorites


def _wrong(order: Order, served: Served, character: Character) -> Wrong:
    target, drink = order.target, served.drink
    if drink.flavor == character.bar_disliked_flavor:
        return "disliked"
    if "no_alcohol" in order.said and served.alcoholic:
        return "alcohol"
    if order.phrasing == "usual":
        return "not_usual"
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
