"""The drink catalog (GLOSSARY.md「饮品」「材料」), loaded from the configuration beside the
characters'.

It is configuration, not data, as the gift catalog is: the maintainer keeps it in the
repository, and neither `.env` nor the admin console changes it. It has the original's 28
drinks, 24 mixed from the five ingredients and 4 bottled, served as they are. Each has its
identifier, its English name (what the recipe book, the order memo and her subtitles say),
its name in Japanese (what she says), its short name, its flavor and kind, and its
description; a mixed one its recipe and its recipe card, a bottled one how many parts of
Karmotrine are in it.

What the bar counter holds as a drink is served is matched against the recipes exactly
(`DrinkCatalog.match`): the parts, the ice, the ageing and the method all as a recipe has
them, but for Karmotrine where a recipe leaves it optional, is that drink; all of them
doubled is its big glass, unless it is big already. Anything else is broken, and cannot be
served.

Anything wrong in it keeps the backend from starting (`DrinkCatalogError`), as do bar tastes
in the character configuration that are not right by it (`check_bar_tastes`).
"""

import re
import tomllib
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, get_args

from eidolon.characters import Character, CharacterConfigError

Flavor = Literal["sweet", "bitter", "sour", "spicy", "bubbly"]
"""甜味、苦味、酸味、辛辣、发泡."""

Kind = Literal["girly", "manly", "classic", "classy", "promo"]
"""女性化、男性化、经典、时尚、宣传, as the recipe book's menu names them."""

Tolerance = Literal["weak", "medium", "strong"]
"""How well a character holds her drink: 弱、中、强."""

Method = Literal["mix", "blend"]
"""Shaken under 5 seconds, or 5 seconds and on."""

DRINKS_FILE = "drinks.toml"
"""The file's name, in the directory of the character configuration."""

MAX_PARTS = 20
"""What the mixer holds, of the five ingredients together."""

MAX_FLAVORS = 2
"""The most flavors a character likes at the bar."""

MAX_FAVORITES = 3
"""The most drinks a character loves."""

_VALID_ID = re.compile(r"[a-z0-9_-]+")


class DrinkCatalogError(RuntimeError):
    """The drink catalog is missing or broken."""


@dataclass(frozen=True)
class Recipe:
    adelhyde: int
    bronson_extract: int
    powdered_delta: int
    flanergide: int
    karmotrine: int | None
    """None where it is optional: none makes the drink without alcohol."""
    ice: bool
    aged: bool
    method: Method
    big: bool = False
    """A big glass already, with no doubled one."""


@dataclass(frozen=True)
class Drink:
    id: str
    """What is easy to read, from its English name (`sugar-rush`)."""
    name: str
    """Its English name, as the recipe book, the order memo and her subtitles have it."""
    name_ja: str
    """Its name in the Japanese release, as she says it."""
    short_name: str
    """As the mixer shows it once made."""
    flavor: Flavor
    kind: Kind
    description: str
    """The official Chinese description: on its recipe card, or, bottled, the line under it."""
    recipe: Recipe | None
    """None for a bottled drink."""
    page: int | None = None
    """Its recipe card's number (the frontend's `recipe_<page>.png`); None for a bottled drink."""
    bottled_karmotrine: int = 0
    """How many parts of Karmotrine a bottled drink has in it."""

    def described(self) -> dict:
        """As the bar counter and the recipe book read it: without its Japanese name, nor
        its recipe card's description, which the frontend has on the card itself."""
        shown: dict = {
            "id": self.id, "name": self.name, "short_name": self.short_name,
            "flavor": self.flavor, "kind": self.kind,
        }
        recipe = self.recipe
        if recipe is None:
            return shown | {
                "method": "bottle", "description": self.description,
                "karmotrine": self.bottled_karmotrine,
            }
        return shown | {
            "method": recipe.method, "adelhyde": recipe.adelhyde,
            "bronson_extract": recipe.bronson_extract, "powdered_delta": recipe.powdered_delta,
            "flanergide": recipe.flanergide,
            "karmotrine": "optional" if recipe.karmotrine is None else recipe.karmotrine,
            "ice": recipe.ice, "aged": recipe.aged, "big": recipe.big, "page": self.page,
        }


@dataclass(frozen=True)
class Mixture:
    """What the bar counter holds as a drink is served: how many parts of each ingredient,
    whether on ice and aged, and how it was shaken."""

    adelhyde: int
    bronson_extract: int
    powdered_delta: int
    flanergide: int
    karmotrine: int
    ice: bool
    aged: bool
    method: Method


@dataclass(frozen=True)
class Served:
    """A drink as it would be served."""

    drink: Drink
    big: bool
    """Its doubled glass; never for a drink big already, or bottled."""
    karmotrine: int
    """How many parts of Karmotrine are in this glass: as many as were put in, the doubled
    glass's doubled; or as many as are in the bottle."""

    @property
    def alcoholic(self) -> bool:
        return self.karmotrine > 0


@dataclass(frozen=True)
class _Glass:
    """One glass a mixed drink is made as, its own or its doubled one."""

    drink: Drink
    big: bool
    parts: tuple[int, int, int, int]
    """Of the four ingredients but Karmotrine, in the recipe card's order."""
    karmotrine: int | None
    """None where it is optional."""
    ice: bool
    aged: bool
    method: Method

    def made_of(self, mixture: Mixture) -> bool:
        return (
            (self.ice, self.aged, self.method) == (mixture.ice, mixture.aged, mixture.method)
            and self.parts == _parts(mixture)
            and self.karmotrine in (None, mixture.karmotrine)
        )


def _parts(mixture: Mixture) -> tuple[int, int, int, int]:
    return (mixture.adelhyde, mixture.bronson_extract, mixture.powdered_delta, mixture.flanergide)


def _glasses(drink: Drink) -> list[_Glass]:
    """The glasses `drink` is made as: its own, and doubled unless it is big already."""
    recipe = drink.recipe
    if recipe is None:
        return []
    parts = (recipe.adelhyde, recipe.bronson_extract, recipe.powdered_delta, recipe.flanergide)
    own = _Glass(drink, False, parts, recipe.karmotrine, recipe.ice, recipe.aged, recipe.method)
    if recipe.big:
        return [own]
    doubled = _Glass(
        drink, True, (parts[0] * 2, parts[1] * 2, parts[2] * 2, parts[3] * 2),
        None if recipe.karmotrine is None else recipe.karmotrine * 2,
        recipe.ice, recipe.aged, recipe.method,
    )
    return [own, doubled]


class DrinkCatalog:
    """The drinks, in file order, and what a mixture or a bottle is of them."""

    def __init__(self, drinks: list[Drink]) -> None:
        """Raises DrinkCatalogError if a mixture could be either of two of `drinks`."""
        self.drinks = {d.id: d for d in drinks}
        self._glasses = [g for d in drinks for g in _glasses(d)]
        for i, one in enumerate(self._glasses):
            for other in self._glasses[i + 1:]:
                if one.drink is not other.drink and _overlap(one, other):
                    raise DrinkCatalogError(
                        f"饮品 {_named(one)}和 {_named(other)}的配方重合，调出来认不出是哪一款"
                    )

    def mixed(self) -> list[Drink]:
        return [d for d in self.drinks.values() if d.recipe is not None]

    def described(self) -> list[dict]:
        """Every drink as the bar counter and the recipe book read it, in file order."""
        return [d.described() for d in self.drinks.values()]

    def match(self, served: Mixture | str) -> Served | None:
        """The drink a mixture is, or the bottled drink of an identifier; None if the
        mixture is broken (over what the mixer holds, or parts that are not whole numbers
        from 0 included), or there is no such bottled drink."""
        if isinstance(served, str):
            drink = self.drinks.get(served)
            if drink is None or drink.recipe is not None:
                return None
            return Served(drink, False, drink.bottled_karmotrine)
        put = (*_parts(served), served.karmotrine)
        if any(type(p) is not int or p < 0 for p in put) or sum(put) > MAX_PARTS:
            return None
        for glass in self._glasses:
            if glass.made_of(served):
                return Served(glass.drink, glass.big, served.karmotrine)
        return None


def check_bar_tastes(characters: Mapping[str, Character], catalog: DrinkCatalog) -> None:
    """Raises CharacterConfigError unless every character likes one to `MAX_FLAVORS`
    flavors, a kind or none, loves one to `MAX_FAVORITES` drinks in `catalog`, dislikes a
    flavor she does not like or none, and holds her drink one of the ways there are; and
    none of the drinks she loves is of the flavor she dislikes."""
    for c in characters.values():
        flavors, favorites = c.bar_flavors, c.bar_favorites
        _some_of(c.id, "bar_flavors", "喜欢的口味", flavors, MAX_FLAVORS)
        for flavor in flavors:
            _named_one_of(c.id, "bar_flavors", flavor, Flavor)
        if c.bar_kind is not None:
            _named_one_of(c.id, "bar_kind", c.bar_kind, Kind)
        _some_of(c.id, "bar_favorites", "爱喝的饮品", favorites, MAX_FAVORITES)
        if unknown := [d for d in favorites if d not in catalog.drinks]:
            raise CharacterConfigError(
                f"角色 {c.id} 的 bar_favorites 里的 {'、'.join(unknown)} 不在饮品目录里"
            )
        if (disliked := c.bar_disliked_flavor) is not None:
            _named_one_of(c.id, "bar_disliked_flavor", disliked, Flavor)
            if disliked in flavors:
                raise CharacterConfigError(
                    f"角色 {c.id} 的 bar_disliked_flavor {disliked} 也在她喜欢的口味 bar_flavors 里"
                )
            if hated := [d for d in favorites if catalog.drinks[d].flavor == disliked]:
                raise CharacterConfigError(
                    f"角色 {c.id} 爱喝的 {'、'.join(hated)} 是她讨厌的口味 {disliked}"
                )
        if c.bar_tolerance is None:
            raise CharacterConfigError(f"角色 {c.id} 没有配 bar_tolerance（酒量）")
        _named_one_of(c.id, "bar_tolerance", c.bar_tolerance, Tolerance)


def _some_of(id: str, field: str, what: str, names: tuple[str, ...], most: int) -> None:
    """Raises CharacterConfigError unless character `id` has one to `most` `names` in
    `field`, none twice."""
    if not names:
        raise CharacterConfigError(f"角色 {id} 没有配 {field}（{what}，1–{most} 个）")
    if len(names) > most:
        raise CharacterConfigError(f"角色 {id} 的 {field} 有 {len(names)} 个，最多 {most} 个")
    if len(set(names)) < len(names):
        raise CharacterConfigError(f"角色 {id} 的 {field} 里有重复的{what}")


def _named_one_of(id: str, field: str, value: str, choices: object) -> None:
    """Raises CharacterConfigError unless `value` in character `id`'s `field` is one of the
    `Literal` `choices`."""
    if value not in get_args(choices):
        raise CharacterConfigError(
            f"角色 {id} 的 {field} 里的 {value} 不在 {'、'.join(get_args(choices))} 之中"
        )


def drinks_path(characters_path: Path) -> Path:
    """Where the drink catalog is: beside the character configuration."""
    return characters_path.parent / DRINKS_FILE


def load_drink_catalog(path: Path) -> DrinkCatalog:
    """The drinks in the catalog at `path`, in file order. Raises DrinkCatalogError if it is
    missing or broken, or if a mixture could be either of two drinks."""
    try:
        config = tomllib.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise DrinkCatalogError(f"找不到饮品目录 {path}") from None
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as e:
        raise DrinkCatalogError(f"饮品目录 {path} 格式有误：{e}") from None
    entries = config.get("drinks", [])
    if not isinstance(entries, list):
        raise DrinkCatalogError(f"饮品目录 {path} 里的 drinks 应当是 [[drinks]] 段")
    drinks: dict[str, Drink] = {}
    for entry in entries:
        drink = _parse_drink(entry)
        if drink.id in drinks:
            raise DrinkCatalogError(f"饮品标识 {drink.id} 重复")
        drinks[drink.id] = drink
    return DrinkCatalog(list(drinks.values()))


def _named(glass: _Glass) -> str:
    return f"{glass.drink.id}（大杯）" if glass.big else f"{glass.drink.id} "


def _overlap(one: _Glass, other: _Glass) -> bool:
    """Whether some mixture is made as both."""
    return (
        (one.parts, one.ice, one.aged, one.method)
        == (other.parts, other.ice, other.aged, other.method)
        and (one.karmotrine is None or other.karmotrine is None or one.karmotrine == other.karmotrine)
    )


_COMMON = ("id", "name", "name_ja", "short_name", "flavor", "kind", "method", "karmotrine", "description")
_INGREDIENTS = ("adelhyde", "bronson_extract", "powdered_delta", "flanergide")
_MIXED_ONLY = (*_INGREDIENTS, "ice", "aged", "big", "page")
_MIXED_REQUIRED = (*_INGREDIENTS, "ice", "aged", "page")


def _parse_drink(entry: object) -> Drink:
    if not isinstance(entry, dict):
        raise DrinkCatalogError(f"饮品目录里的 {entry!r} 应当是一个 [[drinks]] 段")
    label = entry.get("id", "（没有标识）")
    bottled = entry.get("method") == "bottle"
    required = _COMMON if bottled else (*_COMMON, *_MIXED_REQUIRED)
    if missing := [f for f in required if f not in entry]:
        raise DrinkCatalogError(f"饮品 {label} 缺少 {'、'.join(missing)}")
    id = entry["id"]
    if not isinstance(id, str) or not _VALID_ID.fullmatch(id):
        raise DrinkCatalogError(f"饮品标识 {id} 只能用小写字母、数字、- 和 _")
    for field in ("name", "name_ja", "short_name", "description"):
        value = entry[field]
        if not isinstance(value, str) or not value.strip() or any(c in value for c in "\r\n"):
            raise DrinkCatalogError(f"饮品 {id} 的 {field} 应当是一行文字")
    _one_of(entry["flavor"], Flavor, f"饮品 {id} 的口味")
    _one_of(entry["kind"], Kind, f"饮品 {id} 的种类")
    name, name_ja, short_name = entry["name"], entry["name_ja"], entry["short_name"]
    flavor, kind, description = entry["flavor"], entry["kind"], entry["description"]
    if bottled:
        if mixed_only := [f for f in _MIXED_ONLY if f in entry]:
            raise DrinkCatalogError(f"饮品 {id} 是瓶装，不能有 {'、'.join(mixed_only)}")
        karmotrine = _count(entry["karmotrine"], f"饮品 {id} 是瓶装，它的 karmotrine")
        return Drink(
            id, name, name_ja, short_name, flavor, kind, description, None,
            bottled_karmotrine=karmotrine,
        )
    _one_of(entry["method"], Method, f"饮品 {id} 的调法（瓶装是 bottle）")
    return Drink(
        id, name, name_ja, short_name, flavor, kind, description, _parse_recipe(id, entry),
        page=_page(id, entry["page"]),
    )


def _parse_recipe(id: str, entry: dict) -> Recipe:
    a, b, d, f = (_count(entry[i], f"饮品 {id} 的 {i}") for i in _INGREDIENTS)
    listed = entry["karmotrine"]
    karmotrine = None if listed == "optional" else _count(
        listed, f"饮品 {id} 的 karmotrine（可选的写 \"optional\"）"
    )
    flags = {}
    for field in ("ice", "aged", "big"):
        flags[field] = entry.get(field, False)
        if not isinstance(flags[field], bool):
            raise DrinkCatalogError(f"饮品 {id} 的 {field} 应当是 true 或 false")
    total = a + b + d + f + (karmotrine or 0)
    if total > MAX_PARTS:
        raise DrinkCatalogError(f"饮品 {id} 的材料合计 {total} 份，摇酒壶最多装 {MAX_PARTS} 份")
    if total == 0:
        raise DrinkCatalogError(f"饮品 {id} 的配方一份材料都没有")
    if not flags["big"] and total * 2 > MAX_PARTS:
        raise DrinkCatalogError(
            f"饮品 {id} 翻倍成大杯是 {total * 2} 份，超过摇酒壶的 {MAX_PARTS} 份；"
            "本身就是大杯的写 big = true"
        )
    return Recipe(a, b, d, f, karmotrine, flags["ice"], flags["aged"], entry["method"], flags["big"])


def _count(value: object, label: str) -> int:
    if type(value) is not int or not 0 <= value <= MAX_PARTS:
        raise DrinkCatalogError(f"{label} 应当是 0 到 {MAX_PARTS} 的整数，而不是 {value!r}")
    return value


def _page(id: str, value: object) -> int:
    if type(value) is not int or value < 1:
        raise DrinkCatalogError(f"饮品 {id} 的 page 应当是配方卡的编号，从 1 起，而不是 {value!r}")
    return value


def _one_of(value: object, choices: object, label: str) -> None:
    """Raises DrinkCatalogError unless `value` is one of the `Literal` `choices`."""
    if value not in get_args(choices):
        raise DrinkCatalogError(f"{label} {value} 不在 {'、'.join(get_args(choices))} 之中")
