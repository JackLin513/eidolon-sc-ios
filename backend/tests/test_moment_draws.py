"""The draws behind moments (GLOSSARY.md「朋友圈」), given what they go by and the numbers
drawn (`FakeRandom`, each below 1000): the day's plan, of who posts and when in Tokyo, and her
everyday moment's seeds."""

from datetime import date, datetime, time

from eidolon.characters import Fact
from eidolon.moment_draws import Eligible, Planned, draw_seeds, plan_day
from eidolon.today import TOKYO
from tests.fakes import FakeRandom

DAY = date(2026, 10, 19)
MIDNIGHT = datetime.combine(DAY, time(), TOKYO)


def at(hour: int, minute: int = 0, day: date = DAY) -> datetime:
    return datetime.combine(day, time(hour, minute), TOKYO)


def test_each_is_drawn_for_by_her_tier_and_given_a_time_in_a_part_of_the_day_by_its_weight():
    """Intimate 80%, close 50%, trust 25%. The parts weigh 2, 2, 4 and 1 of 9: the morning
    from 0, lunch from 2/9, after work from 4/9, late at night from 8/9 of the draw."""
    eligible = [Eligible("mano", "intimate", False), Eligible("kogane", "close", False),
                Eligible("hiori", "trust", False)]
    random = FakeRandom(
        799, 500, 249,  # posts, doesn't, posts
        0, 500,  # the morning, 08:00
        900, 0,  # late at night, 00:00
    )

    planned = plan_day(eligible, DAY, MIDNIGHT, 3, random)

    assert planned == [Planned("hiori", at(0), False), Planned("mano", at(8), False)]


def test_on_her_birthday_she_posts_and_over_the_day_birthdays_are_kept_first():
    eligible = [Eligible("mano", "trust", False), Eligible("kogane", "trust", True),
                Eligible("hiori", "intimate", False)]
    random = FakeRandom(
        0, 0,  # Mano and Hiori post; Kogane is not drawn for
        600,  # of Mano and Hiori, the second
        500, 0,  # Kogane after work, 18:00
        500, 0,  # Hiori after work, an hour after her: 19:00
    )

    planned = plan_day(eligible, DAY, MIDNIGHT, 2, random)

    assert planned == [Planned("kogane", at(18), True), Planned("hiori", at(19), False)]


def test_only_what_is_left_of_the_day_and_none_without_an_hour_apart():
    """Planned at 23:30, only the half hour after work is left; the second has nowhere to go
    an hour apart from the first, and posts nothing."""
    eligible = [Eligible("mano", "intimate", False), Eligible("kogane", "intimate", False)]
    random = FakeRandom(0, 0, 0, 500)

    planned = plan_day(eligible, DAY, at(23, 30), 3, random)

    assert planned == [Planned("mano", at(23, 45), False)]


def test_her_seeds_are_drawn_from_her_facts_but_those_of_the_people_she_knows():
    facts = [
        Fact("档案 / 基本信息", "a"), Fact("人物关系 / 風野灯織", "b"), Fact("档案 / 兴趣", "c"),
        Fact(None, "d"), Fact("人物关系", "e"), Fact("日常 / 鸽子", "f"),
    ]

    seeds = draw_seeds(facts, FakeRandom(999, 0, 500))

    assert [s.text for s in seeds] == ["f", "a", "d"]
