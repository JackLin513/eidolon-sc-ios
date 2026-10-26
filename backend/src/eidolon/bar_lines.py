"""The bar's fixed lines, loaded from the configuration beside the characters': what is said
at the bar without the model writing it.

It is configuration, not data, as the reasons and topics are: the maintainer keeps it in the
repository, and neither `.env`, the admin console nor the background model changes it. The
lines are for every character alike. There are:

- what the producer says as he serves each drink (`enjoy`), in Chinese only;
- her order for each way of ordering (`orders`), said instead of hers where hers names a
  drink it should not or does not name the one it should, even rewritten;
- what she adds where she wants it without alcohol (`no_alcohol`), after such an order;
- her reaction to a drink by how well it was served (`reactions`), and her farewell sober or
  drunk (`farewells`), said where the last call of a visit cannot be written.

Hers are each a line in Japanese with its Chinese subtitle, and how she looks saying it. An
order names what it must through placeholders the server fills in (`PLACEHOLDERS`): never a
drink by name, nor does any other line (`check_bar_lines`).

Anything wrong in it keeps the backend from starting (`BarLinesError`).
"""

import tomllib
import unicodedata
from collections.abc import Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path
from string import Formatter
from typing import Literal, NamedTuple, TypeVar, get_args

from eidolon.drink_catalog import DrinkCatalog
from eidolon.emotion import Emotion

Phrasing = Literal[
    "name", "name_big", "flavor", "kind", "conditions", "analogy", "my_favorite", "your_call",
    "usual",
]
"""How she orders: 直说饮品名、饮品名加大杯、说口味、说种类、几个条件叠加、照描述打比方、
「来杯我喜欢的」、「你拿主意」、「老样子」."""

Tier = Literal["best", "right", "wrong"]
"""How well a drink was served: 上得最好、上对、上错."""

Sobriety = Literal["sober", "drunk"]

_Group = TypeVar("_Group", bound=str)

BAR_LINES_FILE = "bar_lines.toml"
"""The file's name, in the directory of the character configuration."""



class Placeholders(NamedTuple):
    """The placeholders a line has in Japanese and in its subtitle, every one of them and no
    other."""

    ja: frozenset[str] = frozenset()
    zh: frozenset[str] = frozenset()


PLACEHOLDERS: dict[Phrasing, Placeholders] = {
    "name": Placeholders(frozenset({"name_ja"}), frozenset({"name"})),
    "name_big": Placeholders(frozenset({"name_ja"}), frozenset({"name"})),
    "flavor": Placeholders(frozenset({"flavor"}), frozenset({"flavor"})),
    "kind": Placeholders(frozenset({"kind"}), frozenset({"kind"})),
    "conditions": Placeholders(frozenset({"conditions"}), frozenset({"conditions"})),
    "analogy": Placeholders(frozenset({"conditions"}), frozenset({"conditions"})),
}
"""Each way of ordering's placeholders; the ways not here have none."""


class BarLinesError(RuntimeError):
    """The fixed lines are missing or broken."""


@dataclass(frozen=True)
class Line:
    """One of hers."""

    ja: str
    zh: str
    """Its Chinese subtitle."""
    emotion: Emotion = "calm"


@dataclass(frozen=True)
class BarLines:
    enjoy: list[str]
    orders: dict[Phrasing, list[Line]]
    no_alcohol: list[Line]
    reactions: dict[Tier, list[Line]]
    farewells: dict[Sobriety, list[Line]]


def bar_lines_path(characters_path: Path) -> Path:
    """Where the fixed lines are: beside the character configuration."""
    return characters_path.parent / BAR_LINES_FILE


def load_bar_lines(path: Path) -> BarLines:
    """The fixed lines at `path`. Raises BarLinesError, naming the group, if they are missing
    or broken."""
    try:
        config = tomllib.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise BarLinesError(f"找不到写死的句子 {path}") from None
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as e:
        raise BarLinesError(f"写死的句子 {path} 格式有误：{e}") from None
    enjoy = _group(config, "enjoy", path)
    for n, line in enumerate(enjoy, 1):
        if not isinstance(line, str):
            raise BarLinesError(f"enjoy 第 {n} 句应当是一行文字")
        _check_text(line, "enjoy", n, frozenset())
    return BarLines(
        enjoy,
        _table(config, "orders", get_args(Phrasing), path, PLACEHOLDERS),
        _lines(_group(config, "no_alcohol", path), "no_alcohol"),
        _table(config, "reactions", get_args(Tier), path),
        _table(config, "farewells", get_args(Sobriety), path),
    )


def check_bar_lines(lines: BarLines, catalog: DrinkCatalog) -> None:
    """Raises BarLinesError unless no line names a drink of `catalog`, in English or in
    Japanese, whatever its case or width."""
    names = [(d.name, folded(n)) for d in catalog.drinks.values() for n in (d.name, d.name_ja)]
    for label, n, text in _texts(lines):
        compared = folded(text)
        if said := [name for name, f in names if f in compared]:
            raise BarLinesError(f"{label} 第 {n} 句提到了饮品 {said[0]}")


def _texts(lines: BarLines) -> Iterator[tuple[str, int, str]]:
    """Every line's group, its place in it and its text: hers both in Japanese and in
    Chinese."""
    yield from (("enjoy", n, text) for n, text in enumerate(lines.enjoy, 1))
    tables = (
        ("orders", lines.orders), ("reactions", lines.reactions), ("farewells", lines.farewells),
    )
    groups = [
        ("no_alcohol", lines.no_alcohol),
        *((f"{t}.{g}", group) for t, table in tables for g, group in table.items()),
    ]
    for label, group in groups:
        for n, line in enumerate(group, 1):
            yield label, n, line.ja
            yield label, n, line.zh


def folded(text: str) -> str:
    """`text` as names in it are compared, whatever its case or width."""
    return unicodedata.normalize("NFKC", text).casefold()


def _group(config: dict, key: str, path: Path, label: str | None = None) -> list:
    """The group at `key` in `config`, named `label` (`key` unless given) if it is
    missing."""
    label = label or key
    group = config.get(key)
    if group is None:
        raise BarLinesError(f"写死的句子 {path} 里没有 {label} 这一组")
    if not isinstance(group, list):
        raise BarLinesError(f"写死的句子 {path} 里的 {label} 应当是一组句子")
    if not group:
        raise BarLinesError(f"写死的句子 {path} 里的 {label} 这一组是空的")
    return group


def _table(
    config: dict,
    key: str,
    groups: tuple[_Group, ...],
    path: Path,
    placeholders: Mapping[_Group, Placeholders] | None = None,
) -> dict[_Group, list[Line]]:
    """The lines of the `groups` in `[key]`, each of them there and none other, with the
    `placeholders` each has."""
    table = config.get(key)
    if not isinstance(table, dict):
        raise BarLinesError(f"写死的句子 {path} 里没有 [{key}] 这一节")
    if unknown := sorted(table.keys() - set(groups)):
        raise BarLinesError(
            f"写死的句子 {path} 里的 {'、'.join(f'{key}.{u}' for u in unknown)} 不是认识的组"
        )
    return {
        group: _lines(
            _group(table, group, path, label := f"{key}.{group}"),
            label,
            (placeholders or {}).get(group, Placeholders()),
        )
        for group in groups
    }


def _lines(group: list, label: str, placeholders: Placeholders = Placeholders()) -> list[Line]:
    lines = []
    for n, entry in enumerate(group, 1):
        if not isinstance(entry, dict):
            raise BarLinesError(f"{label} 第 {n} 句应当是一个 [[{label}]] 段")
        if missing := [f for f in ("ja", "zh") if f not in entry]:
            raise BarLinesError(f"{label} 第 {n} 句缺少 {'、'.join(missing)}")
        ja, zh, emotion = entry["ja"], entry["zh"], entry.get("emotion", "calm")
        _check_text(ja, label, n, placeholders.ja)
        _check_text(zh, label, n, placeholders.zh)
        if emotion not in get_args(Emotion):
            raise BarLinesError(
                f"{label} 第 {n} 句的表情 {emotion} 不在 {'、'.join(get_args(Emotion))} 之中"
            )
        lines.append(Line(ja, zh, emotion))
    return lines


def _check_text(text: object, label: str, n: int, placeholders: frozenset[str]) -> None:
    """Raises BarLinesError unless `text` is a line with all of `placeholders` and no
    other."""
    if not isinstance(text, str) or not text.strip() or any(c in text for c in "\r\n"):
        raise BarLinesError(f"{label} 第 {n} 句应当是一行文字")
    try:
        fields = [(f, spec, conversion) for _, f, spec, conversion in Formatter().parse(text)]
    except ValueError:
        raise BarLinesError(f"{label} 第 {n} 句的花括号没有配对：{text}") from None
    used = set()
    for field, spec, conversion in fields:
        if field is None:
            continue
        if field not in placeholders or spec or conversion:
            allowed = "、".join(f"{{{p}}}" for p in sorted(placeholders))
            raise BarLinesError(
                f"{label} 第 {n} 句用了不认识的占位 {{{field}}}，"
                + (f"这一组只能用 {allowed}" if allowed else "这一组不能用占位")
            )
        used.add(field)
    if missing := sorted(placeholders - used):
        raise BarLinesError(
            f"{label} 第 {n} 句缺少占位 {'、'.join(f'{{{p}}}' for p in missing)}：{text}"
        )
