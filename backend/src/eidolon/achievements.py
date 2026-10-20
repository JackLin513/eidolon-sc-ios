"""Achievements (GLOSSARY.md「成就」): how far each user has come with the characters, kept
as it happens (`happenings`), and the stages it has unlocked.

Four are each character's own (`PER_CHARACTER`): turns with her, the time talked with her in
calls, gifts given her, and the highest tier her affinity has reached. Four are of all the
characters together (`ALL_CHARACTERS`): how many characters the user has had a turn with and
how many have reached intimate, worked out from her own; how many days they came, a turn or a
gift given that day in Beijing (`affinity.day_of`), not one after another; and how many times
they drew.

Each stage is unlocked once, the first time what it counts reaches its goal by the goals as
they are then, and stays unlocked whatever the goals become; stages are told apart by their
number, so goals may be changed but not reordered. Stage n gives n draw chances
(`Stage.draws`). Every stage of a character's own achievements unlocked, she is complete,
giving `COMPLETE_RESET_CARDS` once ever for her, however many stages there come to be.

What is kept and unlocked is kept on the connection and in the transaction it is rewarded in
(`Gifts.reward`), so that two at once unlock and reward a stage once. Each user's is theirs,
deleted with them (`database.USER_DATA`), and goes in no data package."""

import sqlite3
from collections.abc import Iterable
from dataclasses import dataclass
from datetime import date, datetime

from eidolon.affinity import Tier
from eidolon.gifts import Reward

SCHEMA = """
-- One row per user, achievement and character (empty for those of all the characters
-- together) with anything kept towards it: how much (a tier's rank among
-- `achievements.TIERS_REACHED` for the tier reached), and for the days come the last of them
-- (`affinity.day_of`).
CREATE TABLE IF NOT EXISTS achievement_progress (
    user_id TEXT NOT NULL REFERENCES users(id),
    achievement TEXT NOT NULL,
    character_id TEXT NOT NULL,
    count INTEGER NOT NULL,
    last_day TEXT,
    PRIMARY KEY (user_id, achievement, character_id)
);
-- One row per stage each user unlocked, by its number from 1, and when.
CREATE TABLE IF NOT EXISTS achievement_stages (
    user_id TEXT NOT NULL REFERENCES users(id),
    achievement TEXT NOT NULL,
    character_id TEXT NOT NULL,
    stage INTEGER NOT NULL,
    unlocked_at TEXT NOT NULL,
    PRIMARY KEY (user_id, achievement, character_id, stage)
);
"""


@dataclass(frozen=True)
class Stage:
    """A stage of an achievement: unlocked as what it counts reaches `goal`, giving `draws`
    draw chances."""

    goal: int
    draws: int


def _stages(*goals: int) -> tuple[Stage, ...]:
    """Stages reaching `goals` in order, stage n giving n draw chances."""
    return tuple(Stage(goal, n) for n, goal in enumerate(goals, 1))


@dataclass(frozen=True)
class Achievement:
    """An achievement, its stages in order."""

    id: str
    stages: tuple[Stage, ...]


TIERS_REACHED: tuple[Tier, ...] = ("close", "intimate")
"""The tiers the tier reached counts, by rank from 1: reaching one reaches those below it."""

PER_CHARACTER = (
    Achievement("turns", _stages(10, 100, 300, 1000, 3000)),
    Achievement("call_time", _stages(10 * 60, 60 * 60, 5 * 60 * 60, 20 * 60 * 60)),
    Achievement("gifts", _stages(1, 10, 30, 100)),
    Achievement("tier", _stages(1, 2)),
)
"""Each character's own, in the order her panel shows them: turns, seconds talked in calls
since connected, gifts given, the rank of the tier reached."""

ALL_CHARACTERS = (
    Achievement("characters", _stages(3, 10, 28)),
    Achievement("intimate_characters", _stages(1, 3, 10)),
    Achievement("days", _stages(7, 30, 100, 365)),
    Achievement("draws", _stages(10, 50, 200, 500)),
)
"""Those of all the characters together, in the order the gifts page shows them."""

COMPLETE_RESET_CARDS = 1
"""The reset cards a character complete gives, once ever for her."""

_ALL = ""
"""The character of those of all the characters together."""


@dataclass(frozen=True)
class Unlocked:
    """A stage unlocked: of which achievement, for which character (None for those of all
    the characters together), by number, and the draw chances it gave."""

    achievement: str
    character_id: str | None
    stage: int
    draws: int

    def shown(self) -> dict:
        """As the browser is told it."""
        return {
            "achievement": self.achievement,
            "character_id": self.character_id,
            "stage": self.stage,
            "draws": self.draws,
        }


@dataclass(frozen=True)
class Completed:
    """A character complete, and the reset cards it gave."""

    character_id: str
    reset_cards: int

    def shown(self) -> dict:
        """As the browser is told it."""
        return {"character_id": self.character_id, "reset_cards": self.reset_cards}


@dataclass(frozen=True)
class Progress:
    """How far the user has come with an achievement, and when each stage unlocked, by
    number."""

    achievement: Achievement
    progress: int
    unlocked: dict[int, datetime]

    def shown(self) -> dict:
        """As the browser is told it: the tier reached by its name, never her affinity."""
        tier = self.achievement.id == "tier"
        return {
            "id": self.achievement.id,
            "progress": _tier(self.progress) if tier else self.progress,
            "stages": [
                {
                    "goal": _tier(s.goal) if tier else s.goal,
                    "draws": s.draws,
                    "unlocked_at": (at := self.unlocked.get(n)) and at.isoformat(),
                }
                for n, s in enumerate(self.achievement.stages, 1)
            ],
        }


@dataclass(frozen=True)
class Hers:
    """A character's own achievements with the user, and when she was complete (None if
    not)."""

    achievements: list[Progress]
    completed_at: datetime | None

    def shown(self) -> dict:
        """As the browser is told it."""
        return {
            "achievements": [p.shown() for p in self.achievements],
            "complete": {
                "completed_at": self.completed_at and self.completed_at.isoformat(),
                "reset_cards": COMPLETE_RESET_CARDS,
            },
        }


def keep(
    db: sqlite3.Connection, user_id: str, character_id: str, now: datetime, today: date,
    *, turns: int = 0, gifts: int = 0,
) -> list[tuple[Reward, Unlocked | Completed]]:
    """Keep that the user had `turns` turns with the character and gave her `gifts` gifts
    `now`, on `today`, and unlock the stages reached by now: the rewards due for every stage
    unlocked and her being complete, newly or not, each with what it is for."""
    for achievement, count in (("turns", turns), ("gifts", gifts)):
        if count:
            db.execute(
                "INSERT INTO achievement_progress (user_id, achievement, character_id, count)"
                " VALUES (?, ?, ?, ?) ON CONFLICT (user_id, achievement, character_id)"
                " DO UPDATE SET count = count + excluded.count",
                (user_id, achievement, character_id, count),
            )
    db.execute(
        "INSERT INTO achievement_progress"
        " (user_id, achievement, character_id, count, last_day) VALUES (?, 'days', ?, 1, ?)"
        " ON CONFLICT (user_id, achievement, character_id) DO UPDATE"
        " SET count = count + 1, last_day = excluded.last_day"
        " WHERE last_day < excluded.last_day",
        (user_id, _ALL, today.isoformat()),
    )
    return _unlock(db, user_id, character_id, now)


def hers(db: sqlite3.Connection, user_id: str, character_id: str) -> Hers:
    """How far the user has come with the character's own achievements."""
    counts = _counts(db, user_id)
    unlocked = _unlocked(db, user_id, character_id)
    achievements = [
        Progress(a, counts.get((a.id, character_id), 0), unlocked.get(a.id, {}))
        for a in PER_CHARACTER
    ]
    completed_at = None
    if _complete(unlocked):
        completed_at = max((at for p in achievements for at in p.unlocked.values()), default=None)
    return Hers(achievements, completed_at)


def of_all(db: sqlite3.Connection, user_id: str) -> list[Progress]:
    """How far the user has come with the achievements of all the characters together."""
    counts = _counts(db, user_id)
    unlocked = _unlocked(db, user_id, _ALL)
    return [
        Progress(a, _of_all(counts, a.id), unlocked.get(a.id, {})) for a in ALL_CHARACTERS
    ]


def _unlock(
    db: sqlite3.Connection, user_id: str, character_id: str, now: datetime
) -> list[tuple[Reward, Unlocked | Completed]]:
    """Unlock the stages reached of the character's own achievements and of those of all
    together; the rewards due for each stage reached, and for her being complete if she is."""
    counts = _counts(db, user_id)
    reached = [
        (a, character_id, counts.get((a.id, character_id), 0)) for a in PER_CHARACTER
    ] + [(a, _ALL, _of_all(counts, a.id)) for a in ALL_CHARACTERS]
    due: list[tuple[Reward, Unlocked | Completed]] = []
    for achievement, character, progress in reached:
        for n, stage in enumerate(achievement.stages, 1):
            if progress < stage.goal:
                continue
            db.execute(
                "INSERT INTO achievement_stages"
                " (user_id, achievement, character_id, stage, unlocked_at) VALUES (?, ?, ?, ?, ?)"
                " ON CONFLICT DO NOTHING",
                (user_id, achievement.id, character, n, now.isoformat()),
            )
            due.append((
                Reward(f"achievement:{achievement.id}:{character}:{n}", stage.draws),
                Unlocked(achievement.id, character or None, n, stage.draws),
            ))
    if _complete(_unlocked(db, user_id, character_id)):
        due.append((
            Reward(f"achievement_complete:{character_id}", 0, COMPLETE_RESET_CARDS),
            Completed(character_id, COMPLETE_RESET_CARDS),
        ))
    return due


def _counts(db: sqlite3.Connection, user_id: str) -> dict[tuple[str, str], int]:
    """Everything kept towards the user's achievements, by achievement and character."""
    rows: Iterable[tuple[str, str, int]] = db.execute(
        "SELECT achievement, character_id, count FROM achievement_progress WHERE user_id = ?",
        (user_id,),
    )
    return {(a, c): count for a, c, count in rows}


def _of_all(counts: dict[tuple[str, str], int], achievement: str) -> int:
    """How far the user has come with one of the achievements of all the characters
    together, worked out from each character's own where it is."""
    if achievement == "characters":
        return sum(1 for (a, c), n in counts.items() if a == "turns" and c != _ALL and n >= 1)
    if achievement == "intimate_characters":
        intimate = TIERS_REACHED.index("intimate") + 1
        return sum(1 for (a, c), n in counts.items() if a == "tier" and c != _ALL and n >= intimate)
    return counts.get((achievement, _ALL), 0)


def _unlocked(
    db: sqlite3.Connection, user_id: str, character_id: str
) -> dict[str, dict[int, datetime]]:
    """When each stage the user unlocked for the character (`_ALL` for those of all
    together) unlocked, by achievement and number."""
    unlocked: dict[str, dict[int, datetime]] = {}
    for achievement, stage, at in db.execute(
        "SELECT achievement, stage, unlocked_at FROM achievement_stages"
        " WHERE user_id = ? AND character_id = ?",
        (user_id, character_id),
    ):
        unlocked.setdefault(achievement, {})[stage] = datetime.fromisoformat(at)
    return unlocked


def _complete(unlocked: dict[str, dict[int, datetime]]) -> bool:
    """Whether every stage of a character's own achievements there is now is unlocked."""
    return all(
        n in unlocked.get(a.id, {}) for a in PER_CHARACTER for n in range(1, len(a.stages) + 1)
    )


def _tier(rank: int) -> Tier | None:
    """The tier reached of `rank`; None for none."""
    return TIERS_REACHED[rank - 1] if rank else None
