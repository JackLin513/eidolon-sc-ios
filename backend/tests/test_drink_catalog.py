"""The drink catalog (GLOSSARY.md「饮品」「材料」) comes from configuration beside the
characters', as the gift catalog does: the original's 28 drinks, checked as the backend
starts. What the bar counter holds as a drink is served is matched against it, exactly: a
drink, big or not, with how many parts of Karmotrine are in it; or broken, not to be
served."""

import re
from dataclasses import replace

import pytest

from eidolon.characters import load_characters
from eidolon.drink_catalog import DRINKS_FILE, Mixture, check_bar_tastes, load_drink_catalog

from tests.conftest import BAR_TASTE, REPO_DRINKS, CharacterConfig, ClientFactory
from tests.fakes import FakeLLM

CATALOG = load_drink_catalog(REPO_DRINKS)

SUGAR_RUSH = Mixture(2, 0, 1, 0, 0, ice=False, aged=False, method="mix")
"""As its recipe card has it, with no Karmotrine."""


def test_each_mixed_drinks_recipe_is_that_drink_not_big():
    for drink in CATALOG.mixed():
        recipe = drink.recipe
        assert recipe is not None
        mixture = Mixture(
            recipe.adelhyde, recipe.bronson_extract, recipe.powdered_delta, recipe.flanergide,
            recipe.karmotrine or 0, ice=recipe.ice, aged=recipe.aged, method=recipe.method,
        )

        served = CATALOG.match(mixture)

        assert served is not None, drink.id
        assert (served.drink.id, served.big) == (drink.id, False)


BIG_ALREADY = {"marsblast", "zen-star", "piano-man", "piano-woman"}


def test_each_mixed_drinks_recipe_doubled_is_its_big_glass_unless_it_is_big_already():
    for drink in CATALOG.mixed():
        recipe = drink.recipe
        assert recipe is not None
        doubled = Mixture(
            recipe.adelhyde * 2, recipe.bronson_extract * 2, recipe.powdered_delta * 2,
            recipe.flanergide * 2, (recipe.karmotrine or 0) * 2,
            ice=recipe.ice, aged=recipe.aged, method=recipe.method,
        )

        served = CATALOG.match(doubled)

        if drink.id in BIG_ALREADY:
            assert served is None, drink.id
        else:
            assert served is not None, drink.id
            assert (served.drink.id, served.big) == (drink.id, True)
    assert {d.id for d in CATALOG.mixed() if d.recipe and d.recipe.big} == BIG_ALREADY


def test_optional_karmotrine_is_the_same_drink_however_much_and_alcoholic_by_how_much():
    big_sugar_rush = Mixture(4, 0, 2, 0, 0, ice=False, aged=False, method="mix")
    glasses = [
        SUGAR_RUSH,
        Mixture(2, 0, 1, 0, 17, ice=False, aged=False, method="mix"),
        big_sugar_rush,
        Mixture(4, 0, 2, 0, 5, ice=False, aged=False, method="mix"),
    ]

    served = [CATALOG.match(g) for g in glasses]

    assert [(s.drink.id, s.big, s.karmotrine, s.alcoholic) for s in served if s] == [
        ("sugar-rush", False, 0, False),
        ("sugar-rush", False, 17, True),
        ("sugar-rush", True, 0, False),
        ("sugar-rush", True, 5, True),
    ]


def test_a_fixed_karmotrine_drinks_glass_has_its_parts_doubled_in_the_big_glass():
    beer = Mixture(1, 2, 1, 2, 4, ice=False, aged=False, method="mix")
    big_beer = Mixture(2, 4, 2, 4, 8, ice=False, aged=False, method="mix")
    frothy_water = Mixture(1, 1, 1, 1, 0, ice=False, aged=True, method="mix")

    served = [CATALOG.match(g) for g in (beer, big_beer, frothy_water)]

    assert [(s.drink.id, s.big, s.karmotrine, s.alcoholic) for s in served if s] == [
        ("beer", False, 4, True), ("beer", True, 8, True), ("frothy-water", False, 0, False),
    ]


def test_a_part_the_ice_or_the_method_off_is_broken_and_the_ageing_off_another_drink_or_broken():
    bad_touch = Mixture(0, 2, 2, 2, 4, ice=True, aged=False, method="mix")
    off = [
        replace(bad_touch, adelhyde=1),
        replace(bad_touch, karmotrine=5),
        replace(bad_touch, ice=False),
        replace(bad_touch, aged=True),
        replace(bad_touch, method="blend"),
    ]

    assert CATALOG.match(bad_touch) is not None
    assert [CATALOG.match(m) for m in off] == [None] * len(off)
    sparkle_star = CATALOG.match(replace(SUGAR_RUSH, aged=True))
    assert sparkle_star is not None and sparkle_star.drink.id == "sparkle-star"


def test_flaming_moai_more_than_the_mixer_holds_and_parts_not_counted_from_0_are_broken():
    broken = {
        "flaming moai": Mixture(1, 1, 2, 3, 5, ice=False, aged=False, method="mix"),
        "overfilled": replace(SUGAR_RUSH, karmotrine=18),
        "less than none": replace(SUGAR_RUSH, karmotrine=-1),
        "not a whole number": replace(SUGAR_RUSH, karmotrine=True),
    }

    for name, mixture in broken.items():
        assert CATALOG.match(mixture) is None, name


def test_a_bottled_drink_is_served_by_its_id_with_its_parts_of_karmotrine():
    served = [CATALOG.match(id) for id in ("absinthe", "rum", "a-fedora", "mulan-tea")]

    assert [(s.drink.id, s.big, s.karmotrine, s.alcoholic) for s in served if s] == [
        ("absinthe", False, 6, True), ("rum", False, 6, True),
        ("a-fedora", False, 3, True), ("mulan-tea", False, 0, False),
    ]
    assert (CATALOG.match("sugar-rush"), CATALOG.match("flaming-moai")) == (None, None)


def test_the_repositorys_catalog_has_the_originals_24_mixed_drinks_and_4_bottled():
    bottled = [d.id for d in CATALOG.drinks.values() if d.recipe is None]

    assert (len(CATALOG.mixed()), bottled) == (24, ["absinthe", "rum", "mulan-tea", "a-fedora"])
    piano_man, beer = CATALOG.drinks["piano-man"], CATALOG.drinks["beer"]
    assert (piano_man.flavor, beer.kind) == ("sour", "classic")
    assert sorted(d.page or 0 for d in CATALOG.mixed()) == list(range(1, 25))
    assert all(d.description for d in CATALOG.drinks.values())
    assert {
        d.id for d in CATALOG.mixed() if d.recipe and d.recipe.karmotrine is None
    } == {
        "sugar-rush", "sparkle-star", "blue-fairy", "fluffy-dream", "sunshine-cloud",
        "gut-punch", "crevice-spike",
    }


def mixed(
    id: str, parts: str = "2, 0, 1, 0", karmotrine: str = '"optional"', *, ice: str = "false",
    aged: str = "false", method: str = "mix", flavor: str = "sweet", extra: str = "",
) -> str:
    """A mixed drink's [[drinks]] entry; its parts are of the four ingredients but Karmotrine."""
    a, b, d, f = (p.strip() for p in parts.split(","))
    return (
        f'[[drinks]]\nid = "{id}"\nname = "{id}"\nname_ja = "{id}"\nshort_name = "{id}"\n'
        f'flavor = "{flavor}"\nkind = "girly"\nadelhyde = {a}\nbronson_extract = {b}\n'
        f"powdered_delta = {d}\nflanergide = {f}\nkarmotrine = {karmotrine}\n"
        f'ice = {ice}\naged = {aged}\nmethod = "{method}"\npage = 1\ndescription = "描述"\n{extra}'
    )


def bottled(id: str, karmotrine: str = "6", extra: str = "") -> str:
    return (
        f'[[drinks]]\nid = "{id}"\nname = "{id}"\nname_ja = "{id}"\nshort_name = "{id}"\n'
        f'flavor = "sour"\nkind = "classic"\nmethod = "bottle"\nkarmotrine = {karmotrine}\n'
        f'description = "小字"\n{extra}'
    )


def test_a_small_catalog_of_its_own_is_loaded(make_client: ClientFactory, characters: CharacterConfig):
    """With the drink the characters love in it."""
    characters.write(DRINKS_FILE, mixed("sugar-rush") + bottled("bottle"))

    make_client(FakeLLM())


@pytest.mark.parametrize(
    ("catalog", "named"),
    [
        (mixed("sweet-one") + mixed("sweet-one", aged="true"), "sweet-one"),
        (mixed("Sweet One"), "Sweet One"),
        (mixed("sweet-one").replace('name_ja = "sweet-one"\n', ""), "name_ja"),
        (mixed("sweet-one").replace("page = 1\n", ""), "page"),
        (mixed("sweet-one", parts="21, 0, 0, 0", karmotrine="0"), "sweet-one"),
        (mixed("sweet-one", parts="10, 0, 0, 0", karmotrine="11", extra="big = true\n"), "20"),
        (mixed("sweet-one", parts="6, 0, 5, 0", karmotrine="0"), "翻倍"),
        (mixed("sweet-one", karmotrine='"some"'), "some"),
        (mixed("sweet-one", ice='"yes"'), "ice"),
        (mixed("sweet-one", flavor="salty"), "salty"),
        (bottled("bottle", extra="adelhyde = 1\n"), "adelhyde"),
        (bottled("bottle", karmotrine='"optional"'), "bottle"),
        (mixed("sweet-one", parts="0, 0, 0, 0"), "sweet-one"),
        ('drinks = ["sweet-one"]\n', "drinks"),
        ("[[drinks]\n", DRINKS_FILE),
    ],
)
def test_a_broken_catalog_keeps_the_backend_from_starting_naming_what_is_wrong(
    make_client: ClientFactory, characters: CharacterConfig, catalog: str, named: str
):
    characters.write(DRINKS_FILE, catalog)

    with pytest.raises(RuntimeError, match=named):
        make_client(FakeLLM())


@pytest.mark.parametrize(
    "catalog",
    [
        mixed("one", karmotrine="2") + mixed("two", karmotrine="2", flavor="sour"),
        mixed("one", karmotrine="2") + mixed("two", karmotrine='"optional"'),
        mixed("one", parts="2, 0, 1, 0", karmotrine="1") + mixed("two", parts="4, 0, 2, 0", karmotrine="2"),
        mixed("one", parts="2, 0, 1, 0") + mixed("two", parts="4, 0, 2, 0", karmotrine="3"),
        mixed("one", parts="1, 1, 0, 0", karmotrine="1")
        + mixed("two", parts="2, 2, 0, 0", karmotrine='"optional"', extra="big = true\n"),
    ],
    ids=["same", "optional-karmotrine", "doubled", "doubled-optional", "doubled-big"],
)
def test_two_drinks_one_mixture_could_be_either_of_keep_the_backend_from_starting(
    make_client: ClientFactory, characters: CharacterConfig, catalog: str
):
    characters.write(DRINKS_FILE, catalog)

    with pytest.raises(RuntimeError, match="one.*two|two.*one"):
        make_client(FakeLLM())


def test_a_missing_catalog_keeps_the_backend_from_starting(
    make_client: ClientFactory, characters: CharacterConfig
):
    (characters.directory / DRINKS_FILE).unlink()

    with pytest.raises(RuntimeError, match=DRINKS_FILE):
        make_client(FakeLLM())


HIORI_SHEET = "# 人设\n你是風野灯織。"


@pytest.mark.parametrize(
    ("bar", "named"),
    [
        ({"bar_flavors": ["sweet"], "bar_tolerance": "weak"}, "bar_favorites"),
        ({"bar_flavors": ["sweet"], "bar_favorites": ["sugar-rush"]}, "bar_tolerance"),
    ],
    ids=["favorites", "tolerance"],
)
def test_bar_tastes_missing_what_is_required_keep_the_backend_from_starting(
    make_client: ClientFactory, characters: CharacterConfig, bar: dict[str, object], named: str
):
    characters.add("hiori", "風野灯織", HIORI_SHEET, bar=bar)

    with pytest.raises(RuntimeError, match=f"hiori.*{named}"):
        make_client(FakeLLM())


@pytest.mark.parametrize(
    ("wrong", "named"),
    [
        ({"bar_favorites": ["sugar-rush", "flaming-moai"]}, "flaming-moai"),
        ({"bar_favorites": ["sugar-rush", "beer", "rum", "absinthe"]}, "最多 3 个"),
        ({"bar_flavors": ["salty"]}, "salty"),
        ({"bar_disliked_flavor": "sweet"}, "bar_disliked_flavor"),
        ({"bar_favorites": ["sugar-rush", "rum"], "bar_disliked_flavor": "bitter"}, "rum"),
        ({"bar_flavors": "sweet"}, "bar_flavors"),
    ],
    ids=[
        "favorite-not-in-catalog", "too-many-favorites", "flavor-misspelt", "disliked-also-liked",
        "favorite-disliked", "flavors-not-a-list",
    ],
)
def test_bar_tastes_not_right_by_the_catalog_keep_the_backend_from_starting(
    make_client: ClientFactory, characters: CharacterConfig, wrong: dict[str, object], named: str
):
    characters.add("hiori", "風野灯織", HIORI_SHEET, bar=BAR_TASTE | wrong)

    with pytest.raises(RuntimeError, match=f"hiori.*{named}"):
        make_client(FakeLLM())


def test_repository_characters_each_have_bar_tastes_with_a_reason_for_each_in_her_sources():
    """Her sources file's 「酒吧口味」 has a line for each flavor, kind, loved drink, disliked
    flavor and tolerance she has, in the order `characters.toml` has them."""
    characters = load_characters(REPO_DRINKS.parent / "characters.toml")

    check_bar_tastes(characters, CATALOG)
    for id, c in characters.items():
        sources = (REPO_DRINKS.parent / "facts" / f"{id}.sources.md").read_text(encoding="utf-8")
        section = sources.split("\n## 酒吧口味\n", 1)[1].split("\n## ", 1)[0]
        reasons = re.findall(r"^- (口味|种类|爱喝|讨厌|酒量) ([a-z-]+)[（：]", section, re.M)
        assert reasons == [
            *(("口味", f) for f in c.bar_flavors),
            *([("种类", c.bar_kind)] if c.bar_kind else []),
            *(("爱喝", d) for d in c.bar_favorites),
            *([("讨厌", c.bar_disliked_flavor)] if c.bar_disliked_flavor else []),
            ("酒量", c.bar_tolerance),
        ], id
