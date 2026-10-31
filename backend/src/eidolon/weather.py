"""Tokyo's weather (GLOSSARY.md「动态」), as a moment is posted: from Open-Meteo, which wants no
key, the hourly WMO weather code and temperature at one spot in Tokyo, where its model is the
JMA's MSM. Should it be gone for good, MET Norway's Locationforecast is the one to turn to.

Fetched as the price catalogs are (`price_catalog`): direct, never through the proxy, not a
service the status page or activity records know of. Each fetch asks for `AHEAD` hours from
the one wanted, and each hour is kept in memory, by the grid cell and the hour, for `KEPT`;
one failing, none is asked for again for `RETRY_AFTER`, nor in the first `PEAK` of an hour,
when Open-Meteo drops what it cannot take: the weather is then none, as it is for a code not of
the seven kinds (`KINDS`)."""

import logging
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Literal, get_args

import httpx

from eidolon.clock import Clock

log = logging.getLogger(__name__)

URL = "https://api.open-meteo.com/v1/forecast"

TOKYO_AT = (35.6895, 139.6917)
"""Where in Tokyo the weather is of: the Metropolitan Government Building, in WGS-84."""

KEPT = timedelta(hours=3)
"""How long an hour fetched is kept: MSM is run again every three hours."""

RETRY_AFTER = timedelta(minutes=10)
"""How long after a fetch fails none is tried again."""

PEAK = timedelta(minutes=2)
"""How long into each hour none is fetched."""

AHEAD = 12
"""How many hours after the one wanted each fetch asks for besides."""

Kind = Literal["clear", "cloudy", "overcast", "fog", "rain", "snow", "thunder"]

ALL_KINDS: frozenset[str] = frozenset(get_args(Kind))

KINDS: tuple[tuple[range, Kind], ...] = (
    (range(0, 2), "clear"),
    (range(2, 3), "cloudy"),
    (range(3, 4), "overcast"),
    (range(45, 46), "fog"),
    (range(48, 49), "fog"),
    (range(51, 68), "rain"),
    (range(80, 83), "rain"),
    (range(71, 78), "snow"),
    (range(85, 87), "snow"),
    (range(95, 100), "thunder"),
)
"""The kinds of weather, each by the WMO codes it is."""

WET: frozenset[Kind] = frozenset({"rain", "snow", "thunder"})

NAMES: dict[Kind, str] = {
    "clear": "晴", "cloudy": "多云", "overcast": "阴", "fog": "雾", "rain": "雨", "snow": "雪",
    "thunder": "雷雨",
}
"""How she is told each kind."""


@dataclass(frozen=True)
class Weather:
    """One of the kinds, and the temperature in whole degrees Celsius."""

    kind: Kind
    temperature: int

    @property
    def wet(self) -> bool:
        """Whether it rains, snows or thunders: no day to be out of doors."""
        return self.kind in WET

    def shown(self) -> dict:
        return {"kind": self.kind, "temperature": self.temperature}


@dataclass(frozen=True)
class _Kept:
    """An hour's weather as fetched (None for none to be had), and when it was."""

    weather: Weather | None
    fetched_at: datetime


def weather_line(weather: Weather) -> str:
    """The line of now telling her the weather."""
    return f"东京这会儿的天气：{NAMES[weather.kind]}，{weather.temperature}°C。"


def _kind(code: object) -> Kind | None:
    if not isinstance(code, int):
        return None
    return next((kind for codes, kind in KINDS if code in codes), None)


def _weather(code: object, temperature: object) -> Weather | None:
    kind = _kind(code)
    if kind is None or not isinstance(temperature, int | float):
        return None
    return Weather(kind, round(temperature))


class Weathers:
    """Tokyo's weather, fetched over `transport` (Open-Meteo's own by default), kept by
    `clock`."""

    def __init__(self, clock: Clock, transport: httpx.AsyncBaseTransport | None = None) -> None:
        self._clock = clock
        self._http = httpx.AsyncClient(
            transport=transport, timeout=10, headers={"User-Agent": "eidolon-sc"},
            trust_env=False,
        )
        self._cell = (round(TOKYO_AT[0], 2), round(TOKYO_AT[1], 2))
        self._kept: dict[tuple[tuple[float, float], datetime], _Kept] = {}
        self._failed_at: datetime | None = None

    async def at(self, when: datetime) -> Weather | None:
        """The weather in the hour of `when`: as kept, or fetched now; None if it cannot be."""
        hour = when.astimezone(UTC).replace(minute=0, second=0, microsecond=0)
        now = self._clock()
        kept = self._kept.get((self._cell, hour))
        if kept is not None and now - kept.fetched_at < KEPT:
            return kept.weather
        into = now - now.replace(minute=0, second=0, microsecond=0)
        if into < PEAK or (self._failed_at is not None and now - self._failed_at < RETRY_AFTER):
            return None
        try:
            hours = await self._fetch(hour)
        except (httpx.HTTPError, ValueError, KeyError, TypeError) as e:
            log.warning("could not fetch the weather: %s", type(e).__name__)
            self._failed_at = now
            return None
        self._kept = {k: v for k, v in self._kept.items() if now - v.fetched_at < KEPT}
        hours.setdefault(hour, None)  # not in the answer: none to be had, not asked again
        for at, weather in hours.items():
            self._kept[(self._cell, at)] = _Kept(weather, now)
        return hours[hour]

    async def _fetch(self, hour: datetime) -> dict[datetime, Weather | None]:
        response = await self._http.get(URL, params={
            "latitude": TOKYO_AT[0], "longitude": TOKYO_AT[1],
            "hourly": "weather_code,temperature_2m", "models": "jma_msm",
            "timeformat": "unixtime",
            "start_hour": f"{hour:%Y-%m-%dT%H:%M}",
            "end_hour": f"{hour + timedelta(hours=AHEAD):%Y-%m-%dT%H:%M}",
        })
        response.raise_for_status()
        hourly = response.json()["hourly"]
        return {
            datetime.fromtimestamp(at, UTC): _weather(code, temperature)
            for at, code, temperature in zip(
                hourly["time"], hourly["weather_code"], hourly["temperature_2m"], strict=True
            )
        }

    async def aclose(self) -> None:
        await self._http.aclose()
