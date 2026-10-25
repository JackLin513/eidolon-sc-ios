"""Estimating her cycle from the user's records of it (GLOSSARY.md「推算」), as LAPLACE Cycles
does (<https://laplace.live/cycles/predictions>): from what the user wrote down alone, never
her true cycle (`her_cycle`), which this does not read; worked out whenever it is asked,
not stored.

**Her cycle.** From one record, `TYPICAL_CYCLE` days, roughly (`once`). From more, the gaps
between the latest records' first days, at most `GAPS`: those shorter than `SHORTEST_GAP`
or longer than `LONGEST_GAP` are set aside, then those `MISSED_TIMES` the shortest left
(the anchor, kept within `ANCHOR`) or more, a period having been missed in between
(`missed`). Where one or two are left, all `FOLDED_FROM` or longer, each is folded into the
nearest whole number of typical cycles (`missed`); from a third, she is taken to be long.
Her cycle is the median of what is left, in whole days; `TYPICAL_CYCLE` where nothing is
(`missed`). Those left more than `IRREGULAR` days apart are `irregular`.

**Her period.** The median of the latest `PERIODS` records' days where there is a gap to
go by; else the last record's days, or `TYPICAL_PERIOD` if more, so that a first period
still going on is not cut short.

**What is estimated.** Her next `AHEAD` periods, each a cycle after the one before, from
the last record's first day on, and the `PREMENSTRUAL` days before each. Today past the
next one's first day, it is still there, not moved on, and the latest period may not have
been written down (`late`). Any reason fades everything estimated.

**How far off.** Each cycle that has ended, estimated again from the records before its
end alone, against the gap it turned out to be; those out of the gaps' bounds or
`MISSED_TIMES` the estimate or more not compared. The mean, from two compared on."""

import math
import statistics
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import date, timedelta
from typing import Literal

TYPICAL_CYCLE = 28
TYPICAL_PERIOD = 5
GAPS = 8
"""How many of the latest gaps her cycle is estimated from."""
SHORTEST_GAP, LONGEST_GAP = 15, 60
ANCHOR = (22, 38)
"""What the shortest gap is kept within as the anchor: 80% of the typical cycle to 10 days
more."""
MISSED_TIMES = 1.6
"""How many times the anchor a gap is, or more, that a period was missed in."""
FOLDED_FROM = 45
"""How long a gap is, or more, to be folded, one or two of them alone: the typical cycle
`MISSED_TIMES` over."""
IRREGULAR = 7
"""How many days apart the longest and shortest gaps may be without her being irregular."""
PERIODS = 6
"""How many of the latest records her period is estimated from."""
AHEAD = 3
"""How many periods are estimated."""
PREMENSTRUAL = 5
"""How many days before each estimated period are estimated premenstrual."""

Reason = Literal["once", "irregular", "missed", "late"]
"""Why an estimate is faded: one record only; her cycles vary; a period may have been
missed in the records; the latest may not be written down yet."""

REASONS: tuple[Reason, ...] = ("once", "irregular", "missed", "late")


@dataclass(frozen=True)
class Logged:
    """A period the user wrote down: its first day, a calendar day, and how many days."""

    first_day: date
    days: int


@dataclass(frozen=True)
class Recorded:
    """Today is day `day` (from 1) of a period the user wrote down."""

    day: int


@dataclass(frozen=True)
class Estimated:
    """Today is in an estimated period."""


@dataclass(frozen=True)
class Premenstrual:
    """Today is in the days estimated before a period."""


Today = Recorded | Estimated | Premenstrual | None


@dataclass(frozen=True)
class Estimate:
    cycle: int
    period: int
    reasons: tuple[Reason, ...]
    """Empty where it is not faded; in the order of `REASONS`."""
    periods: tuple[tuple[date, int], ...]
    """The estimated periods, their first day and days; the `PREMENSTRUAL` days before
    each are estimated premenstrual."""
    off_by: float | None
    """How many days the past estimates were off, on average, to a tenth."""
    today: Today

    def shown(self) -> dict:
        today: dict | None
        match self.today:
            case Recorded(day):
                today = {"kind": "recorded", "day": day}
            case Estimated():
                today = {"kind": "estimated"}
            case Premenstrual():
                today = {"kind": "premenstrual"}
            case None:
                today = None
        return {
            "cycle": self.cycle,
            "period": self.period,
            "reasons": list(self.reasons),
            "periods": [
                {"first_day": first.isoformat(), "days": days} for first, days in self.periods
            ],
            "off_by": self.off_by,
            "today": today,
        }


def estimate(records: Sequence[Logged], today: date) -> Estimate | None:
    """What is estimated of her from `records` on `today`; None without any."""
    if not records:
        return None
    records = sorted(records, key=lambda r: r.first_day)
    cycle, gaps, reasons = _cycle(records)
    if gaps:
        period = _rounded(statistics.median(r.days for r in records[-PERIODS:]))
    else:
        period = max(records[-1].days, TYPICAL_PERIOD)
    step = timedelta(days=cycle)
    first = records[-1].first_day + step
    periods = tuple((first + step * n, period) for n in range(AHEAD))
    if today > first:
        reasons.add("late")
    return Estimate(
        cycle=cycle,
        period=period,
        reasons=tuple(r for r in REASONS if r in reasons),
        periods=periods,
        off_by=_off_by(records),
        today=_today(records, periods, today),
    )


def _cycle(records: Sequence[Logged]) -> tuple[int, list[float], set[Reason]]:
    """Her cycle from `records` in order, the gaps it is the median of, and why it is
    faded, but for being late."""
    if len(records) == 1:
        return TYPICAL_CYCLE, [], {"once"}
    reasons: set[Reason] = set()
    days = [
        (later.first_day - earlier.first_day).days
        for earlier, later in zip(records, records[1:])
    ][-GAPS:]
    gaps: list[float] = [g for g in days if SHORTEST_GAP <= g <= LONGEST_GAP]
    if gaps:
        anchor = min(max(min(gaps), ANCHOR[0]), ANCHOR[1])
        gaps = [g for g in gaps if g < anchor * MISSED_TIMES]
    if len(gaps) < len(days):
        reasons.add("missed")
    if 1 <= len(gaps) <= 2 and all(g >= FOLDED_FROM for g in gaps):
        gaps = [g / round(g / TYPICAL_CYCLE) for g in gaps]
        reasons.add("missed")
    if not gaps:
        return TYPICAL_CYCLE, [], reasons
    if max(gaps) - min(gaps) > IRREGULAR:
        reasons.add("irregular")
    return _rounded(statistics.median(gaps)), gaps, reasons


def _off_by(records: Sequence[Logged]) -> float | None:
    """How many days the estimates of each cycle that has ended were off on average, each
    estimated from the records before its end alone; None from fewer than two compared."""
    off = []
    for n in range(1, len(records)):
        estimated, _, _ = _cycle(records[:n])
        gap = (records[n].first_day - records[n - 1].first_day).days
        if SHORTEST_GAP <= gap <= LONGEST_GAP and gap < estimated * MISSED_TIMES:
            off.append(abs(gap - estimated))
    if len(off) < 2:
        return None
    return math.floor(statistics.mean(off) * 10 + 0.5) / 10


def _today(
    records: Sequence[Logged], periods: Sequence[tuple[date, int]], today: date
) -> Today:
    for record in records:
        into = (today - record.first_day).days
        if 0 <= into < record.days:
            return Recorded(into + 1)
    for first, days in periods:
        into = (today - first).days
        if 0 <= into < days:
            return Estimated()
        if -PREMENSTRUAL <= into < 0:
            return Premenstrual()
    return None


def _rounded(days: float) -> int:
    """`days` to the nearest whole day, halves up."""
    return math.floor(days + 0.5)
