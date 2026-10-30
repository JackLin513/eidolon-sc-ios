"""The bar prompt the upstream Python engine assembles, for the bar oracle scenario.

`bar_prompt.prompt` is a pure function of its arguments, so the scenario fixes every input
(characters, reason, topic, cups, remembered visits, facts, prior calls, this call's ask)
and this writes the message list upstream builds from them. It is compared verbatim with
the iOS core's (`prompt-oracle --bar`).

Usage:
    uv run --project ../eidolon-sc/backend python tools/oracle/upstream_bar_prompt.py \
        --upstream ../eidolon-sc --scenario tools/oracle/scenario-bar.json \
        --out build/oracle/upstream-scenario-bar.json
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path


def last_part(ask: dict, order, serving, scenario: dict) -> str:
    """The ask's last part, as `bar_prompt` writes it for that kind of call."""
    from eidolon import bar_prompt
    from eidolon.bar_reply import BarLine

    kind = ask["kind"]
    if kind == "opening":
        return bar_prompt.opening_ask(order(ask["order"]))
    if kind == "serving":
        return bar_prompt.serving_ask(
            serving(ask["serving"]), ask["enjoy"], order(ask["order"])
        )
    if kind == "farewell":
        return bar_prompt.farewell_ask(
            serving(ask["serving"]), ask["enjoy"],
            [serving(s) for s in ask["servings"]], drunk=ask["drunk"],
        )
    if kind == "rewrite":
        return bar_prompt.rewrite_ask(
            scenario.get("opening_ask") or bar_prompt.opening_ask(order(ask["order"])),
            order(ask["order"]),
            [
                BarLine(
                    line["speaker"], line["zh"], line.get("ja", ""),
                    line.get("emotion", "calm"), line.get("order", False),
                )
                for line in ask.get("before", [])
            ],
        )
    raise SystemExit(f"scenario: unknown ask kind {kind}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", default="../eidolon-sc")
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    upstream = Path(args.upstream).resolve()
    scenario = json.loads(Path(args.scenario).read_text(encoding="utf-8"))

    sys.path.insert(0, str(upstream / "backend" / "src"))
    from eidolon import bar_prompt
    from eidolon.bar_lines import load_bar_lines, bar_lines_path
    from eidolon.bar_reply import BarLine
    from eidolon.bar_rules import Had, Order, Serving
    from eidolon.bar_visits import load_bar_visits, bar_visits_path
    from eidolon.characters import load_characters
    from eidolon.drink_catalog import Mixture, load_drink_catalog, drinks_path

    characters_path = upstream / "characters" / "characters.toml"
    characters = load_characters(characters_path)
    catalog = load_drink_catalog(drinks_path(characters_path))
    visits = load_bar_visits(bar_visits_path(characters_path))
    lines = load_bar_lines(bar_lines_path(characters_path))

    character = characters[scenario["character_id"]]
    from eidolon.bar_rules import Reason as DrawnReason

    listed = next(r for r in visits.reasons if r.id == scenario["reason_id"])
    reason = DrawnReason(listed.id, listed.note, listed.mood)
    topic = next(t for t in visits.topics if t.id == scenario["topic_id"])

    def order(fixed: dict) -> Order:
        drink = catalog.drinks[fixed["target"]]
        return Order(
            drink,
            fixed["phrasing"],
            tuple(fixed.get("said", ())),
            frozenset(fixed.get("usual", ())),
        )

    def serving(fixed: dict) -> Serving:
        put = fixed["served"]
        served = (
            catalog.match(Mixture(**put)) if isinstance(put, dict)
            else catalog.match(put)
        )
        if served is None:
            raise SystemExit(f"scenario: {put} is not a drink")
        return Serving(
            order(fixed["order"]), served, fixed["tier"],
            fixed.get("wrong"),
        )

    remembered = bar_prompt.Remembered(
        visits=scenario["remembered"]["visits"],
        last_left_at=(
            datetime.fromisoformat(scenario["remembered"]["last_left_at"])
            if scenario["remembered"].get("last_left_at") else None
        ),
        last_orders=tuple(
            Had(h["target"], h["phrasing"], h["served"], h["big"], h["tier"])
            for h in scenario["remembered"].get("last_orders", [])
        ),
        last_drunk=scenario["remembered"].get("last_drunk", False),
    )

    now = datetime.fromisoformat(scenario["now"])
    shared = bar_prompt.shared_prompt(character, scenario.get("world"))
    # Upstream now takes one list of "now" lines (`her_now.HerNow`): how she feels toward
    # the producer, then the day in Tokyo (`her_now.CARRIES["visit"]`). The scenario fixes
    # both halves, so they are joined here in that order.
    now_lines = [*scenario.get("affinity_lines", []), *scenario.get("today", [])]
    visit = bar_prompt.visit_prompt(
        scenario["about_producer"], reason, topic, scenario["cups"],
        now_lines, remembered, now, character, catalog, scenario.get("facts", []),
    )

    written: list[tuple[str, list[BarLine]]] = []
    for call in scenario.get("written", []):
        written.append((
            call["ask"],
            [
                BarLine(
                    line["speaker"], line["zh"], line.get("ja", ""),
                    line.get("emotion", "calm"), line.get("order", False),
                )
                for line in call["lines"]
            ],
        ))

    # `asks` compares several calls' last parts in one run; `ask` alone is one of them.
    asks = scenario.get("asks") or [scenario["ask"]]
    out = []
    for ask in asks:
        final = last_part(ask, order, serving, scenario)
        messages = bar_prompt.prompt(shared, visit, written, final)
        out.extend(
            {
                "role": m.role,
                "content": m.content,
                "cache_breakpoint": bool(getattr(m, "cache_breakpoint", False)),
            }
            for m in messages
        )
    path = Path(args.out)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {path} ({len(out)} messages)")


if __name__ == "__main__":
    main()
