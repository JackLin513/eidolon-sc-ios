"""The dashboard (GLOSSARY.md「看板」): the activity records of a recent range of time,
summed up for the admin, under `/api/admin/dashboard`.

Everything is summed up here; the browser only shows it. For each service, on the
deployer's keys and on users' own apart: how many calls, how many failed and how, how
long they took, and what they were billed for; for image generation, from how many photos
tags were stripped for crossing the line, and how many for each part of it; for an LLM, how
soon its first word came and how much of its input hit the provider's prompt cache, at
whatever reasoning effort.
For turns (typed or in calls): how many, by how they turned out, how many on users' own
keys, how soon the character began to speak. For calls: how many, by how they turned out, how many on users' own keys, how long
they lasted and why they ended. How many users took any turn or call; how many turns and
calls with each character, and in each stretch of the range (`trend`), in stretches
beginning where the admin's clock (`X-Timezone`) has a round hour or day. Where affinity is
on (GLOSSARY.md「好感度」), how the judge model judged the turns recorded, and the cooldowns
they began, in all and for each character, with how often she hung up a call or ended a
conversation (`affinity`). How many times characters reached out (GLOSSARY.md「搭话」), how
many times that failed, and the share answered (`reach_outs`), where the deployer has them on
or any were recorded in the range. Nothing anyone said is in it, nor whose any of it was.

How many calls are in progress now is not in the records but the calls themselves:
`/api/admin/calls/live`, which the page asks every minute.
"""

import math
from collections import Counter, defaultdict
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Annotated, Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import FastAPI, Header, Query

from eidolon.activity import (
    CALL_END_REASONS,
    LLM_SERVICES,
    RESULTS,
    SERVICES,
    CallRow,
    RecordRow,
)
from eidolon.affinity import LEVEL_STEPS, Judged
from eidolon.admin_api import Admin
from eidolon.assembly import Backend
from eidolon.photo_prompt import CROSSINGS
from eidolon.prices import cost

Range = Literal["24h", "7d", "30d", "90d"]


@dataclass(frozen=True)
class Span:
    """A range of the dashboard: how far back it goes, and how long each stretch of its
    trend is."""

    length: timedelta
    stretch: timedelta
    bucket: Literal["hour", "6h", "day"]


SPANS: dict[Range, Span] = {
    "24h": Span(timedelta(hours=24), timedelta(hours=1), "hour"),
    "7d": Span(timedelta(days=7), timedelta(hours=6), "6h"),
    "30d": Span(timedelta(days=30), timedelta(days=1), "day"),
    "90d": Span(timedelta(days=90), timedelta(days=1), "day"),
}


def add_dashboard_routes(app: FastAPI, backend: Backend) -> None:
    @app.get("/api/admin/dashboard")
    def dashboard(
        _: Admin,
        range: Annotated[Range, Query()] = "24h",
        timezone: Annotated[str | None, Header(alias="X-Timezone")] = None,
    ) -> dict:
        """The activity of the last `range`, summed up."""
        span = SPANS[range]
        now = backend.clock()
        recorded, service_calls = backend.activity.since(now - span.length)
        # Reach-outs are no turns nor calls, and taken by no user; their service calls count.
        records = [r for r in recorded if r.kind != "reach_out"]
        reached = [r for r in recorded if r.kind == "reach_out"]
        names = {id: c.name for id, c in backend.characters.items()}
        starts = stretches(now, span, _zone(timezone))
        spent = cost(service_calls, backend.prices.pricing(), starts)
        backend.prices.catalog.refresh_soon(
            missing=any(r["unit"] == "tokens" and r["price"] is None for r in spent["rows"])
        )
        return {
            "range": range,
            "from": (now - span.length).isoformat(),
            "to": now.isoformat(),
            "bucket": span.bucket,
            "health": health(service_calls),
            "active_users": len({r.who for r in records if r.who is not None}),
            "turns": turns([r for r in records if r.kind == "turn"]),
            "calls": calls([r for r in records if r.kind == "call"]),
            "trend": trend(records, starts),
            "characters": characters(records, names),
            "affinity": affinity(records, names) if backend.config.affinity_on else None,
            "reach_outs": (
                reach_outs(reached) if backend.config.reach_outs.enabled or reached else None
            ),
            "cost": spent,
        }

    @app.get("/api/admin/calls/live")
    def live_calls(_: Admin) -> dict:
        """How many calls there are right now, connected or still connecting."""
        return {"in_progress": backend.calls.in_progress}


def _zone(name: str | None) -> ZoneInfo:
    try:
        return ZoneInfo(name or "UTC")
    except (ZoneInfoNotFoundError, ValueError):
        return ZoneInfo("UTC")


def percentile(values: Sequence[float], p: float) -> float | None:
    """The nearest-rank `p`th percentile of `values`, None of none."""
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[max(0, math.ceil(p / 100 * len(ordered)) - 1)], 1)


def health(calls: Iterable[CallRow]) -> list[dict]:
    """Each service's calls, on the deployer's keys and on users' own apart, in the order
    of `SERVICES`; an LLM's at every reasoning effort together, with its cache hit rate."""
    groups: dict[tuple[str, bool], list[CallRow]] = defaultdict(list)
    for call in calls:
        groups[(call.service, call.own_key)].append(call)
    rows = []
    for (service, own_key), group in sorted(groups.items(), key=lambda g: (_order(g[0][0]), g[0][1])):
        failed = [c for c in group if c.error is not None]
        row = {
            "service": service,
            "own_key": own_key,
            "calls": len(group),
            "errors": len(failed),
            "error_rate": len(failed) / len(group),
            "errors_by_kind": dict(Counter(c.error for c in failed if c.error)),
            "latency_ms": _percentiles(c.latency_ms for c in group),
            "usage": _usage(group, llm=service in LLM_SERVICES),
            "usage_unknown": sum(c.usage_unit is None for c in group),
        }
        if service == "image":
            row["stripped_photos"] = sum(c.stripped is not None for c in group)
            row["stripped"] = _stripped(group)
        if service in LLM_SERVICES:
            row["first_token_ms"] = _percentiles(c.first_token_ms for c in group)
            row["cache_hit_rate"] = cache_hit_rate(group)
        rows.append(row)
    return rows


def _stripped(calls: Sequence[CallRow]) -> dict[str, int]:
    """How many tags were stripped from her photo tags, by which part of the line each
    crossed, in the order of `CROSSINGS`; only those any crossed."""
    stripped: Counter[str] = Counter()
    for call in calls:
        stripped.update(call.stripped or {})
    return {c: stripped[c] for c in CROSSINGS if stripped[c]}


def cache_hit_rate(calls: Sequence[CallRow]) -> float | None:
    """Of all the input tokens an LLM's calls said they were billed for, the share the
    provider read from its prompt cache; a call that did not say how much hit none. None
    where no call said what its input was."""
    told = [c for c in calls if c.usage_unit == "tokens" and c.usage_input is not None]
    input = sum(c.usage_input or 0 for c in told)
    return sum(c.usage_cached or 0 for c in told) / input if input else None


def _percentiles(values: Iterable[float | None]) -> dict:
    """The p50 and p95 of the values known."""
    known = [v for v in values if v is not None]
    return {"p50": percentile(known, 50), "p95": percentile(known, 95)}


def _order(service: str) -> int:
    return SERVICES.index(service) if service in SERVICES else len(SERVICES)  # pyright: ignore[reportArgumentType]


def _usage(calls: Sequence[CallRow], llm: bool) -> list[dict]:
    """What the calls were billed for, in each unit they were billed in; an `llm`'s, of the
    input, how much hit the prompt cache, where any call said."""
    units: dict[str, list[CallRow]] = defaultdict(list)
    for call in calls:
        if call.usage_unit is not None:
            units[call.usage_unit].append(call)
    return [
        {
            "unit": unit,
            "input": _sum(c.usage_input for c in billed),
            "output": _sum(c.usage_output for c in billed),
            **({"cached": _sum(c.usage_cached for c in billed)} if llm else {}),
        }
        for unit, billed in sorted(units.items())
    ]


def _sum(values: Iterable[float | None]) -> float | None:
    told = [v for v in values if v is not None]
    return sum(told) if told else None


def turns(records: Sequence[RecordRow]) -> dict:
    by_result = Counter(r.result for r in records)
    return {
        "total": len(records),
        "by_result": {result: by_result[result] for result in RESULTS if result != "not_connected"},
        "own_keys": sum(bool(r.own_llm) for r in records),
        "in_calls": sum(r.in_call for r in records),
        "time_to_speak_ms": _speaking(records),
    }


CALL_RESULTS = ("success", "failed", "rejected", "not_connected")
"""How a call can turn out: a user leaving a call is hanging it up, not a result."""

DURATIONS: tuple[tuple[int, int | None], ...] = (
    (0, 60), (60, 180), (180, 600), (600, 1800), (1800, None)
)
"""The stretches, in seconds, calls' durations are counted in."""


def calls(records: Sequence[RecordRow]) -> dict:
    """The calls: how they turned out, on whose keys, how long those that connected
    lasted, and why each ended (a call refused over the limit never began, so did not)."""
    by_result = Counter(r.result for r in records)
    lasted = [r.duration_s for r in records if r.duration_s is not None]
    reasons = Counter(r.end_reason for r in records if r.end_reason is not None)
    return {
        "total": len(records),
        "by_result": {result: by_result[result] for result in CALL_RESULTS},
        "own_keys": sum(r.own_keys for r in records),
        "duration_s": {"p50": percentile(lasted, 50), "p90": percentile(lasted, 90)},
        "durations": [
            {
                "from_s": low,
                "to_s": high,
                "calls": sum(low <= d and (high is None or d < high) for d in lasted),
            }
            for low, high in DURATIONS
        ],
        "end_reasons": {reason: reasons[reason] for reason in CALL_END_REASONS},
    }


def _speaking(records: Sequence[RecordRow]) -> dict:
    """How soon the character began to speak, in the turns where she did."""
    times = [r.time_to_speak_ms for r in records if r.time_to_speak_ms is not None]
    return {"count": len(times), "p50": percentile(times, 50), "p90": percentile(times, 90)}


def stretches(now: datetime, span: Span, zone: ZoneInfo) -> list[datetime]:
    """Where each stretch of the range's trend begins, oldest first: the last one where
    the admin's clock last had a round hour, six hours or day, and as many before it as the
    range holds."""
    local = now.astimezone(zone)
    if span.stretch >= timedelta(days=1):
        last = local.replace(hour=0, minute=0, second=0, microsecond=0)
    else:
        hours = int(span.stretch / timedelta(hours=1))
        last = local.replace(hour=local.hour - local.hour % hours, minute=0, second=0,
                             microsecond=0)
    count = int(span.length / span.stretch)
    last = last.astimezone(UTC)
    return [last - span.stretch * (count - 1 - i) for i in range(count)]


def trend(records: Sequence[RecordRow], starts: Sequence[datetime]) -> list[dict]:
    """How many turns and calls, and by how many users, in each stretch beginning at
    `starts`; the first takes in whatever of the range comes before it."""
    stretch = starts[1] - starts[0] if len(starts) > 1 else timedelta(days=1)
    counts: list[Counter[str]] = [Counter() for _ in starts]
    users: list[set[str]] = [set() for _ in starts]
    for record in records:
        i = max(0, min(len(starts) - 1, int((record.started_at - starts[0]) / stretch)))
        counts[i][record.kind] += 1
        if record.who is not None:
            users[i].add(record.who)
    return [
        {
            "start": start.isoformat(),
            "turns": n["turn"],
            "calls": n["call"],
            "active_users": len(who),
        }
        for start, n, who in zip(starts, counts, users, strict=True)
    ]


def characters(records: Sequence[RecordRow], names: dict[str, str]) -> list[dict]:
    """How many turns and calls with each character, most turns first; a character since
    removed from the configuration has no name."""
    counted: dict[str, Counter[str]] = defaultdict(Counter)
    for record in records:
        counted[record.character_id][record.kind] += 1
    return [
        {"character_id": id, "name": names.get(id), "turns": n["turn"], "calls": n["call"]}
        for id, n in sorted(counted.items(), key=lambda c: (-c[1]["turn"], -c[1]["call"], c[0]))
    ]


JUDGED_TO_TELL_SHARE = 20
"""How many judged turns a character needs for the shares of them that raised and lowered
her affinity to be told."""



def affinity(records: Sequence[RecordRow], names: dict[str, str]) -> dict:
    """How the judge model judged the turns recorded (only those, not those failed, refused
    or left), in all and for each character: how many began a cooldown, and for how many
    users; how many were out of line, how many tried to dictate her affinity; how many at
    each level. For each character, how many were judged, the shares that raised and lowered
    it (not told for too few, `JUDGED_TO_TELL_SHARE`), how many began a cooldown, and how
    often she hung up a call or ended a conversation, whatever for (`she_ended`); the most
    judged first."""
    judged = [r for r in records if r.kind == "turn" and r.result == "success" and r.judged]
    by_character: dict[str, list[RecordRow]] = defaultdict(list)
    for record in judged:
        by_character[record.character_id].append(record)
    she_ended = Counter(
        r.character_id for r in records
        if (r.kind == "call" and r.end_reason == "character_hung_up")
        or (r.kind == "turn" and r.ended_conversation is not None)
    )
    rows = []
    for id in by_character.keys() | she_ended.keys():
        turns = by_character.get(id, [])
        told = len(turns) >= JUDGED_TO_TELL_SHARE
        rows.append({
            "character_id": id,
            "name": names.get(id),
            "judged": len(turns),
            "raised_share": _share(turns, lambda step: step > 0) if told else None,
            "lowered_share": _share(turns, lambda step: step < 0) if told else None,
            "cooldowns": sum(r.cooled for r in turns),
            "she_ended": she_ended[id],
        })
    rows.sort(key=lambda r: (-r["judged"], -r["she_ended"], r["character_id"]))
    levels = Counter(_judged(r).level for r in judged)
    return {
        **_judgements(judged),
        "cooled_users": len({r.who for r in judged if r.cooled and r.who is not None}),
        "levels": [levels[level] for level in range(len(LEVEL_STEPS))],
        "characters": rows,
    }


def reach_outs(records: Sequence[RecordRow]) -> dict:
    """How many times characters reached out, how many times it failed, and the share of
    those reached out that were answered (None of none); not by character."""
    succeeded = [r for r in records if r.result == "success"]
    return {
        "succeeded": len(succeeded),
        "failed": sum(r.result == "failed" for r in records),
        "answered_share": (
            sum(r.answered for r in succeeded) / len(succeeded) if succeeded else None
        ),
    }


def _share(turns: Sequence[RecordRow], moved: Callable[[float], bool]) -> float:
    """The share of the judged `turns` whose step (`Judged.step`: out of line lowers it
    whatever the level, trying to dictate it raises it never) `moved` holds of."""
    return sum(moved(_judged(r).step) for r in turns) / len(turns)


def _judgements(records: Sequence[RecordRow]) -> dict[str, int]:
    """How many of the judged turns began a cooldown, were out of line, or tried to dictate
    her affinity."""
    return {
        "cooldowns": sum(r.cooled for r in records),
        "out_of_line": sum(_judged(r).out_of_line for r in records),
        "manipulation": sum(_judged(r).manipulation for r in records),
    }


def _judged(record: RecordRow) -> Judged:
    """What the judge model made of a turn known to have been judged."""
    assert record.judged is not None
    return record.judged
