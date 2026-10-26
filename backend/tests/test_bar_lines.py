"""The bar's fixed lines (characters/bar_lines.toml) come from configuration beside the
characters', as the reasons and topics do: what the producer says as he serves, her orders
where hers name what they should not or do not name what they should, and her reactions and
farewells where the last call cannot be written, for every character alike, checked as the
backend starts."""

import pytest

from eidolon.bar_lines import BAR_LINES_FILE, check_bar_lines, load_bar_lines
from eidolon.drink_catalog import load_drink_catalog

from tests.conftest import REPO_BAR_LINES, REPO_DRINKS, CharacterConfig, ClientFactory
from tests.fakes import FakeLLM


def test_the_repositorys_lines_have_at_least_three_in_every_group_and_no_drink_named():
    lines = load_bar_lines(REPO_BAR_LINES)

    check_bar_lines(lines, load_drink_catalog(REPO_DRINKS))
    groups = [
        lines.enjoy, lines.no_alcohol, *lines.orders.values(), *lines.reactions.values(),
        *lines.farewells.values(),
    ]
    assert all(len(g) >= 3 for g in groups)


def line(group: str, ja: str = "はい。", zh: str = "好。") -> str:
    return f'[[{group}]]\nja = "{ja}"\nzh = "{zh}"\n'


ORDERS = {
    "name": line("orders.name", "{name_ja}で。", "{name}。"),
    "name_big": line("orders.name_big", "{name_ja}、大きいので。", "{name}，大杯。"),
    "flavor": line("orders.flavor", "{flavor}で。", "{flavor}。"),
    "kind": line("orders.kind", "{kind}で。", "{kind}。"),
    "conditions": line("orders.conditions", "{conditions}で。", "{conditions}。"),
    "analogy": line("orders.analogy", "{conditions}みたいな。", "{conditions}那种。"),
    "my_favorite": line("orders.my_favorite"),
    "your_call": line("orders.your_call"),
    "usual": line("orders.usual"),
}
GROUPS = {
    "enjoy": 'enjoy = ["请慢用。"]\n',
    **{f"orders.{p}": entry for p, entry in ORDERS.items()},
    "no_alcohol": line("no_alcohol"),
    **{f"reactions.{t}": line(f"reactions.{t}") for t in ("best", "right", "wrong")},
    **{f"farewells.{s}": line(f"farewells.{s}") for s in ("sober", "drunk")},
}


def lines_but(group: str, instead: str = "") -> str:
    """A file with a line in every group, `group`'s `instead`."""
    return "".join(instead if g == group else entry for g, entry in GROUPS.items())


EVERY_GROUP = lines_but("")


def test_lines_of_its_own_with_a_line_in_every_group_are_loaded(
    make_client: ClientFactory, characters: CharacterConfig
):
    characters.write(BAR_LINES_FILE, EVERY_GROUP)

    make_client(FakeLLM())


@pytest.mark.parametrize(
    ("lines", "named"),
    [
        (lines_but("enjoy"), "enjoy"),
        (lines_but("farewells.drunk"), r"farewells\.drunk"),
        (lines_but("enjoy", "enjoy = []\n"), "enjoy"),
        (EVERY_GROUP + line("orders.nmae", "{name_ja}で。", "{name}。"), "nmae"),
        (lines_but("orders.usual", line("orders.usual", "{name_ja}で。")), "usual.*name_ja"),
        (lines_but("orders.flavor", line("orders.flavor", "{taste}で。", "{flavor}。")), "taste"),
        (lines_but("orders.name", line("orders.name", "{name}で。", "{name}。")), r"orders\.name"),
        (lines_but("orders.kind", line("orders.kind", "それで。", "{kind}。")), r"\{kind\}"),
        (lines_but("orders.name", line("orders.name", "{name_ja で。", "{name}。")), "花括号"),
        (lines_but("reactions.best", line("reactions.best", zh="好\\n喝")), "best"),
        (lines_but("no_alcohol", line("no_alcohol") + 'emotion = "drunk"\n'), "drunk"),
        (lines_but("orders.your_call", line("orders.your_call", zh="Sugar Rush 吧。")), "Sugar"),
        (lines_but("orders.usual", line("orders.usual", "ＢＥＥＲで。")), "Beer"),
        (lines_but("orders.flavor", line("orders.flavor", "{flavor}、ラム酒。", "{flavor}")), "Rum"),
        (lines_but("enjoy", 'enjoy = ["请慢用 piano man。"]\n'), "enjoy.*Piano Man"),
        ("[[enjoy]\n", BAR_LINES_FILE),
    ],
    ids=[
        "no-enjoy", "no-drunk-farewell", "enjoy-empty", "phrasing-misspelt",
        "placeholder-where-none-go", "placeholder-unknown", "name-in-the-wrong-language",
        "placeholder-missing", "brace-unpaired", "two-lines", "emotion-unknown",
        "drink-named-in-english", "drink-named-full-width-in-another-case",
        "drink-named-in-japanese", "drink-named-by-the-producer", "not-toml",
    ],
)
def test_broken_lines_keep_the_backend_from_starting_naming_the_group(
    make_client: ClientFactory, characters: CharacterConfig, lines: str, named: str
):
    characters.write(BAR_LINES_FILE, lines)

    with pytest.raises(RuntimeError, match=named):
        make_client(FakeLLM())


def test_missing_lines_keep_the_backend_from_starting(
    make_client: ClientFactory, characters: CharacterConfig
):
    (characters.directory / BAR_LINES_FILE).unlink()

    with pytest.raises(RuntimeError, match=BAR_LINES_FILE):
        make_client(FakeLLM())
