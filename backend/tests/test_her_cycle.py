"""Her true cycle (GLOSSARY.md「周期」, ADR-0029): where she is on a day, from her seed and
whether she is under 18 alone, derived rather than stored, the same whenever it is asked;
and her seed, from the user and the character, keyed with the deployment's secret key if
it has one."""

from collections import Counter
from datetime import date, timedelta

from eidolon.her_cycle import (
    EPOCH,
    Period,
    Premenstrual,
    Rhythm,
    cycle_seed,
    cycles,
    her_day,
    rhythm,
)

SEEDS = [cycle_seed("test-secret-key", f"user-{n}", "mano") for n in range(3000)]


def test_frozen_days_stay_where_they_are():
    """Written down once: changing any of the frozen constants turns these red, as it would
    move every her at once (ADR-0029)."""
    keyed = cycle_seed("test-secret-key", "user-0", "mano")
    plain = cycle_seed(None, "user-0", "mano")

    assert rhythm(keyed) == Rhythm(base_cycle=29, base_period=6, premenstrual_days=5, offset=27)
    assert rhythm(plain) == Rhythm(base_cycle=32, base_period=6, premenstrual_days=5, offset=16)
    assert periods_in_2026(keyed, False) == [
        ("01-03", 7), ("02-02", 6), ("03-04", 5), ("04-01", 7), ("04-28", 7), ("05-27", 7),
        ("06-22", 6), ("07-24", 7), ("08-19", 5), ("09-18", 7), ("10-16", 6), ("11-14", 6),
        ("12-12", 5),
    ]
    assert periods_in_2026(plain, True) == [
        ("01-18", 6), ("02-21", 6), ("03-24", 6), ("04-25", 6), ("05-23", 5), ("06-25", 5),
        ("07-27", 5), ("08-25", 6), ("09-24", 6), ("10-31", 7), ("12-02", 6),
    ]
    assert her_day(keyed, False, date(2026, 10, 11)) == Premenstrual(5)
    assert her_day(keyed, False, date(2026, 10, 18)) == Period(3, 6, date(2026, 10, 16))
    assert her_day(keyed, False, date(2026, 10, 22)) is None


def periods_in_2026(seed: bytes, under_18: bool) -> list[tuple[str, int]]:
    """Each of her periods beginning in 2026: its first day, as MM-DD, and its length."""
    found = []
    day = date(2026, 1, 1)
    while day.year == 2026:
        today = her_day(seed, under_18, day)
        if isinstance(today, Period) and today.day == 1:
            found.append((day.strftime("%m-%d"), today.length))
        day += timedelta(days=1)
    return found


def test_the_same_day_is_the_same_however_often_and_in_whatever_order_it_is_asked():
    seed = SEEDS[7]
    days = [date(2026, 1, 1) + timedelta(days=n) for n in range(400)]

    forwards = [her_day(seed, False, d) for d in days]
    backwards = [her_day(seed, False, d) for d in reversed(days)][::-1]

    assert forwards == backwards == [her_day(seed, False, d) for d in days]


def test_base_cycles_are_25_to_34_days_mostly_28_or_29_and_premenstrual_3_to_5():
    rhythms = [rhythm(seed) for seed in SEEDS]
    bases = Counter(r.base_cycle for r in rhythms)

    assert set(bases) == set(range(25, 35))
    assert {bases.most_common(2)[0][0], bases.most_common(2)[1][0]} == {28, 29}
    assert {r.premenstrual_days for r in rhythms} == {3, 4, 5}
    assert {r.base_period for r in rhythms} == {4, 5, 6, 7}


def test_each_cycle_strays_from_her_base_by_at_most_3_days_or_5_under_18_its_period_3_to_8():
    for under_18, most in ((False, 3), (True, 5)):
        strays: set[int] = set()
        periods: set[int] = set()
        for seed in SEEDS[:300]:
            base = rhythm(seed).base_cycle
            for _, cycle in zip(range(40), cycles(seed, under_18)):
                assert 21 <= cycle.length <= 40
                if cycle.length > 21:  # where it is not kept from straying further
                    strays.add(cycle.length - base)
                periods.add(cycle.period)
        assert strays == set(range(-most, most + 1))
        assert periods == set(range(3, 9))


def test_day_after_day_her_cycles_follow_one_another_with_no_gap_nor_overlap():
    """Years of days, from before the epoch on: each period counts up from its first day,
    the days before the next count down to it, and the next begins the day after."""
    for seed, under_18 in ((SEEDS[1], False), (SEEDS[2], True)):
        premenstrual = rhythm(seed).premenstrual_days
        day = EPOCH - timedelta(days=400)
        first_days: list[date] = []
        previous = None
        for _ in range(3000):
            today = her_day(seed, under_18, day)
            if isinstance(today, Period):
                assert today.first_day == day - timedelta(days=today.day - 1)
                if today.day == 1:
                    first_days.append(day)
                    assert previous is None or previous == Premenstrual(1)
                else:
                    assert previous == Period(today.day - 1, today.length, today.first_day)
            elif isinstance(today, Premenstrual):
                assert 1 <= today.days_left <= premenstrual
                if today.days_left == premenstrual:
                    assert not isinstance(previous, Premenstrual)
                else:
                    assert previous == Premenstrual(today.days_left + 1)
            previous = today
            day += timedelta(days=1)
        lengths = [(b - a).days for a, b in zip(first_days, first_days[1:])]
        assert len(lengths) > 80
        assert all(21 <= length <= 40 for length in lengths)


def test_hundreds_of_cycles_on_each_begins_the_day_after_the_one_before_ends():
    seed = SEEDS[4]
    hundreds = [cycle for _, cycle in zip(range(400), cycles(seed, True))]

    for cycle, after in zip(hundreds, hundreds[1:]):
        assert after.first_day == cycle.first_day + timedelta(days=cycle.length)
    for cycle in hundreds[::20]:
        assert her_day(seed, True, cycle.first_day) == Period(1, cycle.period, cycle.first_day)
        last = cycle.first_day + timedelta(days=cycle.length - 1)
        assert her_day(seed, True, last) == Premenstrual(1)


def test_seeds_differ_by_user_character_and_key():
    keyed = cycle_seed("test-secret-key", "user-1", "mano")

    assert keyed != cycle_seed(None, "user-1", "mano")
    assert keyed != cycle_seed("another-key", "user-1", "mano")
    assert keyed != cycle_seed("test-secret-key", "user-1", "kogane")
    assert keyed != cycle_seed("test-secret-key", "user-2", "mano")
    assert cycle_seed(None, "user-1", "mano") != cycle_seed(None, "user-1", "kogane")
    assert cycle_seed(None, "user-1", "mano") != cycle_seed(None, "user-2", "mano")
    assert keyed == cycle_seed("test-secret-key", "user-1", "mano")

