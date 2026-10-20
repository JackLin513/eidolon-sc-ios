"""What happens between the user and the characters, as it happens (GLOSSARY.md「每日任务」):
a turn recorded, typed or in a call alike, and a gift given. Each is told here once, and
whatever it counts towards is kept and rewarded here: today's daily tasks, and the
achievements (`achievements`).

The daily tasks are the same each day (`DAILY_TASKS`), the day in Beijing wherever the user
is (`affinity.day_of`), by the clock as each happens: what was done the day before counts
not. Each done gives its draw chances through the gifts (`Gifts.reward`), once a day, in the
same transaction as what was done is kept, so that two done at once are rewarded once. So
does each achievement's stage unlocked, and each character complete.

Only what is told here counts: a turn refused or failed is never recorded, so never told; a
data package's turns and gifts are put in the database, not told; deleting a past
conversation takes nothing back. Nothing is kept while affinity and gifts are closed
(`LiveConfig.affinity_on`); what was kept before stays. Keeping it failing is only logged,
as the turn or the gift it was told of is recorded already.

Each task done, once its reward is given, has an activity record (`ActivityLog.daily_task_done`)
for the dashboard to count; writing it failing is only logged too.

Each user's progress today and with the achievements is theirs, deleted with them (`database.USER_DATA`), and goes in
no data package."""

import logging
import sqlite3
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path
from typing import Literal

from eidolon import achievements
from eidolon.achievements import Completed, Hers, Progress, Unlocked
from eidolon.activity import ActivityLog
from eidolon.affinity import day_of, next_day
from eidolon.clock import Clock
from eidolon.database import connect
from eidolon.gifts import Gifts, GiftsClosed, Reward

log = logging.getLogger(__name__)

_SCHEMA = """
-- One row per user who has done anything towards a daily task: the day it was last on
-- (`affinity.day_of`), and how many turns and gifts that day.
CREATE TABLE IF NOT EXISTS daily_task_progress (
    user_id TEXT PRIMARY KEY REFERENCES users(id),
    day TEXT NOT NULL,
    turns INTEGER NOT NULL,
    gifts INTEGER NOT NULL
);
"""


@dataclass(frozen=True)
class Counts:
    """What a user did in a day that daily tasks count: turns and gifts given."""

    turns: int
    gifts: int

    def __add__(self, other: "Counts") -> "Counts":
        return Counts(self.turns + other.turns, self.gifts + other.gifts)


@dataclass(frozen=True)
class DailyTask:
    """A daily task: done as the day's `counts` reach `goal`, giving `draws` draw chances."""

    id: str
    counts: Literal["turns", "gifts"]
    goal: int
    draws: int = 1

    def of(self, counts: Counts) -> int:
        """How far `counts` take it, past its goal or not."""
        return getattr(counts, self.counts)


DAILY_TASKS = (
    DailyTask("one_turn", "turns", 1),
    DailyTask("one_gift", "gifts", 1),
    DailyTask("ten_turns", "turns", 10),
)
"""Each day's daily tasks, in the order the gifts page shows them."""


@dataclass(frozen=True)
class Rewarded:
    """What something the user did was rewarded with: draw chances, reset cards, the daily
    tasks it did, the achievements' stages it unlocked and the characters it completed; and
    when, by the time the rewards are kept by, for the browser to tell what it has seen."""

    draws: int
    reset_cards: int
    daily_tasks: list[str]
    rewarded_at: datetime
    achievements: list[Unlocked] = field(default_factory=list)
    completed: list[Completed] = field(default_factory=list)

    def shown(self) -> dict:
        """As the browser is told it."""
        return {
            "draws": self.draws,
            "reset_cards": self.reset_cards,
            "daily_tasks": self.daily_tasks,
            "achievements": [u.shown() for u in self.achievements],
            "completed": [c.shown() for c in self.completed],
            "rewarded_at": self.rewarded_at.isoformat(),
        }


@dataclass(frozen=True)
class DailyTasks:
    """How far the user is with today's daily tasks, and when they begin again."""

    progress: list[tuple[DailyTask, int]]
    """Each task, and how far towards its goal, no further than it."""
    renews_at: datetime

    def shown(self) -> dict:
        """As the browser is told it."""
        return {
            "tasks": [
                {"id": t.id, "done": p >= t.goal, "progress": p, "goal": t.goal, "draws": t.draws}
                for t, p in self.progress
            ],
            "renews_at": self.renews_at.isoformat(),
        }


class Happenings:
    """What happens between users and characters, kept in the database at `path` next to
    the gifts they are rewarded with."""

    def __init__(
        self,
        path: Path,
        clock: Clock,
        is_open: Callable[[], bool],
        gifts: Gifts,
        activity: ActivityLog,
    ) -> None:
        """`is_open` tells whether affinity and gifts are open now."""
        self._db = connect(path)
        self._clock = clock
        self._is_open = is_open
        self._gifts = gifts
        self._activity = activity
        with self._db:
            self._db.executescript(_SCHEMA + achievements.SCHEMA)

    def turn_recorded(self, user_id: str, character_id: str) -> Rewarded | None:
        """A turn of the user's with the character was recorded, now: what it was rewarded
        with; None if nothing."""
        return self._happened(user_id, character_id, Counts(turns=1, gifts=0))

    def gift_given(self, user_id: str, character_id: str) -> Rewarded | None:
        """The user gave the character a gift, now: what it was rewarded with; None if
        nothing."""
        return self._happened(user_id, character_id, Counts(turns=0, gifts=1))

    def daily_tasks(self, user_id: str) -> DailyTasks | None:
        """How far the user is with today's daily tasks; None while closed."""
        if not self._is_open():
            return None
        now = self._clock()
        counts = _counts(self._db, user_id, day_of(now))
        return DailyTasks([(t, min(t.of(counts), t.goal)) for t in DAILY_TASKS], next_day(now))

    def hers(self, user_id: str, character_id: str) -> Hers | None:
        """How far the user has come with the character's own achievements; None while
        closed."""
        if not self._is_open():
            return None
        return achievements.hers(self._db, user_id, character_id)

    def of_all(self, user_id: str) -> list[Progress] | None:
        """How far the user has come with the achievements of all the characters together;
        None while closed."""
        if not self._is_open():
            return None
        return achievements.of_all(self._db, user_id)

    def close(self) -> None:
        self._db.close()

    def _happened(self, user_id: str, character_id: str, happened: Counts) -> Rewarded | None:
        """Keep what `happened` with the character towards today's daily tasks and the
        achievements, and give the rewards for the tasks it did and the stages it unlocked:
        what it was rewarded with; None if nothing, or if closed."""
        done: dict[str, str | Unlocked | Completed] = {}
        """Each task's id, stage unlocked or character completed, by the key it is rewarded
        by."""

        def due(db: sqlite3.Connection, now: datetime) -> list[Reward]:
            today = day_of(now)
            counts = _counts(db, user_id, today) + happened
            db.execute(
                "INSERT INTO daily_task_progress (user_id, day, turns, gifts) VALUES (?, ?, ?, ?)"
                " ON CONFLICT (user_id) DO UPDATE"
                " SET day = excluded.day, turns = excluded.turns, gifts = excluded.gifts",
                (user_id, today.isoformat(), counts.turns, counts.gifts),
            )
            done.update({_key(today, t): t.id for t in DAILY_TASKS})
            rewards = [
                Reward(_key(today, t), t.draws) for t in DAILY_TASKS if t.of(counts) >= t.goal
            ]
            unlocked = achievements.keep(
                db, user_id, character_id, now, today,
                turns=happened.turns, gifts=happened.gifts,
            )
            done.update({reward.key: what for reward, what in unlocked})
            return rewards + [reward for reward, _ in unlocked]

        try:
            if not self._is_open():
                return None
            given, at = self._gifts.reward(user_id, due)
        except GiftsClosed:  # closed since: as if it had been all along
            return None
        except Exception:
            log.exception("keeping what happened failed; the daily tasks miss it")
            return None
        if not given:
            return None
        what = [done[r.key] for r in given]
        tasks = [w for w in what if isinstance(w, str)]
        for task in tasks:
            try:
                self._activity.daily_task_done(user_id, task, at)
            except Exception:
                log.exception("recording daily task %s done failed", task)
        return Rewarded(
            sum(r.draws for r in given), sum(r.reset_cards for r in given), tasks, at,
            [w for w in what if isinstance(w, Unlocked)],
            [w for w in what if isinstance(w, Completed)],
        )


def _counts(db: sqlite3.Connection, user_id: str, today: date) -> Counts:
    """The user's turns and gifts kept for `today`; none if those kept were another day's."""
    row = db.execute(
        "SELECT day, turns, gifts FROM daily_task_progress WHERE user_id = ?", (user_id,)
    ).fetchone()
    if row is None or row[0] != today.isoformat():
        return Counts(0, 0)
    return Counts(row[1], row[2])


def _key(day: date, task: DailyTask) -> str:
    """The key the task's reward is given by on `day`."""
    return f"daily_task:{day.isoformat()}:{task.id}"
