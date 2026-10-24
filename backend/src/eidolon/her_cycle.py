"""Her true cycle (GLOSSARY.md「周期」): where she is on a day, derived rather than stored
(ADR-0029).

Each user's each character has a seed (`cycle_seed`), and from it alone her rhythm: her
base cycle, her base period, how many days before it she is premenstrual, and where her
first cycle begins before the epoch. Cycle k's length and period are drawn from the seed
and k alone, so a day is where it is whenever it is asked, and the days gone by never
move. Nothing here reads the database, the switches or the clock: the day asked about is
the producer's calendar day, in their time zone (`cycles`).

Everything marked frozen is: changing any of it moves every her at once, and the records
users keep of her no longer match her (ADR-0029)."""

import hashlib
import hmac
from collections.abc import Iterator, Mapping
from dataclasses import dataclass
from datetime import date, timedelta

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

EPOCH = date(2026, 1, 1)
"""Where her first cycle (the 0th) is counted back from. Frozen (ADR-0029)."""

BASE_CYCLES = dict(zip(range(25, 35), (3, 6, 12, 20, 20, 14, 10, 7, 5, 3)))
"""Her base cycle's length in days, drawn once, by weight in percent. Frozen (ADR-0029)."""

BASE_PERIODS = {4: 20, 5: 40, 6: 28, 7: 12}
"""Her base period's length in days, drawn once, by weight in percent. Frozen (ADR-0029)."""

PERIOD_STRAYS = {-1: 25, 0: 50, 1: 25}
"""How much each period strays from her base, by weight in percent. Frozen (ADR-0029)."""

SHORTEST_PERIOD, LONGEST_PERIOD = 3, 8
"""What each period is kept within. Frozen (ADR-0029)."""

ADULT_STRAYS = dict(zip(range(-3, 4), (5, 10, 20, 30, 20, 10, 5)))
"""How much each cycle of hers strays from her base, 18 or over, by weight in percent.
Frozen (ADR-0029)."""

YOUNG_STRAYS = dict(zip(range(-5, 6), (3, 5, 7, 10, 15, 20, 15, 10, 7, 5, 3)))
"""How much each cycle of hers strays from her base under 18, by weight in percent: more,
as is usual then. Frozen (ADR-0029)."""

SHORTEST_CYCLE, LONGEST_CYCLE = 21, 40
"""What each cycle is kept within. Frozen (ADR-0029)."""

PREMENSTRUAL_DAYS = (3, 4, 5)
"""How many days before her period she is premenstrual, drawn once, evenly. Frozen
(ADR-0029)."""

SEED_INFO = b"eidolon cycles"
"""What the key her seeds are made with is derived from the secret key with (HKDF's info).
Frozen (ADR-0029)."""


@dataclass(frozen=True)
class Period:
    """Day `day` (from 1) of her period, `length` days long this time, from `first_day`."""

    day: int
    length: int
    first_day: date


@dataclass(frozen=True)
class Premenstrual:
    """Premenstrual: `days_left` days (from 1) before her next period's first day."""

    days_left: int


HerDay = Period | Premenstrual | None
"""Where she is on a day; None in her follicular or ovulatory days, or where her cycle has
no part (`cycles`)."""


@dataclass(frozen=True)
class Rhythm:
    """What is drawn once for her."""

    base_cycle: int
    base_period: int
    premenstrual_days: int
    """How many days before each period she is premenstrual."""
    offset: int
    """How many days before the epoch her 0th cycle begins, below her base cycle."""


@dataclass(frozen=True)
class Cycle:
    """One cycle of hers: her period from `first_day` on for `period` days, the next from
    `length` days after it."""

    first_day: date
    length: int
    period: int


def cycle_seed(secret_key: str | None, user_id: str, character_id: str) -> bytes:
    """The seed of the user's character's cycle: an HMAC with a key derived from the
    deployment's `secret_key`, so that no one can work it out from the code alone; without
    one, a plain SHA-256. Frozen (ADR-0029)."""
    message = f"{user_id}\n{character_id}".encode()
    if secret_key is None:
        return hashlib.sha256(message).digest()
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=SEED_INFO).derive(
        secret_key.encode()
    )
    return hmac.new(key, message, hashlib.sha256).digest()


def rhythm(seed: bytes) -> Rhythm:
    """What is drawn once for her with `seed`."""
    base_cycle = _weighted(seed, "base cycle", 0, BASE_CYCLES)
    return Rhythm(
        base_cycle=base_cycle,
        base_period=_weighted(seed, "base period", 0, BASE_PERIODS),
        premenstrual_days=PREMENSTRUAL_DAYS[_number(seed, "premenstrual", 0) % len(PREMENSTRUAL_DAYS)],
        offset=_number(seed, "offset", 0) % base_cycle,
    )


def cycles(seed: bytes, under_18: bool) -> Iterator[Cycle]:
    """Her cycles from the 0th on, one after another for ever."""
    drawn = rhythm(seed)
    return _cycles_from(seed, under_18, drawn, 0, EPOCH - timedelta(days=drawn.offset))


def her_day(seed: bytes, under_18: bool, day: date) -> HerDay:
    """Where she is on `day`: in her period, premenstrual, or neither. Days before her 0th
    cycle go on backwards as those after it go on forwards."""
    drawn = rhythm(seed)
    first_day = EPOCH - timedelta(days=drawn.offset)
    k = 0
    while day < first_day:
        k -= 1
        first_day -= timedelta(days=_length(seed, under_18, drawn, k))
    for cycle in _cycles_from(seed, under_18, drawn, k, first_day):
        into = (day - cycle.first_day).days
        if into < cycle.period:
            return Period(into + 1, cycle.period, cycle.first_day)
        if into < cycle.length:
            days_left = cycle.length - into
            return Premenstrual(days_left) if days_left <= drawn.premenstrual_days else None
    raise AssertionError("her cycles go on for ever")


def _cycles_from(
    seed: bytes, under_18: bool, drawn: Rhythm, k: int, first_day: date
) -> Iterator[Cycle]:
    """Her cycles from the `k`th on, which begins on `first_day`."""
    while True:
        cycle = Cycle(first_day, _length(seed, under_18, drawn, k), _period(seed, drawn, k))
        yield cycle
        first_day += timedelta(days=cycle.length)
        k += 1


def _length(seed: bytes, under_18: bool, drawn: Rhythm, k: int) -> int:
    """How long her `k`th cycle is."""
    strays = YOUNG_STRAYS if under_18 else ADULT_STRAYS
    length = drawn.base_cycle + _weighted(seed, "cycle", k, strays)
    return min(max(length, SHORTEST_CYCLE), LONGEST_CYCLE)


def _period(seed: bytes, drawn: Rhythm, k: int) -> int:
    """How long her period is in her `k`th cycle."""
    period = drawn.base_period + _weighted(seed, "period", k, PERIOD_STRAYS)
    return min(max(period, SHORTEST_PERIOD), LONGEST_PERIOD)


def _weighted(seed: bytes, what: str, k: int, weights: Mapping[int, int]) -> int:
    """One of the `weights`' keys, drawn by their weights, which add up to 100."""
    point = _number(seed, what, k) % 100
    for value, weight in weights.items():
        if point < weight:
            return value
        point -= weight
    raise AssertionError("weights add up to 100")


def _number(seed: bytes, what: str, k: int) -> int:
    """A number drawn from the seed for `what` in her `k`th cycle (0 for what is drawn
    once): SHA-256's first 8 bytes, big-endian. Frozen (ADR-0029)."""
    digest = hashlib.sha256(seed + f"\n{what}\n{k}".encode()).digest()
    return int.from_bytes(digest[:8], "big")
