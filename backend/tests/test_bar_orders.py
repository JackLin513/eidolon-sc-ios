"""How she orders at the bar (GLOSSARY.md「点单」), driven through the backend's external API:
the ways she says it, and when she can; what is right for each and what best, and how a
drink served wrong is; her wanting it without alcohol; the order memo; and the names in her
order, rewritten or replaced by a fixed line where they are not as they should be.

Mano is the only character: she likes what is sweet and girly, loves Sugar Rush, dislikes
what is bitter, and holds her drink well unless a test says otherwise. Each visit here is
of one drink, and none is done that day before it, so the random source is asked, coming
in: her reason and topic, how many drinks (0, one), her order's bucket (0 a favorite, 45
her liking, 80 any) and which of it, and how she says it (`says`); then what that way of
saying it draws; serving, the producer's fixed line. What she had before is written into
the visit records as visits done the day before."""

import asyncio
import json
import sqlite3
from collections.abc import Sequence
from dataclasses import replace
from pathlib import Path

import pytest

from eidolon.bar_lines import Phrasing, load_bar_lines
from eidolon.bar_rules import FLAVORS, KINDS, NAMING, PHRASINGS
from eidolon.config import Settings, UsageLimits
from eidolon.llm import LLMError
from tests.conftest import MANO_SHEET, REPO_BAR_LINES, CharacterConfig, ClientFactory
from tests.fakes import FakeLLM, FakeRandom
from tests.test_bar_draws import visit_rows
from tests.test_bar_visit import (
    CATALOG,
    MANO_TASTES,
    PARTING,
    VISITS,
    coming_in,
    enter,
    her,
    mano_alone,
    mixed,
    serve,
    streamed,
)
from tests.test_delete_account import user_id

LINES = load_bar_lines(REPO_BAR_LINES)

ALL: tuple[Phrasing, ...] = tuple(p for p, _ in PHRASINGS)
NOVICE: tuple[Phrasing, ...] = ("name", "name_big", "flavor", "kind", "your_call")
"""How a novice who has had no visit with her is asked for a drink with a big glass."""

QUIET = [her("こんばんは。", "晚上好。", "happy"), her("今日はね……", "今天嘛……", order=True)]
"""Her coming in and ordering without naming any drink."""

LAST_TIME = [
    {"target": "sparkle-star", "phrasing": "name", "served": "sparkle-star", "big": False, "tier": "right"},
    {"target": "blue-fairy", "phrasing": "name", "served": "brandtini", "big": False, "tier": "wrong"},
]
"""Her orders the last time: she wanted Sparkle Star and Blue Fairy."""


@pytest.fixture
def characters(tmp_path: Path) -> CharacterConfig:
    return mano_alone(tmp_path / "characters")


def holding(settings: Settings, tmp_path: Path, tolerance: str) -> Settings:
    """The settings with Mano holding her drink as `tolerance` says."""
    config = CharacterConfig(tmp_path / tolerance).add(
        "mano", "櫻木真乃", MANO_SHEET, birthday="04-25",
        bar=MANO_TASTES | {"bar_tolerance": tolerance},
    )
    return replace(settings, characters_path=config.path)


def says(phrasing: Phrasing, among: Sequence[Phrasing]) -> int:
    """The number that has her say her order `phrasing`, where she can say it any way
    `among`."""
    percents = dict(PHRASINGS)
    can: list[Phrasing] = [p for p in ALL if p in among]
    return sum(percents[p] for p in can[:can.index(phrasing)])


def entering(bucket: int, index: int, phrasing: int, *then: int) -> list[int]:
    """Coming in for one drink, her order drawn from `bucket` at `index`, said by
    `phrasing`, and `then` what that draws."""
    return [0, 0, 0, bucket, index, phrasing, *then]


def had_visits(settings: Settings, character: str, times: int, orders: list[dict]) -> None:
    """`times` visits done the day before with `character`, each of `orders`."""
    user = user_id(settings.database_path, "producer")
    with sqlite3.connect(settings.database_path) as db:
        for n in range(times):
            db.execute(
                "INSERT INTO visit_records (user_id, character_id, entered_at, left_at,"
                " entered_on, reason, topic, orders, drunk, rewarded)"
                " VALUES (?, ?, ?, ?, '2026-09-24', ?, ?, ?, 0, 0)",
                (
                    user, character, f"2026-09-24T1{n}:00:00+00:00",
                    f"2026-09-24T1{n}:30:00+00:00", f"reason-{n}", f"topic-{n}",
                    json.dumps(orders),
                ),
            )
    db.close()


def regular(settings: Settings) -> None:
    """Three visits with Mano done, the last of `LAST_TIME`: no novice."""
    had_visits(settings, "mano", 3, LAST_TIME)


def card(prompt: list) -> str:
    """The order card in a call's prompt."""
    return "点单卡：" + prompt[-1].content.split("点单卡：")[1]


def ordering(drink_id: str, phrasing: Phrasing) -> list[str]:
    """Her coming in and ordering as `phrasing` would have her: by the drink's name, or by
    no name at all."""
    return coming_in(drink_id) if phrasing in NAMING else QUIET


def memo_for(phrasing: Phrasing, drink_id: str) -> str:
    drink = CATALOG.drinks[drink_id]
    memos: dict[Phrasing, str] = {
        "name": f"她要 {drink.name}。", "name_big": f"她要 {drink.name}，大杯。",
        "flavor": f"她要{FLAVORS[drink.flavor]}的。", "kind": f"她要{KINDS[drink.kind]}的。",
        "conditions": f"她要{FLAVORS[drink.flavor]}的，大杯。", "analogy": "今天嘛……",
        "my_favorite": "她要她喜欢的。", "your_call": "她让你拿主意。", "usual": "她要上次那款。",
    }
    return memos[phrasing]


DRAWS: dict[Phrasing, tuple[int, ...]] = {"conditions": (0, 0, 0), "usual": (0,)}
"""What some ways of saying it draw: in conditions, the flavor and one more, the first she
may say (a big glass, for Sugar Rush); the usual, the first she wanted the last time."""


@pytest.mark.parametrize(
    ("history", "bucket", "index", "drink_id", "can"),
    [
        pytest.param({}, 0, 0, "sugar-rush", NOVICE, id="novice-never-with-her"),
        pytest.param(
            {"kogane": (3, LAST_TIME)}, 0, 0, "sugar-rush",
            ("name", "name_big", "flavor", "kind", "conditions", "analogy", "your_call"),
            id="three-visits-with-another",
        ),
        pytest.param({"mano": (3, LAST_TIME)}, 0, 0, "sugar-rush", ALL, id="a-regular-a-favorite"),
        pytest.param(
            {"mano": (3, LAST_TIME)}, 80, 3, "marsblast",  # past what she wanted the last time
            ("name", "flavor", "kind", "analogy", "your_call", "usual"),
            id="a-regular-a-drink-big-already-with-nothing-else-to-say",
        ),
        pytest.param(
            {"mano": (1, LAST_TIME)}, 45, 0, "fluffy-dream", NOVICE + ("usual",),
            id="a-novice-with-her-to-her-liking",
        ),
    ],
)
async def test_she_says_her_order_only_the_ways_she_can_for_it(
    make_client: ClientFactory,
    settings: Settings,
    history: dict[str, tuple[int, list[dict]]],
    bucket: int,
    index: int,
    drink_id: str,
    can: tuple[Phrasing, ...],
):
    llm = FakeLLM(*(ordering(drink_id, p) for p in can), ordering(drink_id, can[-1]))
    numbers = [
        *(n for p in can for n in entering(bucket, index, says(p, can), *DRAWS.get(p, ()))),
        *entering(bucket, index, sum(dict(PHRASINGS)[p] for p in can) - 1, *DRAWS.get(can[-1], ())),
    ]
    unlimited = replace(settings, usage_limits=UsageLimits(visits_per_hour=None))
    client = make_client(llm, settings=unlimited, random=FakeRandom(*numbers))
    for character, (times, orders) in history.items():
        had_visits(settings, character, times, orders)

    memos = [(await enter(client))[-2]["text"] for _ in range(len(can) + 1)]

    meant = ["sparkle-star" if p == "usual" else drink_id for p in can]
    assert memos == [memo_for(p, d) for p, d in zip(can, meant)] + [memos[len(can) - 1]]
    for prompt, drink in zip(llm.prompts, meant):
        told = card(prompt)
        assert f"- 饮品：{CATALOG.drinks[drink].name}（" in told
        others = [d for d in CATALOG.drinks.values() if d.id != drink]
        assert not [d.name for d in others if d.name in told or d.name_ja in told]
        assert "算对" not in told and "上得最好" not in told


NOT_REGULAR: tuple[Phrasing, ...] = tuple(p for p in ALL if p != "my_favorite")
"""How a regular is asked for a drink not one she loves, with a big glass."""

TIERS = {"best": "上得最好", "right": "上对了", "wrong": "上错了"}


@pytest.mark.parametrize(
    ("tolerance", "is_regular", "draws", "phrasing", "served", "tier", "wrong"),
    [
        # By name: Sugar Rush, in any glass, nothing best.
        pytest.param("strong", False, (0, 0), "name", mixed("sugar-rush"), "right", None, id="name-right"),
        pytest.param(
            "strong", False, (0, 0), "name", mixed("sugar-rush", big=True), "right", None,
            id="name-big-unasked-right",
        ),
        pytest.param("strong", False, (0, 0), "name", mixed("blue-fairy"), "wrong", "完全不对", id="name-wrong"),
        # By name and big: best big, right small.
        pytest.param(
            "strong", False, (0, 0), "name_big", mixed("sugar-rush", big=True), "best", None,
            id="name-big-best",
        ),
        pytest.param(
            "strong", False, (0, 0), "name_big", mixed("sugar-rush"), "right", None,
            id="name-big-small-right",
        ),
        pytest.param(
            "strong", False, (0, 0), "name_big", mixed("brandtini"), "wrong", "口味对了，种类不对",
            id="name-big-wrong",
        ),
        # By flavor, sweet (Sparkle Star): best the one she loves.
        pytest.param("strong", False, (45, 0), "flavor", mixed("sugar-rush"), "best", None, id="flavor-best"),
        pytest.param("strong", False, (45, 0), "flavor", mixed("brandtini"), "right", None, id="flavor-right"),
        pytest.param(
            "strong", False, (45, 0), "flavor", mixed("fluffy-dream"), "wrong", "种类对了，口味不对",
            id="flavor-wrong",
        ),
        # By kind, girly (Sparkle Star).
        pytest.param("strong", False, (45, 0), "kind", mixed("sugar-rush"), "best", None, id="kind-best"),
        pytest.param("strong", False, (45, 0), "kind", mixed("fluffy-dream"), "right", None, id="kind-right"),
        pytest.param(
            "strong", False, (45, 0), "kind", mixed("sunshine-cloud"), "wrong", "你讨厌的苦口味",
            id="kind-but-disliked",
        ),
        # In conditions: Moonblast, sweet and on ice, which none she loves is.
        pytest.param(
            "strong", True, (45, 1, 0, 0, 0), "conditions", mixed("moonblast"), "right", None,
            id="conditions-none-best",
        ),
        pytest.param(
            "strong", True, (45, 1, 0, 0, 0), "conditions", mixed("sugar-rush"), "wrong", "完全不对",
            id="conditions-not-on-ice",
        ),
        # In conditions: Sugar Rush, sweet and big.
        pytest.param(
            "strong", True, (0, 0, 0, 0, 0), "conditions", mixed("sugar-rush", big=True), "best", None,
            id="conditions-best",
        ),
        pytest.param(
            "strong", True, (0, 0, 0, 0, 0), "conditions", mixed("blue-fairy", big=True), "right", None,
            id="conditions-right",
        ),
        pytest.param(
            "strong", True, (0, 0, 0, 0, 0), "conditions", mixed("piano-woman"), "right", None,
            id="conditions-big-already",
        ),
        pytest.param(
            "strong", True, (0, 0, 0, 0, 0), "conditions", mixed("sugar-rush"), "wrong", "完全不对",
            id="conditions-small",
        ),
        # In conditions: Sugar Rush, sweet and without alcohol.
        pytest.param(
            "strong", True, (0, 0, 0, 0, 1), "conditions", {"method": "bottle", "bottle": "mulan-tea"},
            "right", None, id="conditions-without-alcohol-right",
        ),
        pytest.param(
            "strong", True, (0, 0, 0, 0, 1), "conditions", mixed("sugar-rush", karmotrine=1), "wrong",
            "你说了不要酒精", id="conditions-without-alcohol-wrong",
        ),
        # By an analogy: Sugar Rush alone, nothing best.
        pytest.param("strong", True, (0, 0), "analogy", mixed("sugar-rush"), "right", None, id="analogy-right"),
        pytest.param(
            "strong", True, (0, 0), "analogy", mixed("sparkle-star"), "wrong", "完全不对",
            id="analogy-wrong",
        ),
        # Her favorite: one she loves best; of a flavor she likes or of her kind right.
        pytest.param(
            "strong", True, (0, 0), "my_favorite", mixed("sugar-rush"), "best", None,
            id="my-favorite-best",
        ),
        pytest.param(
            "strong", True, (0, 0), "my_favorite", mixed("brandtini"), "right", None,
            id="my-favorite-her-flavor",
        ),
        pytest.param(
            "strong", True, (0, 0), "my_favorite", mixed("fluffy-dream"), "right", None,
            id="my-favorite-her-kind",
        ),
        pytest.param(
            "strong", True, (0, 0), "my_favorite", mixed("bad-touch"), "wrong", "完全不对",
            id="my-favorite-wrong",
        ),
        # Her call: anything right, but what she dislikes.
        pytest.param("strong", True, (0, 0), "your_call", mixed("sugar-rush"), "best", None, id="your-call-best"),
        pytest.param("strong", True, (0, 0), "your_call", mixed("piano-man"), "right", None, id="your-call-right"),
        pytest.param(
            "strong", True, (0, 0), "your_call", mixed("gut-punch"), "wrong", "你讨厌的苦口味",
            id="your-call-disliked",
        ),
        # The usual: any she wanted the last time, Sparkle Star or Blue Fairy, nothing best.
        pytest.param("strong", True, (0, 0, 1), "usual", mixed("blue-fairy"), "right", None, id="usual-right"),
        pytest.param(
            "strong", True, (0, 0, 1), "usual", mixed("sparkle-star"), "right", None,
            id="usual-the-other-right",
        ),
        pytest.param(
            "strong", True, (0, 0, 1), "usual", mixed("sugar-rush"), "wrong", "不是上次那款",
            id="usual-wrong",
        ),
        pytest.param(
            "strong", True, (0, 0, 1), "usual", mixed("brandtini"), "wrong", "不是上次那款",
            id="usual-wrong-before-flavor-only",
        ),
        # Wanting it without alcohol, as she does that holds her drink badly.
        pytest.param(
            "weak", False, (0, 0, 39), "name", mixed("sugar-rush"), "right", None,
            id="without-alcohol-right",
        ),
        pytest.param(
            "weak", False, (0, 0, 39), "name", mixed("sugar-rush", karmotrine=2), "wrong",
            "你说了不要酒精", id="without-alcohol-wrong",
        ),
        pytest.param(
            "weak", False, (0, 0, 39), "name", mixed("brandtini"), "wrong", "你说了不要酒精",
            id="without-alcohol-before-flavor-only",
        ),
        pytest.param(
            "weak", False, (0, 0, 0), "your_call", mixed("gut-punch", karmotrine=3), "wrong",
            "你讨厌的苦口味", id="disliked-before-without-alcohol",
        ),
    ],
)
async def test_each_way_of_ordering_is_judged_by_what_she_said(
    make_client: ClientFactory,
    settings: Settings,
    tmp_path: Path,
    tolerance: str,
    is_regular: bool,
    draws: tuple[int, ...],
    phrasing: Phrasing,
    served: dict,
    tier: str,
    wrong: str | None,
):
    bucket, index, *then = draws
    if is_regular:
        can = ALL if bucket == 0 else NOT_REGULAR
    else:
        can = NOVICE
    meant = {"usual": "blue-fairy", "flavor": "sparkle-star", "kind": "sparkle-star"}.get(
        phrasing, "moonblast" if (bucket, index) == (45, 1) else "sugar-rush"
    )
    llm = FakeLLM(ordering(meant, phrasing), PARTING)
    client = make_client(
        llm, settings=holding(settings, tmp_path, tolerance),
        random=FakeRandom(*entering(bucket, index, says(phrasing, can), *then), 0),
    )
    if is_regular:
        regular(settings)

    visit_id = (await enter(client))[0]["visit_id"]
    await serve(client, visit_id, served)

    [order] = json.loads(visit_rows(settings.database_path)[-1]["orders"])
    told = llm.prompts[-1][-1].content
    assert (order["target"], order["phrasing"], order["tier"]) == (meant, phrasing, tier)
    assert f"判定：{TIERS[tier]}" in told
    if wrong is None:
        assert "错在哪" not in told
    else:
        assert wrong in told and told.count("错在哪") == 1
    if wrong in ("你讨厌的苦口味", "你说了不要酒精"):
        assert "要写成明显的不喜欢" in told


@pytest.mark.parametrize(
    ("tolerance", "bucket", "index", "phrasing", "chance", "without"),
    [
        pytest.param("weak", 0, 0, "name", 39, True, id="weak-two-in-five"),
        pytest.param("weak", 0, 0, "name", 40, False, id="weak-not-the-rest"),
        pytest.param("medium", 0, 0, "name", 9, True, id="medium-one-in-ten"),
        pytest.param("medium", 0, 0, "name", 10, False, id="medium-not-the-rest"),
        pytest.param("strong", 0, 0, "name", None, False, id="strong-never"),
        pytest.param("weak", 45, 3, "name", None, False, id="not-for-a-drink-always-with-alcohol"),
        pytest.param("weak", 0, 0, "usual", None, False, id="not-for-the-usual"),
    ],
)
async def test_she_that_holds_her_drink_badly_may_want_it_without_alcohol(
    make_client: ClientFactory,
    settings: Settings,
    tmp_path: Path,
    tolerance: str,
    bucket: int,
    index: int,
    phrasing: Phrasing,
    chance: int | None,
    without: bool,
):
    can = ALL if phrasing == "usual" else NOVICE
    then = (0,) if phrasing == "usual" else () if chance is None else (chance,)
    meant = {"usual": "sparkle-star"}.get(phrasing, "sugar-rush" if bucket == 0 else "moonblast")
    llm = FakeLLM(ordering(meant, phrasing))
    client = make_client(
        llm, settings=holding(settings, tmp_path, tolerance),
        random=FakeRandom(*entering(bucket, index, says(phrasing, can), *then)),
    )
    if phrasing == "usual":
        regular(settings)

    came = await enter(client)

    name = CATALOG.drinks[meant].name
    expected = memo_for(phrasing, meant)
    if without:
        expected = f"她要 {name}，不要酒精。"
    assert came[-2] == {"type": "memo", "text": expected}
    assert ("- 要提的条件：不要酒精。" in card(llm.prompts[0])) is without


NAMED_WRONGLY = [
    pytest.param(her("シュガーラッシュみたいなの。", "像那种的。", order=True), id="japanese-name"),
    pytest.param(her("甘いの。", "像 Sugar Rush 那种甜的。", order=True), id="english-name"),
    pytest.param(her("甘いの。", "像 sugar rush 那种甜的。", order=True), id="any-case"),
    pytest.param(her("甘いの。", "像ＳＵＧＡＲ　ＲＵＳＨ那种甜的。", order=True), id="full-width"),
    pytest.param(her("ピアノマンみたいなの。", "像那种的。", order=True), id="japanese-name-unspaced"),
    pytest.param(her("ピアノ・マンみたいなの。", "像那种的。", order=True), id="japanese-name-dotted"),
    pytest.param(her("ムーンブラストじゃないの。", "不要那种的。", order=True), id="another-drink"),
]


@pytest.mark.parametrize("named", NAMED_WRONGLY)
async def test_her_order_naming_a_drink_where_it_should_not_is_rewritten(
    make_client: ClientFactory, named: str
):
    rewritten = her("甘いのを一杯。", "来杯甜的。", "happy", order=True)
    llm = FakeLLM([QUIET[0], named], [rewritten])
    client = make_client(llm, random=FakeRandom(*entering(0, 0, says("flavor", NOVICE))))

    came = await enter(client)

    first, again = llm.prompts
    assert again[:-1] == first[:-1]
    assert again[-1].content.startswith(first[-1].content)
    assert f"这次前面已经写好了这些，不用再写：\n{QUIET[0]}" in again[-1].content
    assert "只重写点单的那一两句" in again[-1].content
    assert "不要提任何饮品的名字" in again[-1].content
    assert came[1:] == [
        {"type": "line", "speaker": "her", "emotion": "happy", "ja": "こんばんは。", "zh": "晚上好。"},
        {
            "type": "line", "speaker": "her", "emotion": "happy", "ja": "甘いのを一杯。",
            "zh": "来杯甜的。", "order": True,
        },
        {"type": "memo", "text": "她要甜的。"},
        {"type": "waiting"},
    ]


async def test_only_her_order_is_checked_for_names(make_client: ClientFactory):
    llm = FakeLLM([her("シュガーラッシュ、好きなんだ。", "我喜欢 Sugar Rush。"), QUIET[1]])
    client = make_client(llm, random=FakeRandom(*entering(0, 0, says("flavor", NOVICE))))

    came = await enter(client)

    assert len(llm.prompts) == 1
    assert came[-2] == {"type": "memo", "text": "她要甜的。"}


@pytest.mark.parametrize(
    ("named", "rewritten"),
    [
        pytest.param(her("それで。", "就那个。", order=True), True, id="neither"),
        pytest.param(her("それで。", "sugar rush，麻烦了。", order=True), False, id="in-chinese-any-case"),
        pytest.param(her("シュガーラッシュで。", "就那个。", order=True), False, id="in-japanese"),
        pytest.param(her("ｼｭｶﾞｰﾗｯｼｭで。", "就那个。", order=True), False, id="in-half-width-japanese"),
    ],
)
async def test_her_order_by_name_must_name_the_drink_in_one_tongue_or_the_other(
    make_client: ClientFactory, named: str, rewritten: bool
):
    good = her("シュガーラッシュ、お願い。", "Sugar Rush，麻烦了。", order=True)
    llm = FakeLLM([QUIET[0], named], [good])
    client = make_client(llm, random=FakeRandom(*entering(0, 0, says("name", NOVICE))))

    came = await enter(client)

    assert len(llm.prompts) == (2 if rewritten else 1)
    if rewritten:
        assert "一定要说出名字：日语台词里说「シュガーラッシュ」，中文字幕里写「Sugar Rush」" in (
            llm.prompts[1][-1].content
        )
        assert came[2]["zh"] == "Sugar Rush，麻烦了。"
    assert came[-2] == {"type": "memo", "text": "她要 Sugar Rush。"}


def fixed(phrasing: Phrasing, **filled: str) -> dict:
    """Her order as the first fixed line for `phrasing` says it, with `filled` in."""
    line = LINES.orders[phrasing][0]
    ja = {k.removesuffix("_in_ja"): v for k, v in filled.items() if k.endswith("_in_ja")}
    zh = {k: v for k, v in filled.items() if not k.endswith("_in_ja")}
    return {
        "type": "line", "speaker": "her", "emotion": line.emotion, "ja": line.ja.format(**ja),
        "zh": line.zh.format(**zh), "order": True,
    }


def without_alcohol() -> dict:
    line = LINES.no_alcohol[0]
    return {
        "type": "line", "speaker": "her", "emotion": line.emotion, "ja": line.ja, "zh": line.zh,
        "order": True,
    }


async def test_her_order_wrong_twice_is_said_in_a_fixed_line(make_client: ClientFactory):
    wrong = [her("それで。", "就那个。", order=True)]
    llm = FakeLLM([QUIET[0], *wrong], wrong)
    client = make_client(llm, random=FakeRandom(*entering(0, 0, says("name", NOVICE)), 0))

    came = await enter(client)

    assert came[2:] == [
        fixed("name", name_ja_in_ja="シュガーラッシュ", name="Sugar Rush"),
        {"type": "memo", "text": "她要 Sugar Rush。"},
        {"type": "waiting"},
    ]


async def test_a_fixed_line_where_she_wants_it_without_alcohol_says_so(
    make_client: ClientFactory, settings: Settings, tmp_path: Path
):
    llm = FakeLLM([her("シュガーラッシュで。", "Sugar Rush。", order=True)], LLMError("down"))
    client = make_client(
        llm, settings=holding(settings, tmp_path, "weak"),
        random=FakeRandom(*entering(0, 0, says("flavor", NOVICE), 0), 0, 0),
    )

    came = await enter(client)

    assert came[1:] == [
        fixed("flavor", flavor_in_ja="甘いの", flavor="甜的"),
        without_alcohol(),
        {"type": "memo", "text": "她要甜的，不要酒精。"},
        {"type": "waiting"},
    ]


async def test_a_fixed_line_in_conditions_says_them_all(
    make_client: ClientFactory, settings: Settings
):
    named = [her("シュガーラッシュで。", "Sugar Rush。", order=True)]
    llm = FakeLLM(named, named)
    client = make_client(llm, random=FakeRandom(*entering(0, 0, says("conditions", ALL), 0, 0, 1), 0))
    regular(settings)

    came = await enter(client)

    assert came[1:] == [
        fixed("conditions", conditions_in_ja="甘いの、アルコール抜き", conditions="甜的、不要酒精"),
        {"type": "memo", "text": "她要甜的，不要酒精。"},
        {"type": "waiting"},
    ]


async def test_an_analogy_wrong_twice_is_said_and_judged_as_its_flavor_and_kind(
    make_client: ClientFactory, settings: Settings
):
    named = [her("シュガーラッシュみたいな。", "像 Sugar Rush 那样的。", order=True)]
    llm = FakeLLM(named, named, PARTING)
    client = make_client(llm, random=FakeRandom(*entering(0, 0, says("analogy", ALL)), 0, 0))
    regular(settings)

    came = await enter(client)
    await serve(client, came[0]["visit_id"], mixed("sparkle-star"))  # sweet and girly too

    assert came[1:] == [
        fixed("analogy", conditions_in_ja="甘いの、かわいい系の", conditions="甜的、女性化的"),
        {"type": "memo", "text": "她要甜的，女性化的。"},
        {"type": "waiting"},
    ]
    [order] = json.loads(visit_rows(settings.database_path)[-1]["orders"])
    assert (order["phrasing"], order["target"], order["tier"]) == ("conditions", "sugar-rush", "right")
    assert "判定：上对了" in llm.prompts[-1][-1].content


async def test_an_analogy_is_noted_as_she_said_it_once_it_names_no_drink(
    make_client: ClientFactory, settings: Settings
):
    llm = FakeLLM(
        [her("シュガーラッシュっぽいの。", "像 Sugar Rush 那样的。", order=True)],
        [her("甘くて、果物っぽくて。", "甜甜的，有水果味。", order=True)],
    )
    client = make_client(llm, random=FakeRandom(*entering(0, 0, says("analogy", ALL))))
    regular(settings)

    came = await enter(client)

    assert came[-2] == {"type": "memo", "text": "甜甜的，有水果味。"}
    told = card(llm.prompts[0])
    assert f"- 描述：{CATALOG.drinks['sugar-rush'].description}" in told
    assert "不能说出来" in told


async def test_her_order_is_held_back_until_it_is_named_as_it_should_be(make_client: ClientFactory):
    rewriting = asyncio.Event()
    llm = FakeLLM(
        [QUIET[0], her("シュガーラッシュ。", "Sugar Rush。", order=True)],
        [rewriting, her("甘いの。", "甜的。", order=True)],
    )
    client = make_client(llm, random=FakeRandom(*entering(0, 0, says("flavor", NOVICE))))

    async def rewrite_asked() -> None:
        while len(llm.prompts) < 2:
            await asyncio.sleep(0.01)

    came, request = await streamed(client, VISITS, {}, until="line")
    await asyncio.wait_for(rewrite_asked(), timeout=5)
    await asyncio.sleep(0.05)
    before = list(came)
    rewriting.set()
    await request

    assert [e["type"] for e in before] == ["visit", "line"]
    assert not any(e.get("order") for e in before)
    assert [e.get("zh") for e in came[2:4]] == ["甜的。", None]
    assert "Sugar Rush" not in json.dumps(came, ensure_ascii=False)
