"""开发用：用部署者的对话模型完整走一次光顾，把每句台词打印出来看措辞（规格「开发用的终端脚本」）。

只给维护者用，不进 `eidolon` 命令。照 `.env` 搭起整个后端，但库是临时目录里新建的，不碰真库；
酒吧是脚本自己造的，不带好感度和礼物，所以不发奖励。服务器照常抽来意、话题、点单，脚本只在
这几处插手：

- 谁来（`--character`，默认随机）、几杯（`--cups`，默认照常抽；`--drunk` 时默认 3 杯）；
- 每一单的说法、上成哪一档、上错时错在哪（`--phrasing`、`--tier`、`--wrong`，逗号分开，按杯排，
  `any` 是这一杯随机）：服务器照常抽点单，抽到不合要求的就重抽；
- 制作人上什么：脚本替他挑一款判定合要求的，`--drunk` 时挑 Karmotrine 最多的，能选
  Karmotrine 的直接加满；不醉的时候尽量不让她喝醉；
- 以前来过几次（`--visits`，默认 3 次，最后一次是三天前，喝的是合她口味、不是她爱喝的一款）：0 次是新手，
  不会有几个条件叠加、打比方、「来杯我喜欢的」和「老样子」；
- `--break-farewell` 让告别那次调用连着失败，换成写死的兜底句。

打印每句台词（说话人、情绪、日语、中文）、点单备忘、每单名字检查重写了几次、有没有换成写死的
点单句，最后列出每次调用的用量和用时。

    cd backend
    set -a; . ../.env; set +a
    export EIDOLON_CHARACTERS_PATH=../characters/characters.toml PYTHONIOENCODING=utf-8
    uv run python scripts/bar_visit.py --character mano --phrasing name,name_big,flavor \\
        --tier right,best,wrong --wrong any,any,disliked > E:/tmp/bar-wording/01.txt

换模型：命令前加 `CHAT_LLM_MODEL=...`（和别的 `CHAT_LLM_*`）。
"""

import argparse
import asyncio
import json
import logging
import sqlite3
import sys
import tempfile
import time
from itertools import zip_longest
from collections.abc import Sequence
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta
from pathlib import Path
from random import Random as Seeded
from typing import get_args

import eidolon.bar as bar_module
from eidolon.assembly import build
from eidolon.bar import (
    Bar,
    BarCall,
    BarEvent,
    Memo,
    Retrying,
    VisitBegan,
    VisitDone,
    VisitFailed,
    Waiting,
)
from eidolon.bar_lines import BarLines, Phrasing, Tier, bar_lines_path, load_bar_lines
from eidolon.bar_reply import BarLine
from eidolon.bar_rules import DRUNK_AT, FLAVORS, KINDS, Known, Order, Serving, Wrong, judged
from eidolon.bar_visits import bar_visits_path, load_bar_visits
from eidolon.characters import Character
from eidolon.config import Settings
from eidolon.drink_catalog import (
    MAX_PARTS,
    Drink,
    DrinkCatalog,
    Mixture,
    Served,
    drinks_path,
    load_drink_catalog,
)
from eidolon.llm import ChatLLM, LLMError
from eidolon.own_keys import BroughtKeys
from eidolon.randomness import Random

PHRASINGS: tuple[Phrasing, ...] = get_args(Phrasing)
TIERS: tuple[Tier, ...] = get_args(Tier)
WRONGS: tuple[Wrong, ...] = get_args(Wrong)

_TIERS_SAID: dict[Tier, str] = {"best": "上得最好", "right": "上对", "wrong": "上错"}

REDRAWS = 5000
"""抽多少次点单还抽不到合要求的，就算这一杯要不到。"""

RETRIES = 2
"""一次调用失败停住以后，脚本替制作人「再试一次」最多几次。"""


@dataclass(frozen=True)
class Cup:
    """对一杯的要求：说法、档位、上错时错在哪；None 是随机。"""

    phrasing: Phrasing | None = None
    tier: Tier | None = None
    wrong: Wrong | None = None


@dataclass
class Plan:
    cups: list[Cup]
    drunk: bool
    had: int = 0
    """这次光顾到现在上过的 Karmotrine 份数。"""

    def of(self, cup: int) -> Cup:
        return self.cups[cup] if cup < len(self.cups) else Cup()


@dataclass
class CallLog:
    """一次调用里脚本数下来的东西。"""

    rewrites: int = 0
    fixed_order: bool = False
    fixed_farewell: bool = False


@dataclass
class Tally:
    calls: list[CallLog] = field(default_factory=list)

    @property
    def current(self) -> CallLog:
        """正在读的这次调用的。"""
        return self.calls[-1]


class DevBar(Bar):
    """酒吧，多出数重写次数、故意弄坏告别调用、看正在进行的光顾这几样。"""

    def __init__(self, *args, tally: Tally, break_farewell: bool, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.tally = tally
        self.break_farewell = break_farewell

    def under_way(self, user_id: str):
        return self._visits.get(user_id)

    async def _rewritten(self, visit, chat: ChatLLM, ask: str) -> list[BarLine]:
        self.tally.current.rewrites += 1
        return await super()._rewritten(visit, chat, ask)

    async def _attempt(self, visit, ask: str, ordering: bool, said: list[BarLine]):
        if self.break_farewell and not ordering:
            raise LLMError("脚本故意弄坏了告别这次调用")
        async for line in super()._attempt(visit, ask, ordering, said):
            yield line


def glasses(catalog: DrinkCatalog, drunk: bool) -> list[tuple[Served, Mixture | str]]:
    """制作人能上的每一杯，和它在吧台上是怎么调的：瓶装的按名字；调制的照配方，原杯和大杯，
    能选 Karmotrine 的不加和加（`drunk` 时加满，否则加 1 份）。"""
    out: list[tuple[Served, Mixture | str]] = []
    for drink in catalog.drinks.values():
        recipe = drink.recipe
        if recipe is None:
            out.append((Served(drink, False, drink.bottled_karmotrine), drink.id))
            continue
        for big in (False, True) if not recipe.big else (False,):
            times = 2 if big else 1
            parts = (
                recipe.adelhyde * times, recipe.bronson_extract * times,
                recipe.powdered_delta * times, recipe.flanergide * times,
            )
            if recipe.karmotrine is not None:
                amounts = [recipe.karmotrine * times]
            else:
                amounts = [0, MAX_PARTS - sum(parts) if drunk else 1]
            for karmotrine in amounts:
                mixture = Mixture(*parts, karmotrine, recipe.ice, recipe.aged, recipe.method)
                out.append((Served(drink, big, karmotrine), mixture))
    return out


def servings_for(
    order: Order, cup: Cup, character: Character, catalog: DrinkCatalog, drunk: bool
) -> list[tuple[Serving, Mixture | str]]:
    """能上给这一单、又合 `cup` 档位要求的每一杯，和怎么调。"""
    out = []
    for served, made in glasses(catalog, drunk):
        serving = judged(order, served, character)
        if cup.tier is not None and serving.tier != cup.tier:
            continue
        if cup.wrong is not None and serving.wrong != cup.wrong:
            continue
        out.append((serving, made))
    return out


def order_fits(
    order: Order, cup: Cup, character: Character, catalog: DrinkCatalog, plan: Plan
) -> bool:
    """这一单合不合 `cup` 的要求：说法对，有合档位的一杯能上；要醉的话不是不要酒精的，
    不醉的话有一杯上了她还不醉。"""
    if cup.phrasing is not None and order.phrasing != cup.phrasing:
        return False
    if plan.drunk and "no_alcohol" in order.said and cup.wrong != "alcohol":
        return False
    candidates = servings_for(order, cup, character, catalog, plan.drunk)
    if not plan.drunk:
        return any(_keeps_sober(character, plan.had, s) for s, _ in candidates)
    return bool(candidates)


def _drunk_at(her: Character) -> int | None:
    """她喝到几份 Karmotrine 就醉；没写酒量的不醉。"""
    return DRUNK_AT.get(her.bar_tolerance or "")


def _keeps_sober(her: Character, had: int, serving: Serving) -> bool:
    """已经喝了 `had` 份，再上这一杯她还不醉。"""
    at = _drunk_at(her)
    return at is None or had + serving.served.karmotrine < at


def steer(plan: Plan, cups: int | None, character_index: int) -> None:
    """让 `eidolon.bar` 抽谁来、几杯、点单时照 `plan` 来。"""
    drawing = bar_module.draw_order
    drawing_cups = bar_module.cups

    def draw_order(
        character: Character, catalog: DrinkCatalog, random: Random, ordered: Sequence[str],
        known: Known,
    ) -> Order:
        cup = plan.of(len(ordered))
        for _ in range(REDRAWS):
            order = drawing(character, catalog, random, ordered, known)
            if order_fits(order, cup, character, catalog, plan):
                return order
        raise SystemExit(f"第 {len(ordered) + 1} 杯抽了 {REDRAWS} 次也抽不到合要求的点单：{cup}")

    bar_module.draw_order = draw_order
    bar_module.cups = (lambda random: cups) if cups is not None else drawing_cups
    bar_module._of_the_day = lambda user_id, today, characters: character_index


def count_fixed(tally: Tally) -> None:
    """数写死的点单句和兜底句用了几次。"""
    fixed_order = bar_module.fixed_order
    fixed_farewell = bar_module.fixed_farewell

    def order(order: Order, lines: BarLines, random: Random):
        tally.current.fixed_order = True
        return fixed_order(order, lines, random)

    def farewell(serving: Serving, drunk: bool, lines: BarLines, random: Random):
        tally.current.fixed_farewell = True
        return fixed_farewell(serving, drunk, lines, random)

    bar_module.fixed_order = order
    bar_module.fixed_farewell = farewell


def seed_history(
    db: sqlite3.Connection, user_id: str, her: Character, visits: int, usual: str, now: datetime
) -> None:
    """她和制作人以前来过 `visits` 次，最后一次是三天前，每次点的都是 `usual` 这一款、上对了。"""
    orders = json.dumps(
        [{"target": usual, "phrasing": "name", "served": usual, "big": False, "tier": "right"}]
    )
    for i in range(visits):
        at = now - timedelta(days=3 + 7 * (visits - 1 - i))
        db.execute(
            "INSERT INTO visit_records (user_id, character_id, entered_at, left_at, entered_on,"
            " reason, topic, orders, drunk, rewarded) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0)",
            (
                user_id, her.id, at.isoformat(), (at + timedelta(minutes=20)).isoformat(),
                at.date().isoformat(), "seeded", "seeded", orders,
            ),
        )


def described(drink: Drink) -> str:
    return f"{drink.name}（{drink.name_ja}，{FLAVORS[drink.flavor]}/{KINDS[drink.kind]}）"


def show_order(cup: int, order: Order) -> None:
    words = "、".join(order.words()) or "无"
    usual = f"｜上次那款：{'、'.join(sorted(order.usual))}" if order.usual else ""
    print(f"\n【点单卡】第 {cup} 杯：{described(order.target)}｜说法 {order.phrasing}"
          f"｜要提的条件 {words}{usual}")


def show_line(line: BarLine) -> None:
    if line.speaker == "producer":
        print(f"  制作人：{line.zh}")
        return
    order = " 〔点单〕" if line.order else ""
    print(f"  她 [{line.emotion}]{order}")
    print(f"      {line.ja}")
    print(f"      {line.zh}")


async def show(call: BarCall, tally: Tally, label: str) -> BarEvent | None:
    """读完一次调用，边读边打印；返回最后一个事件。"""
    tally.calls.append(CallLog())
    print(f"\n—— 调用 {len(tally.calls)}：{label} ——")
    started = time.monotonic()
    last: BarEvent | None = None
    try:
        async for event in call:
            last = event
            match event:
                case VisitBegan():
                    print(f"  （光顾 {event.visit_id}，{event.character_id}）")
                case BarLine():
                    show_line(event)
                case Memo():
                    print(f"  【备忘】{event.text}")
                case Retrying():
                    print("  …… 出错，重试，前面发的作废 ……")
                case Waiting():
                    pass
                case VisitDone():
                    print(f"  【光顾完成】奖励：{event.rewarded}")
                case VisitFailed():
                    print(f"  【失败】{event.message}")
    finally:
        await call.aclose()
    log = tally.current
    notes = [f"用时 {time.monotonic() - started:.1f} 秒"]
    if log.rewrites:
        notes.append(f"名字检查重写 {log.rewrites} 次")
    if log.fixed_order:
        notes.append("点单换成了写死的句子")
    if log.fixed_farewell:
        notes.append("反应和告别换成了写死的兜底句")
    print(f"  （{'；'.join(notes)}）")
    return last


async def drive(args: argparse.Namespace) -> int:
    cups_asked = []
    for i, (p, t, w) in enumerate(zip_longest(
        _listed(args.phrasing, PHRASINGS, "说法"), _listed(args.tier, TIERS, "档位"),
        _listed(args.wrong, WRONGS, "错法"),
    ), 1):
        if w is not None and t not in (None, "wrong"):
            raise SystemExit(f"第 {i} 杯写了错法 {w}，档位就只能是 wrong，不能是 {t}")
        cups_asked.append(Cup(p, "wrong" if w is not None else t, w))
    if len(cups_asked) > 3:
        raise SystemExit("一次光顾最多 3 杯")
    plan = Plan(cups_asked, args.drunk)
    cups = args.cups or (len(plan.cups) if plan.cups else 3 if args.drunk else None)
    seed = args.seed if args.seed is not None else Seeded().randrange(10**6)
    rng = Seeded(seed)

    with tempfile.TemporaryDirectory(prefix="bar-visit-") as directory:
        settings = replace(Settings.from_env(), database_path=Path(directory) / "eidolon.db")
        backend = build(settings)
        try:
            characters = backend.characters
            ids = list(characters)
            her_id = args.character or ids[rng.randrange(len(ids))]
            if her_id not in characters:
                print(f"没有这个角色：{her_id}（有 {', '.join(ids)}）", file=sys.stderr)
                return 2
            her = characters[her_id]
            catalog = load_drink_catalog(drinks_path(settings.characters_path))
            tally = Tally()
            steer(plan, cups, ids.index(her_id))
            count_fixed(tally)
            bar = DevBar(
                backend.database, backend.clock, characters, catalog,
                load_bar_visits(bar_visits_path(settings.characters_path)),
                load_bar_lines(bar_lines_path(settings.characters_path)),
                backend.admissions, lambda: True, rng.randrange, world=backend.world,
                tally=tally, break_farewell=args.break_farewell,
            )
            user = await backend.store.create_user("制作人")
            await backend.database.write(
                seed_history, user.id, her, args.visits, _usual(her, catalog), backend.clock()
            )
            print(f"种子 {seed}｜模型 {settings.chat_llm.model}（{settings.chat_llm.base_url}）")
            print(
                f"角色 {her.name}（{her.id}）｜酒量 {her.bar_tolerance}"
                f"（醉的门槛 {_drunk_at(her)} 份）｜讨厌 "
                f"{FLAVORS.get(her.bar_disliked_flavor or '', '无')}｜爱喝 "
                f"{'、'.join(her.bar_favorites)}｜以前来过 {args.visits} 次"
            )

            try:
                await _visit(bar, user.id, her, catalog, plan, tally, rng)
            finally:
                await bar.aclose()  # 运行记录和每次调用写完
            await _show_usage(backend.database.read, user.id)
        finally:
            await backend.aclose()
    return 0


async def _visit(
    bar: DevBar, user_id: str, her: Character, catalog: DrinkCatalog, plan: Plan, tally: Tally,
    rng: Seeded,
) -> None:
    call = await bar.enter(user_id, BroughtKeys())
    visit = bar.under_way(user_id)
    assert visit is not None
    visit_id = visit.id
    print(f"来意 {visit.reason.id}：{visit.reason.note}")
    print(f"话题 {visit.topic.id}：{visit.topic.note}｜打算喝 {visit.cups} 杯")
    show_order(1, visit.orders[0])
    last = await show(call, tally, "进门，点第一杯")
    while True:
        tries = 0
        while isinstance(last, VisitFailed) and tries < RETRIES:
            if bar.under_way(user_id) is None:  # 玩完了却没写进库：没有可再试的
                return
            tries += 1
            last = await show(await bar.retry(user_id, visit_id), tally, "再试一次")
        if not isinstance(last, Waiting):
            return
        visit = bar.under_way(user_id)
        assert visit is not None
        cup = len(visit.orders)
        order = visit.orders[-1]
        if cup > 1:
            show_order(cup, order)
        serving, made = _chosen(
            order, plan.of(cup - 1), her, catalog, plan.drunk, plan.had, rng
        )
        plan.had += serving.served.karmotrine
        served = serving.served
        print(
            f"\n【上酒】{described(served.drink)}{'，大杯' if served.big else ''}，"
            f"Karmotrine {served.karmotrine} 份 → {_TIERS_SAID[serving.tier]}"
            f"{f'（{serving.wrong}）' if serving.wrong else ''}"
            f"｜累计 {plan.had}/{_drunk_at(her)} 份"
        )
        call = await bar.serve(user_id, visit_id, made)
        label = "反应、闲聊，点下一杯"
        if len(visit.orders) == len(visit.servings):
            label = f"反应、闲聊，告别（{'醉了' if visit.drunk else '没醉'}）"
        last = await show(call, tally, label)


def _usual(her: Character, catalog: DrinkCatalog) -> str:
    """以前几次她喝的：合她口味、又不是她爱喝的一款，没有就是她爱喝的第一款；这样第一杯
    还能点她爱喝的（第一杯不点上次那款）。"""
    for drink in catalog.drinks.values():
        if (
            drink.id not in her.bar_favorites and drink.flavor != her.bar_disliked_flavor
            and (drink.flavor in her.bar_flavors or drink.kind == her.bar_kind)
        ):
            return drink.id
    return her.bar_favorites[0]


def _chosen(
    order: Order, cup: Cup, her: Character, catalog: DrinkCatalog, drunk: bool, had: int,
    rng: Seeded,
) -> tuple[Serving, Mixture | str]:
    """替制作人挑一杯：合档位要求；醉的话 Karmotrine 最多；不醉的话尽量不让她醉。"""
    candidates = servings_for(order, cup, her, catalog, drunk)
    if cup.tier is None:
        tiers = sorted({s.tier for s, _ in candidates})
        tier = tiers[rng.randrange(len(tiers))]
        candidates = [c for c in candidates if c[0].tier == tier]
    if drunk:
        most = max(s.served.karmotrine for s, _ in candidates)
        candidates = [c for c in candidates if c[0].served.karmotrine == most]
    else:
        sober = [c for c in candidates if _keeps_sober(her, had, c[0])]
        candidates = sober or candidates
    return candidates[rng.randrange(len(candidates))]


async def _show_usage(read, user_id: str) -> None:
    rows = await read(_usage, user_id)
    print("\n—— 每次调用的用量和用时 ——")
    for i, (model, error, latency, first, unit, used_in, used_out, cached) in enumerate(rows, 1):
        took = f"{latency / 1000:.1f} 秒" if latency is not None else "?"
        to_first = f"，首字 {first / 1000:.1f} 秒" if first is not None else ""
        usage = (
            f"输入 {used_in:.0f}（缓存 {cached or 0:.0f}）输出 {used_out:.0f} {unit}"
            if used_in is not None and used_out is not None else "用量未知"
        )
        print(f"  {i}. {model}：{took}{to_first}｜{usage}{f'｜出错 {error}' if error else ''}")


def _usage(db: sqlite3.Connection, user_id: str) -> list[tuple]:
    return db.execute(
        "SELECT c.model, c.error, c.latency_ms, c.first_token_ms, c.usage_unit, c.usage_input,"
        " c.usage_output, c.usage_cached FROM service_calls c"
        " JOIN activity_records r ON c.record_id = r.id WHERE r.user_id = ? ORDER BY c.id",
        (user_id,),
    ).fetchall()


def _listed(text: str | None, allowed: tuple[str, ...], what: str) -> list:
    if not text:
        return []
    out = []
    for item in text.split(","):
        item = item.strip()
        if item in ("any", "-", ""):
            out.append(None)
        elif item in allowed:
            out.append(item)
        else:
            raise SystemExit(f"没有这种{what}：{item}（有 {', '.join(allowed)}）")
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="用部署者的对话模型走一次光顾，看措辞")
    parser.add_argument("--character", help="角色 id，默认随机")
    parser.add_argument("--cups", type=int, choices=(1, 2, 3), help="几杯，默认照常抽")
    parser.add_argument("--phrasing", help=f"每杯的说法，逗号分开，any 是随机：{', '.join(PHRASINGS)}")
    parser.add_argument("--tier", help=f"每杯上成哪一档：{', '.join(TIERS)}")
    parser.add_argument("--wrong", help=f"上错的杯错在哪（这一杯就是上错）：{', '.join(WRONGS)}")
    parser.add_argument("--drunk", action="store_true", help="让她喝醉：每杯挑 Karmotrine 最多的")
    parser.add_argument("--visits", type=int, default=3, help="以前来过几次，默认 3（0 是新手）")
    parser.add_argument("--break-farewell", action="store_true", help="告别那次调用故意弄坏，换兜底句")
    parser.add_argument("--seed", type=int, help="抽签的种子，默认随机（会打印出来）")
    args = parser.parse_args()
    logging.basicConfig(level=logging.WARNING, stream=sys.stderr)
    return asyncio.run(drive(args))


if __name__ == "__main__":
    sys.exit(main())
