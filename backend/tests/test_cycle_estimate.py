"""Estimating her cycle from the user's records alone (GLOSSARY.md「推算」), as LAPLACE
Cycles does: none without records; 28 and 5 days, roughly, from one; from more, the median
of the latest gaps, those that look like a period missed set aside or folded; faded, and
why; the next three periods and the days before each; how far off the past estimates were;
and where today is."""

from datetime import date, timedelta

from eidolon.cycle_estimate import Estimated, Logged, Premenstrual, Recorded, estimate

TODAY = date(2026, 10, 25)


def logged(*gaps: int, first: date = date(2026, 1, 5), days: int = 5) -> list[Logged]:
    """Records `gaps` days apart from `first` on, each `days` days long."""
    records = [Logged(first, days)]
    for gap in gaps:
        records.append(Logged(records[-1].first_day + timedelta(days=gap), days))
    return records


def ending_before(records: list[Logged], today: date = TODAY) -> list[Logged]:
    """`records` moved so that the last begins 10 days before `today`."""
    shift = today - timedelta(days=10) - records[-1].first_day
    return [Logged(r.first_day + shift, r.days) for r in records]


def test_without_records_there_is_no_estimate():
    assert estimate([], TODAY) is None


def test_from_one_record_it_is_28_and_5_days_roughly():
    found = estimate([Logged(date(2026, 10, 20), 4)], TODAY)

    assert found is not None
    assert (found.cycle, found.period, found.reasons) == (28, 5, ("once",))
    assert found.periods[0] == (date(2026, 11, 17), 5)
    assert found.off_by is None


def test_from_one_record_longer_than_5_days_its_days_are_kept():
    found = estimate([Logged(date(2026, 10, 20), 7)], TODAY)

    assert found is not None
    assert found.period == 7


def test_from_regular_records_the_latest_8_gaps_median_and_6_periods_median():
    gaps = [22, 22, 22, 30, 30, 30, 30, 31, 31, 31, 31]
    days = [3] * 6 + [4, 6, 6, 5, 7, 6]
    records = [
        Logged(r.first_day, d) for r, d in zip(ending_before(logged(*gaps)), days, strict=True)
    ]

    found = estimate(records, TODAY)

    assert found is not None
    assert (found.cycle, found.period, found.reasons) == (31, 6, ())


def test_how_far_off_each_ended_cycle_was_estimated_from_the_records_before_it():
    # 28 against 30; 30 (from one gap) against 28; 29 against 32.
    found = estimate(ending_before(logged(30, 28, 32)), TODAY)

    assert found is not None
    assert found.off_by == 2.3


def test_how_far_off_needs_two_compared():
    found = estimate(ending_before(logged(30)), TODAY)

    assert found is not None
    assert found.off_by is None


def test_how_far_off_leaves_out_gaps_out_of_bounds_or_1_6_times_the_estimate():
    beyond_60 = estimate(ending_before(logged(30, 70, 29, 29)), TODAY)
    missed = estimate(ending_before(logged(30, 50, 30)), TODAY)

    assert beyond_60 is not None and missed is not None
    assert (beyond_60.off_by, missed.off_by) == (1.3, 1.0)


def test_gaps_shorter_than_15_or_longer_than_60_days_are_set_aside_as_missed():
    shorter = estimate(ending_before(logged(29, 10, 30)), TODAY)
    longer = estimate(ending_before(logged(29, 65, 30)), TODAY)

    assert shorter is not None and longer is not None
    assert (shorter.cycle, shorter.reasons) == (30, ("missed",))
    assert (longer.cycle, longer.reasons) == (30, ("missed",))


def test_a_gap_1_6_times_the_shortest_or_more_is_set_aside_as_missed():
    found = estimate(ending_before(logged(28, 56, 29)), TODAY)

    assert found is not None
    assert (found.cycle, found.reasons) == (29, ("missed",))


def test_the_shortest_gap_is_taken_as_22_days_at_least():
    found = estimate(ending_before(logged(16, 30, 31)), TODAY)

    assert found is not None
    assert (found.cycle, found.reasons) == (30, ("irregular",))


def test_one_or_two_long_gaps_alone_are_folded_into_typical_cycles():
    def cycle_of(*gaps: int) -> tuple[int, tuple[str, ...]]:
        found = estimate(ending_before(logged(*gaps)), TODAY)
        assert found is not None
        return found.cycle, found.reasons

    assert cycle_of(56) == (28, ("missed",))
    assert cycle_of(84) == (28, ("missed",))
    assert cycle_of(50) == (25, ("missed",))
    assert cycle_of(50, 56) == (27, ("missed",))


def test_from_a_third_long_gap_her_cycle_is_taken_to_be_long():
    found = estimate(ending_before(logged(50, 50, 50)), TODAY)

    assert found is not None
    assert (found.cycle, found.reasons) == (50, ())


def test_gaps_more_than_7_days_apart_are_irregular():
    seven = estimate(ending_before(logged(26, 33)), TODAY)
    eight = estimate(ending_before(logged(26, 34)), TODAY)

    assert seven is not None and eight is not None
    assert (seven.reasons, eight.reasons) == ((), ("irregular",))


def test_past_the_next_first_day_it_may_not_be_written_down_and_stays_where_it_was():
    record = Logged(date(2026, 9, 27), 5)

    on_the_day = estimate([record], date(2026, 10, 25))
    past_it = estimate([record], date(2026, 10, 26))

    assert on_the_day is not None and past_it is not None
    assert on_the_day.reasons == ("once",)
    assert past_it.reasons == ("once", "late")
    assert past_it.periods[0] == (date(2026, 10, 25), 5)


def test_three_periods_are_estimated_a_cycle_apart():
    found = estimate(logged(30, first=date(2026, 9, 1), days=4), TODAY)

    assert found is not None
    assert found.periods == (
        (date(2026, 10, 31), 4), (date(2026, 11, 30), 4), (date(2026, 12, 30), 4),
    )


def test_where_today_is():
    records = logged(30, first=date(2026, 9, 1), days=4)  # next on 10-31, then 11-30

    def where(day: date) -> object:
        found = estimate(records, day)
        assert found is not None
        return found.today

    assert where(date(2026, 10, 3)) == Recorded(3)
    assert where(date(2026, 10, 25)) is None
    assert where(date(2026, 10, 26)) == Premenstrual()
    assert where(date(2026, 10, 30)) == Premenstrual()
    assert where(date(2026, 11, 3)) == Estimated()
    assert where(date(2026, 11, 4)) is None
    assert where(date(2026, 11, 25)) == Premenstrual()
