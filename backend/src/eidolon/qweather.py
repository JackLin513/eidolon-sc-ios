"""QWeather (和风天气), for where the producer is (GLOSSARY.md「制作人档案」): finding a city by
its name or nearest a spot, in Chinese, and as she talks (GLOSSARY.md「此刻」), the day's weather
where a spot is (`weather.Today`) and the weather warnings in force there. Open-Meteo has no
warnings and finds no city by a spot, and its global models are often degrees off what the
weather apps in China say, as QWeather is not; Tokyo's weather is still Open-Meteo's
(`weather`). Only with the deployer's account: without it, the producer has no city.

Each request is signed with a JSON Web Token (Ed25519; QWeather limits API keys from 2027) on
the account's own API host. Fetched as the weather is: direct, never through the proxy, not a
service the status page or activity records know of. The day's weather at a spot (the weather
now, the hours to come and the days, each asked for at once) is kept in memory, by the grid
cell, for `KEPT_DAY`, no longer than the day where the spot is; the warnings for
`KEPT_WARNINGS`; each waited on no longer than the caller says, the fetch going on to be kept
all the same; one failing, none is asked for again of that cell for `RETRY_AFTER`. Yesterday's
highest and lowest are had of QWeather's records of the city nearest the spot, its ID looked
up once by the cell and kept, and each day's kept until the day after; these not to be had,
the day goes without them."""

import asyncio
import base64
import json
import logging
import re
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from datetime import date, datetime, timedelta, tzinfo

import httpx
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import load_pem_private_key

from eidolon.clock import Clock
from eidolon.config import QWeatherSettings
from eidolon.producer import City
from eidolon.weather import RETRY_AFTER, Kind, Spot, Today, Weather, later_of

log = logging.getLogger(__name__)

KEPT_DAY = timedelta(hours=1)
"""How long the day's weather fetched at a spot is kept: the hours to come are forecast anew
each hour."""

KEPT_WARNINGS = timedelta(hours=1)
"""How long the warnings fetched at a spot are kept."""

TOKEN_LASTS = timedelta(minutes=15)
"""How long each token signed holds; a new one is signed a minute before."""

MAX_CITIES = 10
"""How many cities a search answers with at most."""

TRIED_AT = (39.92, 116.41)
"""Where a change to the account is tried: Beijing."""

ICONS: tuple[tuple[range, Kind], ...] = (
    (range(100, 101), "clear"),
    (range(150, 151), "clear"),
    (range(101, 104), "cloudy"),
    (range(151, 154), "cloudy"),
    (range(104, 105), "overcast"),
    (range(302, 305), "thunder"),
    (range(300, 400), "rain"),
    (range(400, 500), "snow"),
    (range(500, 502), "fog"),
    (range(509, 511), "fog"),
    (range(514, 516), "fog"),
    (range(502, 509), "overcast"),
    (range(511, 514), "overcast"),
)
"""The kinds of weather, each by the QWeather icon codes it is, the first that has the code:
haze and dust, of none of the kinds, as overcast."""


def private_key_body(value: str) -> str:
    """The private key as it may be written, in PEM (its line breaks maybe written `\\n`) or
    its base64 alone, as its base64 alone: what is kept, its last 4 characters shown. Pasted
    into one line, as a browser's input field has it, its line breaks are gone."""
    value = re.sub(r"-----(?:BEGIN|END)[A-Z ]*-----", " ", value.replace("\\n", "\n"))
    return "".join(value.split())


def private_key_pem(value: str) -> str:
    """The private key as it may be written (`private_key_body`), in PEM."""
    return f"-----BEGIN PRIVATE KEY-----\n{private_key_body(value)}\n-----END PRIVATE KEY-----\n"


class QWeatherFailed(Exception):
    """QWeather could not be asked, or answered with an error, saying which."""


@dataclass(frozen=True)
class _Day:
    """What a fetch for the day's weather at a spot answered, `on` the day where the spot is
    (in `zone`): the weather `now` (None for an icon of none of the kinds); the hours to come,
    as the start of each, and their kinds; the day's highest and lowest, and yesterday's (None
    if not to be had); and when it was fetched."""

    on: date
    zone: tzinfo
    now: Weather | None
    hours: tuple[tuple[datetime, Kind | None], ...]
    high: int
    low: int
    yesterday: tuple[int, int] | None
    fetched_at: datetime

    def holds(self, at: datetime) -> bool:
        """Whether it is still to be had at `at`: kept no longer than `KEPT_DAY`, and the day
        still the one where the spot is."""
        return at - self.fetched_at < KEPT_DAY and at.astimezone(self.zone).date() == self.on

    def today(self, at: datetime) -> Today | None:
        if self.now is None:
            return None
        this_hour = at.astimezone(self.zone).replace(minute=0, second=0, microsecond=0)
        left: list[Kind | None] = [
            kind for start, kind in self.hours if this_hour < start and start.date() == self.on
        ]
        yesterday_high, yesterday_low = self.yesterday or (None, None)
        return Today(
            self.now, later_of(self.now, left), self.high, self.low, yesterday_high, yesterday_low
        )


@dataclass(frozen=True)
class _KeptWarnings:
    headlines: tuple[str, ...]
    fetched_at: datetime


class QWeather:
    """The deployer's QWeather account as `settings` has it now (None without one), asked
    over `transport` (QWeather's own by default), kept by `clock`."""

    def __init__(
        self,
        settings: Callable[[], QWeatherSettings | None],
        clock: Clock,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._settings = settings
        self._clock = clock
        self._http = httpx.AsyncClient(
            transport=transport, timeout=10, headers={"User-Agent": "eidolon-sc"},
            trust_env=False,
        )
        self._token: tuple[QWeatherSettings, str, datetime] | None = None
        self._warnings: dict[tuple[float, float], _KeptWarnings] = {}
        self._warnings_failed: dict[tuple[float, float], datetime] = {}
        self._fetching: dict[tuple[float, float], asyncio.Task[tuple[str, ...] | None]] = {}
        self._days: dict[tuple[float, float], _Day] = {}
        self._days_failed: dict[tuple[float, float], datetime] = {}
        self._fetching_days: dict[tuple[float, float], asyncio.Task[_Day | None]] = {}
        self._ids: dict[tuple[float, float], str | None] = {}
        self._yesterdays: dict[tuple[str, date], tuple[int, int]] = {}

    @property
    def on(self) -> bool:
        """Whether the deployer has an account in effect now."""
        return self._settings() is not None

    async def search(self, name: str) -> list[City]:
        """The cities by `name`, the likeliest first, `MAX_CITIES` at most. Raises
        QWeatherFailed."""
        return await self._lookup(name, settings=None)

    async def nearest(self, latitude: float, longitude: float) -> City | None:
        """The city, district or county nearest the spot; None if none. Raises
        QWeatherFailed."""
        found = await self._lookup(_location(latitude, longitude), settings=None)
        return found[0] if found else None

    async def tried(self, settings: QWeatherSettings) -> None:
        """Try the account `settings` has, finding the city at `TRIED_AT`. Raises
        QWeatherFailed saying why it does not work."""
        if not await self._lookup(_location(*TRIED_AT), settings=settings):
            raise QWeatherFailed("找不到北京，账号可能有问题")

    async def today(self, spot: Spot, wait: float) -> Today | None:
        """The day's weather at `spot`, as of now: as kept, or fetched now, waited on for no
        longer than `wait` seconds; None if it cannot be had by then or without an account."""
        if self._settings() is None:
            return None
        now = self._clock()
        kept = self._days.get(spot.cell)
        if kept is not None and kept.holds(now):
            return kept.today(now)
        failed_at = self._days_failed.get(spot.cell)
        if failed_at is not None and now - failed_at < RETRY_AFTER:
            return None
        fetching = self._fetching_days.get(spot.cell)
        if fetching is None:
            fetching = asyncio.create_task(self._fetch_day(spot))
            self._fetching_days[spot.cell] = fetching
        done, _ = await asyncio.wait({fetching}, timeout=wait)
        day = fetching.result() if done else None
        return day.today(self._clock()) if day is not None else None

    async def _fetch_day(self, spot: Spot) -> _Day | None:
        location = _location(*spot.cell)
        try:
            current, hourly, daily, city_id = await asyncio.gather(
                self._weather_api("/v7/weather/now", location),
                self._weather_api("/v7/weather/24h", location),
                self._weather_api("/v7/weather/3d", location),
                self._id_of(spot),
            )
            zone = datetime.fromisoformat(current["now"]["obsTime"]).tzinfo
            if zone is None:
                raise ValueError("no offset")
            kind = _kind(current["now"]["icon"])
            on = self._clock().astimezone(zone).date()
            days = {date.fromisoformat(d["fxDate"]): d for d in daily["daily"]}
            of_today = days[on]  # not the first day told, should it not have turned yet
            day = _Day(
                on, zone,
                Weather(kind, round(float(current["now"]["temp"]))) if kind else None,
                tuple(
                    (datetime.fromisoformat(hour["fxTime"]).astimezone(zone), _kind(hour["icon"]))
                    for hour in hourly["hourly"]
                ),
                round(float(of_today["tempMax"])), round(float(of_today["tempMin"])),
                await self._yesterday(city_id, on - timedelta(days=1)),
                self._clock(),
            )
        except (QWeatherFailed, KeyError, TypeError, ValueError, IndexError) as e:
            log.warning("could not fetch the day's weather: %s", e)
            self._days_failed[spot.cell] = self._clock()
            return None
        finally:
            self._fetching_days.pop(spot.cell, None)
        now = self._clock()
        self._days = {k: v for k, v in self._days.items() if v.holds(now)}
        self._days[spot.cell] = day
        return day

    async def _id_of(self, spot: Spot) -> str | None:
        """The ID of the city nearest `spot`, as kept or looked up; None if none, or if it
        cannot be looked up now."""
        if spot.cell in self._ids:
            return self._ids[spot.cell]
        try:
            answer = await self._get(
                "/geo/v2/city/lookup", {"location": _location(*spot.cell), "number": "1"}
            )
            code = answer.get("code")
            if code not in ("200", "404"):
                raise QWeatherFailed(f"和风天气答复 {code}")
            city_id = str(answer["location"][0]["id"]) if code == "200" else None
        except (QWeatherFailed, KeyError, TypeError, IndexError) as e:
            log.warning("could not look up the city for its records: %s", e)
            return None
        self._ids[spot.cell] = city_id
        return city_id

    async def _yesterday(self, city_id: str | None, day: date) -> tuple[int, int] | None:
        """The highest and lowest of `day` in the records of the city by `city_id` (None for
        none), as kept or asked for now; None if they cannot be had now."""
        if city_id is None:
            return None
        kept = self._yesterdays.get((city_id, day))
        if kept is None:
            try:
                answer = await self._weather_api(
                    "/v7/historical/weather", city_id, {"date": day.strftime("%Y%m%d")}
                )
                record = answer["weatherDaily"]
                kept = (round(float(record["tempMax"])), round(float(record["tempMin"])))
            except (QWeatherFailed, KeyError, TypeError, ValueError) as e:
                log.warning("could not fetch yesterday's weather: %s", e)
                return None
            self._yesterdays = {k: v for k, v in self._yesterdays.items() if k[1] >= day}
            self._yesterdays[(city_id, day)] = kept
        return kept

    async def _weather_api(
        self, path: str, location: str, params: dict[str, str] | None = None
    ) -> dict:
        """What one of the weather APIs answered for `location`; raises QWeatherFailed if it
        said it could not."""
        answer = await self._get(path, {"location": location, **(params or {})})
        if answer.get("code") != "200":
            raise QWeatherFailed(f"和风天气答复 {answer.get('code')}")
        return answer

    async def warnings(self, spot: Spot, wait: float) -> tuple[str, ...] | None:
        """The headlines of the weather warnings in force at `spot` now (`_headlines`): as
        kept, or fetched now, waited on for no longer than `wait` seconds; None if they cannot
        be had by then or without an account."""
        if self._settings() is None:
            return None
        now = self._clock()
        kept = self._warnings.get(spot.cell)
        if kept is not None and now - kept.fetched_at < KEPT_WARNINGS:
            return kept.headlines
        failed_at = self._warnings_failed.get(spot.cell)
        if failed_at is not None and now - failed_at < RETRY_AFTER:
            return None
        fetching = self._fetching.get(spot.cell)
        if fetching is None:
            fetching = asyncio.create_task(self._fetch_warnings(spot))
            self._fetching[spot.cell] = fetching
        done, _ = await asyncio.wait({fetching}, timeout=wait)
        return fetching.result() if done else None

    async def _fetch_warnings(self, spot: Spot) -> tuple[str, ...] | None:
        latitude, longitude = spot.cell
        try:
            answer = await self._get(
                f"/weatheralert/v1/current/{latitude:.2f}/{longitude:.2f}", {"lang": "zh"}
            )
            headlines = _headlines(answer.get("alerts") or ())
        except (QWeatherFailed, KeyError, TypeError, AttributeError) as e:
            log.warning("could not fetch the weather warnings: %s", e)
            self._warnings_failed[spot.cell] = self._clock()
            return None
        finally:
            self._fetching.pop(spot.cell, None)
        now = self._clock()
        self._warnings = {
            k: v for k, v in self._warnings.items() if now - v.fetched_at < KEPT_WARNINGS
        }
        self._warnings[spot.cell] = _KeptWarnings(headlines, now)
        return headlines

    async def _lookup(self, location: str, settings: QWeatherSettings | None) -> list[City]:
        answer = await self._get(
            "/geo/v2/city/lookup",
            {"location": location, "lang": "zh", "number": str(MAX_CITIES)},
            settings,
        )
        code = answer.get("code")
        if code == "404":
            return []
        if code != "200":
            raise QWeatherFailed(f"和风天气答复 {code}")
        try:
            return [
                City(
                    found["name"], found.get("adm2") or "", found.get("adm1") or "",
                    found.get("country") or "", float(found["lat"]), float(found["lon"]),
                )
                for found in answer.get("location") or ()
            ]
        except (KeyError, TypeError, ValueError) as e:
            raise QWeatherFailed(f"和风天气的答复看不懂：{type(e).__name__}") from None

    async def _get(
        self, path: str, params: dict[str, str], settings: QWeatherSettings | None = None
    ) -> dict:
        settings = settings or self._settings()
        if settings is None:
            raise QWeatherFailed("还没有配置和风天气")
        token = self._signed(settings)
        try:
            response = await self._http.get(
                f"https://{settings.host}{path}", params=params,
                headers={"Authorization": f"Bearer {token}"},
            )
        except httpx.HTTPError as e:
            raise QWeatherFailed(f"连不上和风天气：{type(e).__name__}") from None
        try:
            answer = response.json()
        except ValueError:
            answer = None
        if response.status_code != 200 or not isinstance(answer, dict):
            raise QWeatherFailed(f"和风天气答复 HTTP {response.status_code}{_why(answer)}")
        return answer

    def _signed(self, settings: QWeatherSettings) -> str:
        now = self._clock()
        if self._token is not None:
            signed_for, token, until = self._token
            if signed_for == settings and now < until - timedelta(minutes=1):
                return token
        try:
            key = load_pem_private_key(private_key_pem(settings.private_key).encode(), None)
        except (ValueError, TypeError):
            raise QWeatherFailed("私钥读不出来，需要是 Ed25519 私钥（PEM）") from None
        if not isinstance(key, Ed25519PrivateKey):
            raise QWeatherFailed("私钥需要是 Ed25519 的")
        issued = int(now.timestamp()) - 30
        until = now + TOKEN_LASTS
        header = _b64(json.dumps({"alg": "EdDSA", "kid": settings.key_id}).encode())
        payload = _b64(json.dumps({
            "sub": settings.project_id, "iss": settings.developer_id,
            "iat": issued, "exp": int(until.timestamp()),
        }).encode())
        signing = f"{header}.{payload}"
        token = f"{signing}.{_b64(key.sign(signing.encode()))}"
        self._token = (settings, token, until)
        return token

    async def aclose(self) -> None:
        for fetching in [*self._fetching.values(), *self._fetching_days.values()]:
            fetching.cancel()
        await self._http.aclose()


def _kind(icon: object) -> Kind | None:
    try:
        code = int(str(icon))
    except ValueError:
        return None
    return next((kind for codes, kind in ICONS if code in codes), None)


def _headlines(alerts: Iterable[object]) -> tuple[str, ...]:
    """The headlines of `alerts` in force, each once, in the order told, without the full
    stop the China Meteorological Administration's end with: none cancelled, nor superseded by
    another told with it (QWeather may tell an update and the warning it updates both)."""
    told = [alert for alert in alerts if isinstance(alert, dict)]
    superseded = {
        str(old) for alert in told
        for old in (alert.get("messageType") or {}).get("supersedes") or ()
    }
    headlines: dict[str, None] = {}
    for alert in told:
        headline = alert.get("headline")
        headline = headline.strip().rstrip("。").rstrip() if isinstance(headline, str) else ""
        if (
            (alert.get("messageType") or {}).get("code") != "cancel"
            and str(alert.get("id")) not in superseded
            and headline
        ):
            headlines.setdefault(headline, None)
    return tuple(headlines)


def _location(latitude: float, longitude: float) -> str:
    """A spot as QWeather takes it to look a city up: the longitude first."""
    return f"{longitude:.2f},{latitude:.2f}"


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _why(answer: object) -> str:
    """What QWeather said was wrong, if it said: its error's title and detail."""
    if isinstance(answer, dict) and isinstance(error := answer.get("error"), dict):
        said = "：".join(str(error[k]) for k in ("title", "detail") if error.get(k))
        return f"，{said}" if said else ""
    return ""
