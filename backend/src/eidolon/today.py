"""What she is told of the day it is in Tokyo, where she lives (GLOSSARY.md「日历」): whether
it is her birthday, whose of the others' it is, which of Japan's holidays it is, and which
of the live days she stood on fell on it in years before, told as past. Each
line is told only on its day, after what she is told of now (`producer.now_prompt`), in the
same section, in a typed turn, a call or a reach-out alike; none on a day that is none of
them. The producer's own birthday goes by their day, and is told by `now_prompt`."""

from collections.abc import Iterable, Sequence
from datetime import date, datetime
from zoneinfo import ZoneInfo

from eidolon.characters import Character, in_idol_order
from eidolon.japan_holidays import holiday_on
from eidolon.producer import Talking, is_birthday
from eidolon.world import Live, LiveDay

TOKYO = ZoneInfo("Asia/Tokyo")

_HER_BIRTHDAY = (
    "今天是你的生日。可以自然地提起一两次，不要每句都提；不向制作人要礼物；制作人祝福你就接受。"
)


def tokyo_date(now: datetime) -> date:
    """The day it is in Tokyo at `now`."""
    return now.astimezone(TOKYO).date()


def today_lines(
    now: datetime,
    character: Character,
    characters: Iterable[Character],
    talking: Talking,
    her_lives: Sequence[tuple[Live, Sequence[LiveDay]]],
) -> list[str]:
    """What `character` is told of the day it is in Tokyo at `now`, `talking` with the
    producer as she is (alike for now in each way): her birthday, the birthdays of the others
    among `characters`, in idol order, the holiday, each if it is the day; then each of the
    days of `her_lives` (`World.lives_of`) on this day in a year before, earliest first."""
    today = tokyo_date(now)
    lines: list[str] = []
    if is_birthday(character.birthday, today):
        lines.append(_HER_BIRTHDAY)
    others = [
        c.name for c in in_idol_order(characters)
        if c.id != character.id and is_birthday(c.birthday, today)
    ]
    if others:
        lines.append(
            f"今天是{'、'.join(others)}的生日。可以顺口提一句，不要替她们向制作人要祝福，"
            "也不要催制作人做什么。"
        )
    if holiday := holiday_on(today):
        lines.append(f"今天是日本的节假日：{holiday}。可以自然地提到，不必每句都说。")
    lines += _lives_on_this_day(today, her_lives)
    return lines


def _lives_on_this_day(
    today: date, her_lives: Sequence[tuple[Live, Sequence[LiveDay]]]
) -> list[str]:
    """A line for each of the days she stood on that fell on `today`'s month and day in a
    year before: told as past, the date with its year matching today's otherwise, so that
    she is not to take it for today."""
    found = [
        (day.date, live, day) for live, days in her_lives for day in days
        if day.date.year < today.year and (day.date.month, day.date.day) == (today.month, today.day)
    ]
    lines = []
    for when, live, day in sorted(found, key=lambda f: f[0]):
        which = f"第{live.days.index(day) + 1}天" if len(live.days) > 1 else ""
        lines.append(
            f"今天是{today.year - when.year}年前你站上「{live.name}」{which}的日子"
            f"（{when.year}年{when.month}月{when.day}日，{day.venue}）。那是过去的事，今天没有这场演出；"
            "可以当回忆顺口提一句，不要说成今天的事。"
        )
    return lines


def her_birthday(character: Character) -> str:
    """Her birthday as she always knows it, the same for every user."""
    return f"你的生日是{character.birthday.month}月{character.birthday.day}日。"
