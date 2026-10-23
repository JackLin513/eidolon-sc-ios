"""Japan's holidays (GLOSSARY.md「节假日」): the national holidays by law, substitute holidays
(振替休日) and citizens' holidays (国民の休日) among them, with their Japanese names, as the
`holidays` library reckons them. The New Year's break, お盆 and the days of Golden Week that
are no holiday by law are none. The calendar shows them, and she is told of the one it is
today; both from here, so that the two always agree."""

from datetime import date
from functools import lru_cache

import holidays


@lru_cache(maxsize=16)
def holidays_of(year: int) -> tuple[tuple[date, str], ...]:
    """The holidays of `year`, by date, each with its name; none for a year the library
    reckons none for (before 1949, say, or too far ahead)."""
    try:
        found = holidays.country_holidays("JP", years=year, language="ja")
    except (NotImplementedError, ValueError, OverflowError):
        return ()
    return tuple(sorted(found.items()))


def holiday_on(day: date) -> str | None:
    """The name of the holiday `day` is, if it is one."""
    return dict(holidays_of(day.year)).get(day)
