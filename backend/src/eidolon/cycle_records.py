"""The periods each user writes down of each character (GLOSSARY.md「周期」「推算」), and
what is estimated of her from them (`cycle_estimate`), worked out as they are read, never
stored; nothing of her true cycle (`her_cycle`) is read here, nor shown.

A record is its first day, a calendar day where the producer was as they wrote it down, not
moved should they move, and how many days, `FEWEST_DAYS` to `MOST_DAYS`. Its first day is
not after today in their effective time zone (their profile's, else their device's, else
Shanghai), and it does not overlap another of hers: one ending the day before another
begins does not. Any of the characters configured may have records, whether the user has
talked with her or not.

While the deployment or the user has cycles off, none are read or written; they are kept
all the same, there again once both are on. The user's data, deleted with them
(`database.USER_DATA`), not with a conversation."""

import sqlite3
import uuid
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Literal

from eidolon.characters import Character, in_idol_order
from eidolon.clock import Clock
from eidolon.cycle_estimate import Estimate, Logged, estimate
from eidolon.cycles import Cycles, CyclesOff
from eidolon.data_access import Database
from eidolon.producer import effective_timezone, local_date
from eidolon.store import read_profile

_SCHEMA = """
-- One row per period each user wrote down of each character: its first day (YYYY-MM-DD,
-- the calendar day where they were), how many days, and when it was written down.
CREATE TABLE IF NOT EXISTS cycle_records (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    character_id TEXT NOT NULL,
    first_day TEXT NOT NULL,
    days INTEGER NOT NULL,
    recorded_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS cycle_records_by_user ON cycle_records (user_id, character_id);
"""

FEWEST_DAYS, MOST_DAYS = 1, 10

Refusal = Literal["future", "days", "overlap"]


@dataclass(frozen=True)
class Record:
    id: str
    first_day: date
    days: int

    def overlaps(self, first_day: date, days: int) -> bool:
        return (
            first_day < self.first_day + timedelta(days=self.days)
            and self.first_day < first_day + timedelta(days=days)
        )

    def shown(self) -> dict:
        return {"id": self.id, "first_day": self.first_day.isoformat(), "days": self.days}


@dataclass(frozen=True)
class HerRecords:
    """A character's records, by first day, and what is estimated of her from them."""

    character_id: str
    records: list[Record]
    estimate: Estimate | None

    def shown(self) -> dict:
        return {
            "character_id": self.character_id,
            "records": [r.shown() for r in self.records],
            "estimate": self.estimate and self.estimate.shown(),
        }


@dataclass(frozen=True)
class CyclesView:
    """Every character's records and estimate, in idol order, on the producer's today."""

    today: date
    characters: list[HerRecords]

    def shown(self) -> dict:
        return {
            "enabled": True,
            "today": self.today.isoformat(),
            "characters": [c.shown() for c in self.characters],
        }


class NotFound(Exception):
    """No such character is configured, or no such record is the user's."""


class Refused(Exception):
    """A record that cannot be written down: its first day after today, its days out of
    bounds, or overlapping another (`overlapping`)."""

    def __init__(self, reason: Refusal, overlapping: Record | None = None) -> None:
        self.reason: Refusal = reason
        self.overlapping = overlapping
        super().__init__(_REFUSED[reason](overlapping))


_REFUSED = {
    "future": lambda _: "不能记未来",
    "days": lambda _: f"天数应在 {FEWEST_DAYS} 到 {MOST_DAYS} 天之间",
    "overlap": lambda r: (
        f"和 {r.first_day.month}月{r.first_day.day}日 那次重叠了，要改就编辑那一次"
    ),
}


class CycleRecords:
    def __init__(
        self,
        db: Database,
        clock: Clock,
        characters: Mapping[str, Character],
        cycles: Cycles,
    ) -> None:
        """Read and written while `cycles` has both switches on for the user."""
        self._db = db
        self._clock = clock
        self._characters = characters
        self._cycles = cycles
        db.prepare(_open)

    async def read(self, user_id: str, device_timezone: str | None) -> CyclesView | None:
        """Every character's records and estimate; None while cycles are off."""
        if not await self._on(user_id):
            return None
        return await self._db.read(self._read, user_id, device_timezone, self._clock())

    async def add(
        self,
        user_id: str,
        character_id: str,
        first_day: date,
        days: int,
        device_timezone: str | None,
    ) -> HerRecords:
        """Write down a period of the character's; her records and estimate after. Raises
        CyclesOff, NotFound for a character not configured, Refused."""
        await self._open_to(user_id)
        if character_id not in self._characters:
            raise NotFound
        return await self._db.write(
            self._write, user_id, character_id, None, (first_day, days), device_timezone,
            self._clock(),
        )

    async def change(
        self,
        user_id: str,
        record_id: str,
        first_day: date,
        days: int,
        device_timezone: str | None,
    ) -> HerRecords:
        """Change one of the user's records; its character's records and estimate after.
        Raises CyclesOff, NotFound for a record not theirs, Refused."""
        await self._open_to(user_id)
        return await self._db.write(
            self._write, user_id, None, record_id, (first_day, days), device_timezone,
            self._clock(),
        )

    async def remove(
        self, user_id: str, record_id: str, device_timezone: str | None
    ) -> HerRecords:
        """Delete one of the user's records; its character's records and estimate after.
        Raises CyclesOff, NotFound for a record not theirs."""
        await self._open_to(user_id)
        return await self._db.write(
            self._write, user_id, None, record_id, None, device_timezone, self._clock()
        )

    async def _on(self, user_id: str) -> bool:
        return await self._cycles.switch_of(user_id) is True

    async def _open_to(self, user_id: str) -> None:
        if not await self._on(user_id):
            raise CyclesOff

    def _read(
        self, db: sqlite3.Connection, user_id: str, device_timezone: str | None, now: datetime
    ) -> CyclesView:
        today = _today(db, user_id, device_timezone, now)
        return CyclesView(today, [
            _hers(db, user_id, c.id, today) for c in in_idol_order(self._characters.values())
        ])

    def _write(
        self,
        db: sqlite3.Connection,
        user_id: str,
        character_id: str | None,
        record_id: str | None,
        written: tuple[date, int] | None,
        device_timezone: str | None,
        now: datetime,
    ) -> HerRecords:
        """Write down a new period of `character_id`'s, or change `record_id` to `written`,
        or delete it where nothing is."""
        if record_id is not None:
            row = db.execute(
                "SELECT character_id FROM cycle_records WHERE id = ? AND user_id = ?",
                (record_id, user_id),
            ).fetchone()
            if row is None or row[0] not in self._characters:
                raise NotFound
            character_id = row[0]
        assert character_id is not None
        today = _today(db, user_id, device_timezone, now)
        if written is None:
            db.execute("DELETE FROM cycle_records WHERE id = ?", (record_id,))
            return _hers(db, user_id, character_id, today)
        first_day, days = written
        if first_day > today:
            raise Refused("future")
        if not FEWEST_DAYS <= days <= MOST_DAYS:
            raise Refused("days")
        others = [r for r in _records(db, user_id, character_id) if r.id != record_id]
        overlapping = next((r for r in others if r.overlaps(first_day, days)), None)
        if overlapping is not None:
            raise Refused("overlap", overlapping)
        if record_id is None:
            db.execute(
                "INSERT INTO cycle_records (id, user_id, character_id, first_day, days,"
                " recorded_at) VALUES (?, ?, ?, ?, ?, ?)",
                (uuid.uuid4().hex, user_id, character_id, first_day.isoformat(), days,
                 now.isoformat()),
            )
        else:
            db.execute(
                "UPDATE cycle_records SET first_day = ?, days = ? WHERE id = ?",
                (first_day.isoformat(), days, record_id),
            )
        return _hers(db, user_id, character_id, today)


def _open(db: sqlite3.Connection) -> None:
    db.executescript(_SCHEMA)


def _today(
    db: sqlite3.Connection, user_id: str, device_timezone: str | None, now: datetime
) -> date:
    return local_date(now, effective_timezone(read_profile(db, user_id), device_timezone))


def _records(db: sqlite3.Connection, user_id: str, character_id: str) -> list[Record]:
    rows = db.execute(
        "SELECT id, first_day, days FROM cycle_records WHERE user_id = ? AND character_id = ?"
        " ORDER BY first_day",
        (user_id, character_id),
    )
    return [Record(id, date.fromisoformat(first_day), days) for id, first_day, days in rows]


def _hers(db: sqlite3.Connection, user_id: str, character_id: str, today: date) -> HerRecords:
    records = _records(db, user_id, character_id)
    logged: Sequence[Logged] = [Logged(r.first_day, r.days) for r in records]
    return HerRecords(character_id, records, estimate(logged, today))
