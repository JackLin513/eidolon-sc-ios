"""The calendar over HTTP (GLOSSARY.md「日历」): Japan's holidays of a year, at
`/api/calendar/holidays?year=YYYY`, for those signed in. The birthdays come with the
character list and the producer profile."""

import re

from fastapi import FastAPI, Response

from eidolon.japan_holidays import holidays_of
from eidolon.sessions import UserId

_KEPT_A_DAY = {"Cache-Control": "private, max-age=86400"}
"""A year's holidays change only as the law does, and the library with it."""

_YEAR = re.compile(r"[0-9]{1,4}")


def add_calendar_routes(app: FastAPI) -> None:
    @app.get("/api/calendar/holidays")
    def holidays(_: UserId, response: Response, year: str = "") -> list[dict]:
        """The holidays of `year`, by date; none for what is no year, or one without any
        known."""
        response.headers.update(_KEPT_A_DAY)
        if not _YEAR.fullmatch(year):
            return []
        return [{"date": day.isoformat(), "name": name} for day, name in holidays_of(int(year))]
