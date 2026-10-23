"""Each week's jobs and each producer's schedule (GLOSSARY.md「工作」「日程」「时间段」).

**Weeks.** A week begins at Monday 0:00 Beijing time (`affinity.DAY_TIMEZONE`) and is named
by that Monday's date; its jobs are published then, and cannot be read before. They are drawn
from the job list (`job_list`) as the week is first read, and kept: the same for everyone,
and as the list was then, so a change to the list changes only the weeks not drawn yet.

**Drawing.** Four weeks make a round (`ROTATION`), counted from `FIRST_WEEK`: the round's
number shuffles every idol (the characters in idol order, but the office's staff, as the
world setting tells them) into four groups, the first ones a member more where they do not
divide evenly, and each week of the round takes its group, so every idol has a week in each
round. The week's name then draws each of its idols two or three jobs (`JOBS_EACH`), no job
twice in the week, at least one of work and at most one private each, `LENGTH_IN_ALL` slots
in all; drawn again until they are, up to `DRAW_TRIES` times, and failing that it is the job
list's fault (`ScheduleError`), which a test of the repository's list rules out.

**Schedules.** A producer's week is Monday to Sunday where they are (their effective time
zone, as「此刻」has it), each day three slots, 上午 6–12, 下午 12–18, 晚上 18–24; the hours
before 6 are in none. Their week takes the jobs of the week of the same name: west of
Beijing, the next is published on their Sunday already; east of it, their Monday begins
before their week is published. A job is placed at a day of the week and the slot it starts
in, taking as many slots in a row as it is long, within the day; kept so, not as a time, so
that it stays on the same day and slot should the producer move. Each slot holds one job,
whoever's; a slot begun or past takes none (`why_not`). Placing is saving: what is saved is
neither moved nor taken back, and there is no way to. The browser keeps the drafts.

The weeks' jobs are no one's; each producer's schedule is theirs, deleted with them
(`database.USER_DATA`), not in their data package. Nothing here calls a model or leaves an
activity record.
"""

import json
import random
import sqlite3
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta
from typing import Literal
from zoneinfo import ZoneInfo

from eidolon.affinity import DAY_TIMEZONE, day_of
from eidolon.characters import Character, in_idol_order
from eidolon.clock import Clock
from eidolon.data_access import Database
from eidolon.job_list import SLOTS, WORK, Category, ListedJob, Slot
from eidolon.producer import effective_timezone
from eidolon.store import read_profile
from eidolon.world import World

_SCHEMA = """
-- Each week's jobs, drawn as the week was first read and kept as the job list had them then:
-- the week (its Monday's date), the order drawn, whose, which listed job, and its fields.
CREATE TABLE IF NOT EXISTS weekly_jobs (
    id TEXT PRIMARY KEY,
    week TEXT NOT NULL,
    position INTEGER NOT NULL,
    character_id TEXT NOT NULL,
    listed_id TEXT NOT NULL,
    name TEXT NOT NULL,
    note TEXT NOT NULL,
    category TEXT NOT NULL,
    length INTEGER NOT NULL,
    slots TEXT
);
CREATE INDEX IF NOT EXISTS weekly_jobs_by_week ON weekly_jobs (week, position);
-- One row per job each user saved in their schedule: the day of the week (0 for Monday) and
-- the slot (0 for the morning) it starts in, when saved, and when her affinity was raised for
-- it being done (none yet).
CREATE TABLE IF NOT EXISTS schedule_placements (
    user_id TEXT NOT NULL REFERENCES users(id),
    week TEXT NOT NULL,
    job_id TEXT NOT NULL REFERENCES weekly_jobs(id),
    day INTEGER NOT NULL,
    slot INTEGER NOT NULL,
    saved_at TEXT NOT NULL,
    counted_at TEXT,
    PRIMARY KEY (user_id, week, job_id)
);
CREATE INDEX IF NOT EXISTS schedule_placements_by_week ON schedule_placements (week);
"""

FIRST_WEEK = date(2026, 1, 5)
"""The Monday the rounds are counted from: its week is the first of a round."""

ROTATION = 4
"""How many weeks make a round, in which every idol has one."""

JOBS_EACH = (2, 3)
"""How many jobs each idol of the week may be given."""

LENGTH_IN_ALL = (24, 27)
"""How many slots a week's jobs take in all, at least and at most: more than the 21 a week
has, so that not all fit."""

DRAW_TRIES = 100
"""How many times a week is drawn before the job list is blamed."""

DAYS = 7
SLOT_HOURS = 6
"""How long a slot is; the first begins at this hour too, the hours before in none."""

SLOT_NAMES: dict[Slot, str] = {"morning": "上午", "afternoon": "下午", "evening": "晚上"}

When = Literal["past", "now", "future"]

# Why a job cannot be placed where asked: the browser's own reasons (`why_not`), then the
# server's alone.
WHOLE_DAY_FROM_MORNING = "一整天的工作只能从上午排"
NO_ROOM_THAT_DAY = "当天排不下"
PAST = "已经过了"
UNDER_WAY = "正在进行"
TAKEN = "格子里有别的工作"
NOT_PUBLISHED = "这一周的工作还没有发布"
NOT_THIS_WEEK = "这项工作不在这一周"
ALREADY_SAVED = "这项工作已经保存过了"


class ScheduleError(RuntimeError):
    """The job list cannot give a week its jobs."""


class ScheduleClosed(Exception):
    """The deployment has schedules off: none can be saved."""

    def __init__(self) -> None:
        super().__init__("日程暂时没有开放")


@dataclass(frozen=True)
class Job:
    """One of a week's jobs: whose, and the listed job's fields as they were drawn."""

    id: str
    character_id: str
    name: str
    note: str
    category: Category
    length: int
    slots: tuple[Slot, ...] | None

    def shown(self) -> dict:
        return {
            "id": self.id, "character_id": self.character_id, "name": self.name,
            "note": self.note, "category": self.category, "length": self.length,
            "slots": self.slots and list(self.slots),
        }


@dataclass(frozen=True)
class Placement:
    """A job placed in a schedule: the day of the week (0 for Monday) and the slot (0 for the
    morning) it starts in."""

    job_id: str
    day: int
    slot: int

    def shown(self) -> dict:
        return {"job_id": self.job_id, "day": self.day, "slot": self.slot}


@dataclass(frozen=True)
class Week:
    """A week as the producer reads it: its jobs and what they saved of it, none before it is
    published."""

    id: date
    published_at: datetime
    jobs: list[Job]
    placements: list[Placement]
    published: bool

    def shown(self) -> dict:
        return {
            "id": self.id.isoformat(), "published": self.published,
            "published_at": self.published_at.isoformat(),
            "jobs": [j.shown() for j in self.jobs],
            "placements": [p.shown() for p in self.placements],
        }


@dataclass(frozen=True)
class ScheduleView:
    """The producer's week, and the next once published, in their time zone."""

    timezone: str
    this_week: Week
    next_week: Week | None

    def shown(self) -> dict:
        return {
            "enabled": True,
            "timezone": self.timezone,
            "this_week": self.this_week.shown(),
            "next_week": self.next_week and self.next_week.shown(),
        }


@dataclass(frozen=True)
class Saved:
    """What saving placed, and what it handed back, each with why."""

    saved: list[Placement]
    returned: list[tuple[Placement, str]]

    def shown(self) -> dict:
        return {
            "saved": [p.shown() for p in self.saved],
            "returned": [p.shown() | {"reason": why} for p, why in self.returned],
        }


def idols_of(characters: dict[str, Character], world: World | None) -> list[str]:
    """Who has jobs: the characters in idol order, but the office's staff."""
    return [
        c.id for c in in_idol_order(characters.values())
        if world is None or not world.is_staff(c.name)
    ]


def monday_of(day: date) -> date:
    return day - timedelta(days=day.weekday())


def week_of(now: datetime) -> date:
    """The week published last by `now`: the one Beijing is in."""
    return monday_of(day_of(now))


def published_at(week: date) -> datetime:
    """When `week`'s jobs are published: its Monday's 0:00 in Beijing, in UTC."""
    return datetime.combine(week, time(), ZoneInfo(DAY_TIMEZONE)).astimezone(UTC)


def draw_week(
    week: date, idols: Sequence[str], jobs: Sequence[ListedJob]
) -> list[tuple[str, ListedJob]]:
    """`week`'s idols, from `idols` in idol order, and the jobs from `jobs` each is given, in
    order. Raises ScheduleError if no draw gives a good week."""
    round_number, group = divmod((week - FIRST_WEEK).days // DAYS, ROTATION)
    shuffled = list(idols)
    random.Random(f"round {round_number}").shuffle(shuffled)
    size, more = divmod(len(shuffled), ROTATION)
    start = group * size + min(group, more)
    of_the_week = shuffled[start:start + size + (group < more)]
    drawing = random.Random(f"week {week.isoformat()}")
    least, most = LENGTH_IN_ALL
    for _ in range(DRAW_TRIES):
        drawn = _draw_once(drawing, of_the_week, jobs)
        if drawn is not None and least <= sum(j.length for _, j in drawn) <= most:
            return drawn
    raise ScheduleError(
        f"工作清单抽不出 {week} 这一周的工作：每位 {JOBS_EACH[0]} 到 {JOBS_EACH[1]} 项、"
        f"至少一项工作类、最多一项私人、总时长 {least} 到 {most} 段，试了 {DRAW_TRIES} 次都不行"
    )


def _draw_once(
    drawing: random.Random, idols: Sequence[str], jobs: Sequence[ListedJob]
) -> list[tuple[str, ListedJob]] | None:
    """Each of `idols` given jobs from `jobs` once, each job once, at least one of work and
    at most one private each, in any length; None if the jobs run out."""
    left = list(jobs)
    drawing.shuffle(left)
    drawn = []
    for idol in idols:
        work = next((j for j in left if j.category in WORK), None)
        if work is None:
            return None
        left.remove(work)
        given = [work]
        for _ in range(drawing.choice(JOBS_EACH) - 1):
            private = any(j.category == "private" for j in given)
            more = next((j for j in left if not (private and j.category == "private")), None)
            if more is None:
                return None
            left.remove(more)
            given.append(more)
        drawn.extend((idol, j) for j in given)
    return drawn


def when(local: datetime, this_week: date, week: date, day: int, slot: int) -> When:
    """Whether the slot of `week`'s day is past, under way or to come, it being `local` where
    the producer is, in their `this_week`. Before the first slot of a day, all its slots are
    to come."""
    if week != this_week:
        return "past" if week < this_week else "future"
    today = local.weekday()
    if day != today:
        return "past" if day < today else "future"
    if local.hour < SLOT_HOURS:
        return "future"
    current = local.hour // SLOT_HOURS - 1
    return "past" if slot < current else "now" if slot == current else "future"


def why_not(
    job: Job,
    day: int,
    slot: int,
    when_of: Callable[[int, int], When],
    taken: Callable[[int, int], bool],
) -> str | None:
    """Why `job` cannot start at the slot of the day, or None if it can, as the browser
    tells it: `when_of` a day's slot is, and whether one is `taken` by another job."""
    if slot + job.length > len(SLOTS):
        return WHOLE_DAY_FROM_MORNING if job.length == len(SLOTS) else NO_ROOM_THAT_DAY
    for s in range(slot, slot + job.length):
        match when_of(day, s):
            case "past":
                return PAST
            case "now":
                return UNDER_WAY
        if job.slots is not None and SLOTS[s] not in job.slots:
            return f"只能排在{_joined([SLOT_NAMES[n] for n in job.slots])}"
        if taken(day, s):
            return TAKEN
    return None


def _joined(names: list[str]) -> str:
    return names[0] if len(names) == 1 else "、".join(names[:-1]) + "和" + names[-1]


class Schedules:
    """Each week's jobs and every producer's schedule, kept in the database."""

    def __init__(
        self,
        db: Database,
        clock: Clock,
        is_on: Callable[[], bool],
        idols: Sequence[str],
        job_list: Sequence[ListedJob],
    ) -> None:
        """`is_on` tells whether schedules are on now (the live configuration's switch);
        weeks are drawn for `idols` from `job_list`."""
        self._db = db
        self._clock = clock
        self._is_on = is_on
        self._idols = list(idols)
        self._job_list = list(job_list)
        db.prepare(_open)

    async def read(self, user_id: str, device_timezone: str | None) -> ScheduleView | None:
        """The user's week and the next once published, their jobs drawn if not yet; None
        while schedules are off. Read first, and written only to draw a week."""
        if not self._is_on():
            return None
        now = self._clock()
        found = await self._db.read(self._read, user_id, device_timezone, now, False)
        if found is None:
            found = await self._db.write(self._read, user_id, device_timezone, now, True)
        assert found is not None
        return found

    async def save(
        self,
        user_id: str,
        week: date,
        placements: Sequence[Placement],
        device_timezone: str | None,
    ) -> Saved:
        """Save each of `placements` in the user's `week` that can be, in order, so that
        each finds the slots taken by those saved before it; hand back the others, with why.
        In one transaction, so that two saving at once take a slot once. Raises
        ScheduleClosed while schedules are off."""
        if not self._is_on():
            raise ScheduleClosed()
        return await self._db.write(
            self._save, user_id, week, list(placements), device_timezone, self._clock()
        )

    async def scheduled_this_week(self) -> int:
        """How many users have saved any of the week Beijing is in."""
        return await self._db.read(_scheduled, week_of(self._clock()))

    def _read(
        self,
        db: sqlite3.Connection,
        user_id: str,
        device_timezone: str | None,
        now: datetime,
        drawing: bool,
    ) -> ScheduleView | None:
        """The user's weeks at `now`, read through `db`: drawing a published week's jobs if
        `drawing`, else None if one is yet to be drawn."""
        timezone = effective_timezone(read_profile(db, user_id), device_timezone)
        this_week = monday_of(now.astimezone(ZoneInfo(timezone)).date())
        weeks = []
        for week in (this_week, this_week + timedelta(days=DAYS)):
            published = now >= published_at(week)
            jobs = _jobs(db, week) if published else []
            if published and not jobs:
                if not drawing:
                    return None
                jobs = self._draw(db, week)
            weeks.append(Week(
                week, published_at(week), jobs,
                _placements(db, user_id, week) if published else [], published,
            ))
        this, following = weeks
        return ScheduleView(timezone, this, following if following.published else None)

    def _draw(self, db: sqlite3.Connection, week: date) -> list[Job]:
        """Draw `week`'s jobs and keep them, through `db`."""
        drawn = draw_week(week, self._idols, self._job_list)
        db.executemany(
            "INSERT INTO weekly_jobs (id, week, position, character_id, listed_id, name, note,"
            " category, length, slots) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (f"{week.isoformat()}-{j.id}", week.isoformat(), n, idol, j.id, j.name, j.note,
                 j.category, j.length, j.slots and json.dumps(j.slots))
                for n, (idol, j) in enumerate(drawn)
            ],
        )
        return _jobs(db, week)

    def _save(
        self,
        db: sqlite3.Connection,
        user_id: str,
        week: date,
        placements: list[Placement],
        device_timezone: str | None,
        now: datetime,
    ) -> Saved:
        timezone = effective_timezone(read_profile(db, user_id), device_timezone)
        local = now.astimezone(ZoneInfo(timezone))
        this_week = monday_of(local.date())
        published = now >= published_at(week)
        jobs = {j.id: j for j in _jobs(db, week)} if published else {}
        placed = _placements(db, user_id, week)
        saved_ids = {p.job_id for p in placed}
        taken = {
            (p.day, s) for p in placed for s in range(p.slot, p.slot + jobs[p.job_id].length)
        }
        saved: list[Placement] = []
        returned: list[tuple[Placement, str]] = []
        for p in placements:
            job = jobs.get(p.job_id)
            if not published:
                why = NOT_PUBLISHED
            elif job is None:
                why = NOT_THIS_WEEK
            elif p.job_id in saved_ids:
                why = ALREADY_SAVED
            else:
                why = why_not(
                    job, p.day, p.slot,
                    lambda day, slot: when(local, this_week, week, day, slot),
                    lambda day, slot: (day, slot) in taken,
                )
            if why is not None:
                returned.append((p, why))
                continue
            assert job is not None
            db.execute(
                "INSERT INTO schedule_placements (user_id, week, job_id, day, slot, saved_at)"
                " VALUES (?, ?, ?, ?, ?, ?)",
                (user_id, week.isoformat(), p.job_id, p.day, p.slot, now.isoformat()),
            )
            saved.append(p)
            saved_ids.add(p.job_id)
            taken.update((p.day, s) for s in range(p.slot, p.slot + job.length))
        return Saved(saved, returned)


def _open(db: sqlite3.Connection) -> None:
    db.executescript(_SCHEMA)


def _jobs(db: sqlite3.Connection, week: date) -> list[Job]:
    """`week`'s jobs as drawn, in order; none if not drawn yet."""
    rows = db.execute(
        "SELECT id, character_id, name, note, category, length, slots FROM weekly_jobs"
        " WHERE week = ? ORDER BY position",
        (week.isoformat(),),
    ).fetchall()
    return [
        Job(id, character_id, name, note, category, length, slots and tuple(json.loads(slots)))
        for id, character_id, name, note, category, length, slots in rows
    ]


def _placements(db: sqlite3.Connection, user_id: str, week: date) -> list[Placement]:
    """What the user saved of `week`, in the order of the days and slots."""
    rows: Iterable[tuple[str, int, int]] = db.execute(
        "SELECT job_id, day, slot FROM schedule_placements WHERE user_id = ? AND week = ?"
        " ORDER BY day, slot",
        (user_id, week.isoformat()),
    )
    return [Placement(*row) for row in rows]


def _scheduled(db: sqlite3.Connection, week: date) -> int:
    (count,) = db.execute(
        "SELECT COUNT(DISTINCT user_id) FROM schedule_placements WHERE week = ?",
        (week.isoformat(),),
    ).fetchone()
    return count
