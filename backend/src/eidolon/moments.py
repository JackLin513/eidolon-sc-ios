"""Moments (GLOSSARY.md「朋友圈」「动态」): what the characters post to each user's own
moments, of their days, for that user alone to read.

Only where the deployer turns them on (`LiveConfig.moments`), on the deployer's chat model.
Every `TICK` the backend runs what is due (`run_due`): first each user active and not yet
planned for today in Tokyo is planned for, then each moment whose time has come is posted, one
after another in the order of their times.

A user is active who has been in touch with any character within `ACTIVE`: a turn recorded,
or a call that connected ending (`store.read_in_touch`); gifts are not being in touch. Not a
banned user, nor one an admin lets take no turns on the deployer's keys. Planned for at the
first tick of the day in Tokyo they are active at, from the rest of the day
(`moment_draws.plan_day`): of the characters they have had a turn with, in trust or above and
not in a cooldown (trust where affinity is off), each drawn for once; as many as the deployer
sets a day at most. Once planned, a user is not again that day: a character first talked to,
or come up to trust, that day waits for the next. The plan is kept, and read again after a
restart.

While the deployer has moments off, nothing is planned nor posted; turned on again, what was
planned is forgotten, and each user planned for anew from what is left of the day.

As a moment's time comes, it is looked at again: the deployer still has moments on; the user
is still active, not banned, nor let take no turns; she is in trust or above and not in a
cooldown; the user has had fewer moments of its day than the deployer sets. If not, it is
passed over, for good. One whose time came before the backend started is passed over too,
not made up for. Each is taken off the plan once posted or passed over.

She posts on the deployer's chat model as text turns use it, whoever's LLM the user brings,
held only while she does: nothing counts towards the user's limits. Her prompt is put
together from what is read beforehand (`moment_prompt.PostMaterial`): what she knows of now on
the `moments` occasion; `SEEDS` entries of her facts; the memories she was told herself, found
with the last turn of her current conversation (`Memories.for_reaching_out`); her latest
`RECENT` moments. Each has an activity record of its own (`moment`), on the deployer's keys,
its service calls under it; one the model fails, or writes nothing to post in, is recorded
failed, and not tried again. What she posts is posted as it is written: that is when it shows.

The timeline (`timeline`) is the user's moments of the last `KEPT`, the latest first."""

import asyncio
import logging
import sqlite3
from collections.abc import AsyncIterator, Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta

from eidolon.activity import ActivityLog
from eidolon.affinity import Affinities, Status, Tier, tier_prompt
from eidolon.characters import Character
from eidolon.clock import Clock
from eidolon.data_access import Database
from eidolon.her_now import HerNow
from eidolon.live_config import LiveConfig
from eidolon.llm import Streamed
from eidolon.memory import Memories, last_turn_query
from eidolon.moment_draws import CHANCES, Eligible, Planned, draw_seeds, plan_day
from eidolon.moment_prompt import PostMaterial, parse_post, post_prompt
from eidolon.producer import ProducerProfile, effective_timezone, is_birthday, local_date
from eidolon.randomness import Random
from eidolon.store import (
    Conversation,
    InTouch,
    Message,
    read_current_conversation,
    read_in_touch,
    read_profile,
    read_record,
)
from eidolon.today import tokyo_date
from eidolon.usage import read_user_limits
from eidolon.world import World

log = logging.getLogger(__name__)

TICK = timedelta(minutes=1)
"""How often it is looked whose time has come."""

ACTIVE = timedelta(days=7)
"""How recently a user must have been in touch with a character to have moments."""

RECENT = 5
"""How many of her latest moments she is told of, not to post the same again."""

KEPT = timedelta(days=30)
"""How long moments show on the timeline."""

_SCHEMA = """
-- What she posted to a user's moments (GLOSSARY.md「动态」), as shown, delivery cues left out.
-- `image` is how she wrote its picture, as JSON; `place_*` is a copy of the place she was
-- at, so that it shows as it was should the place pool change; `weather` is Tokyo's as she
-- posted it, one of seven, and `temperature` in whole degrees: each NULL without. `day` is
-- the day in Tokyo it was planned for, `posted_at` when it shows.
CREATE TABLE IF NOT EXISTS moments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL REFERENCES users(id),
    character_id TEXT NOT NULL,
    ja TEXT NOT NULL,
    zh TEXT NOT NULL,
    image TEXT,
    place_id TEXT,
    place_name TEXT,
    place_lat REAL,
    place_lon REAL,
    weather TEXT,
    temperature INTEGER,
    day TEXT NOT NULL,
    posted_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS moments_by_user ON moments(user_id, posted_at);

-- The moments planned, each till it is posted or passed over: whose, the day in Tokyo it is
-- of, when it is due, whether of her jobs done that day (`work`) or her everyday (`daily`),
-- and whether on her birthday.
CREATE TABLE IF NOT EXISTS moment_plans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL REFERENCES users(id),
    character_id TEXT NOT NULL,
    day TEXT NOT NULL,
    due_at TEXT NOT NULL,
    kind TEXT NOT NULL,
    birthday INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS moment_plans_by_time ON moment_plans(due_at);

-- Each user's moments as a whole: the latest day in Tokyo planned for, and when they last
-- opened their moments.
CREATE TABLE IF NOT EXISTS moment_users (
    user_id TEXT PRIMARY KEY REFERENCES users(id),
    planned_day TEXT,
    opened_at TEXT
);
"""


class MomentsOff(Exception):
    """The deployer has moments off."""


@dataclass(frozen=True)
class Moment:
    """A moment as the timeline shows it: whose, what she posted, and when it showed."""

    id: int
    character_id: str
    ja: str
    zh: str
    posted_at: str

    def shown(self) -> dict:
        """As the browser is told it; no picture, place or weather yet."""
        return {
            "id": self.id, "character_id": self.character_id, "ja": self.ja, "zh": self.zh,
            "image": None, "place": None, "weather": None, "posted_at": self.posted_at,
        }


@dataclass(frozen=True)
class _Plan:
    """A moment planned, as `moment_plans` keeps it."""

    id: int
    user_id: str
    character_id: str
    day: date
    due_at: datetime
    birthday: bool


@dataclass(frozen=True)
class _Standing:
    """What is read of a user, at one moment, to tell whether they have moments: whether
    they are active and let take turns; and her tier with each character they have had a turn
    with, None for one she would post nothing in (in a cooldown, or below trust)."""

    active: bool
    tiers: dict[str, Tier | None]


@dataclass(frozen=True)
class _Before:
    """What she posts a moment with, read beforehand in one read: the producer, her current
    conversation and its messages, and her latest moments' Japanese, the latest first."""

    profile: ProducerProfile
    conversation: Conversation | None
    messages: list[Message]
    recent: list[str]


class Moments:
    """Her moments, in `db`, on the deployer's models of `config`, each recorded in
    `activity`; `random` draws who posts and when. A time that came before `clock` says it is
    as they begin is missed."""

    def __init__(
        self,
        db: Database,
        characters: Mapping[str, Character],
        config: LiveConfig,
        affinities: Affinities,
        activity: ActivityLog,
        memory: Memories,
        her_now: HerNow,
        clock: Clock,
        random: Random,
        world: World | None = None,
    ) -> None:
        self._db = db
        self._characters = characters
        self._config = config
        self._affinities = affinities
        self._activity = activity
        self._memory = memory
        self._her_now = her_now
        self._clock = clock
        self._random = random
        self._world = world
        self._started = clock()
        self._was_off = False
        db.prepare(_open)

    async def keep_posting(self) -> None:
        """`run_due` at every `TICK`, until cancelled."""
        while True:
            await asyncio.sleep(TICK.total_seconds())
            try:
                await self.run_due()
            except Exception:
                log.exception("posting moments failed")

    async def run_due(self) -> None:
        """Plan for each user active and not yet planned for today in Tokyo, then post each
        moment whose time has come, one after another in the order of their times; one going
        wrong keeps none of the others from it. Nothing while the deployer has moments off,
        or has no chat model; turned on again, what was planned is forgotten, and each user
        planned for anew."""
        if not self._on:
            self._was_off = True
            return
        if self._was_off:  # turned on again: planned anew, from what is left of the day
            await self._db.write(_forget_plans)
            self._was_off = False
        now = self._clock()
        await self._plan(now)
        for plan in await self._db.read(_due, now.astimezone(UTC).isoformat()):
            try:
                await self._post(plan)
            except Exception:
                log.exception("posting a moment to user %s failed", plan.user_id)
                await self._db.write(_drop_plan, plan.id)  # not tried again

    def switch_of(self, user_id: str) -> bool | None:
        """Whether the user has moments: True, or None where the deployer has them off."""
        return True if self._config.moments.enabled else None

    async def timeline(self, user_id: str) -> list[Moment]:
        """The user's moments that have shown within `KEPT`, the latest first, of the
        characters there are; raise `MomentsOff` where the deployer has them off."""
        if not self._config.moments.enabled:
            raise MomentsOff
        now = self._clock()
        moments = await self._db.read(
            _timeline, user_id, (now - KEPT).astimezone(UTC).isoformat(),
            now.astimezone(UTC).isoformat(),
        )
        return [m for m in moments if m.character_id in self._characters]

    @property
    def _on(self) -> bool:
        return self._config.moments.enabled and self._config.has_service("chat_llm")

    async def _plan(self, now: datetime) -> None:
        """Plan today's moments for each user active and not yet planned for today; one
        going wrong keeps none of the others from it."""
        day = tokyo_date(now)
        affinity_on = self._affinities.on
        unplanned = await self._db.read(self._unplanned, day, now, affinity_on)
        for user_id, tiers in unplanned.items():
            eligible = [
                Eligible(id, tier, is_birthday(self._characters[id].birthday, day))
                for id, tier in tiers.items() if tier is not None
            ]
            try:
                planned = plan_day(
                    eligible, day, now, self._config.moments.per_day, self._random
                )
                await self._db.write(_keep_plan, user_id, day.isoformat(), planned)
            except Exception:
                log.exception("planning moments for user %s failed", user_id)

    def _unplanned(
        self, db: sqlite3.Connection, day: date, now: datetime, affinity_on: bool
    ) -> dict[str, dict[str, Tier | None]]:
        """Each user active and not planned for `day`, with her tier with each character,
        read through `db`."""
        in_touch: dict[str, list[InTouch]] = {}
        for each in read_in_touch(db):
            in_touch.setdefault(each.user_id, []).append(each)
        planned = {
            user_id
            for (user_id,) in db.execute(
                "SELECT user_id FROM moment_users WHERE planned_day = ?", (day.isoformat(),)
            )
        }
        unplanned: dict[str, dict[str, Tier | None]] = {}
        for user_id in in_touch.keys() - planned:
            standing = self._standing(db, user_id, now, affinity_on, in_touch[user_id])
            if standing.active:
                unplanned[user_id] = standing.tiers
        return unplanned

    def _standing(
        self,
        db: sqlite3.Connection,
        user_id: str,
        now: datetime,
        affinity_on: bool,
        in_touch: Sequence[InTouch] | None = None,
    ) -> _Standing:
        """What is read of the user at `now`, through `db`: from `in_touch` if read
        already; her affinity only while it is `affinity_on`."""
        if in_touch is None:
            in_touch = read_in_touch(db, user_id)
        limits = read_user_limits(db, user_id)
        contacts = [t.last_contact for t in in_touch if t.last_contact is not None]
        active = (
            bool(contacts) and now - max(contacts) <= ACTIVE
            and (limits is None or limits.turns_per_hour != 0)
        )
        tiers: dict[str, Tier | None] = {
            t.character_id: _tier(
                self._affinities.read_status(db, user_id, t.character_id)
                if affinity_on else None
            )
            for t in in_touch if t.has_turns and t.character_id in self._characters
        }
        return _Standing(active, tiers)

    async def _post(self, plan: _Plan) -> None:
        """Post the moment planned, unless it is to be passed over; either way, take it off
        the plan."""
        if plan.due_at < self._started or not await self._still(plan):
            await self._db.write(_drop_plan, plan.id)
            return
        now = self._clock()
        character = self._characters[plan.character_id]
        material = await self._material(plan, character, now)
        recording = self._activity.begin(
            "moment", plan.user_id, plan.character_id, own_llm=False, exempt=False
        )
        lease = self._config.lease()
        try:
            with recording.current():
                written = await _written(lease.keys.chat_llm.stream(post_prompt(material)))
        except Exception as e:
            # Not logged with what was raised: a service's error may repeat what it was asked.
            log.warning("posting a moment to user %s failed: %s", plan.user_id,
                        type(e).__name__)
            await self._db.write(_drop_plan, plan.id)
            await recording.finish("failed")
            return
        finally:
            lease.release()
        post = parse_post(written)
        if post is None:
            log.warning("posting a moment to user %s failed: nothing to post", plan.user_id)
            await self._db.write(_drop_plan, plan.id)
            await recording.finish("failed")
            return
        await self._db.write(
            _add_moment, plan, post.ja, post.zh, self._clock().astimezone(UTC).isoformat()
        )
        await recording.finish("success")

    async def _still(self, plan: _Plan) -> bool:
        """Whether the moment planned is to be posted, as it is now."""
        if not self._on or plan.character_id not in self._characters:
            return False
        standing, posted = await self._db.read(
            self._standing_then, plan, self._clock(), self._affinities.on
        )
        return (
            standing.active and standing.tiers.get(plan.character_id) is not None
            and posted < self._config.moments.per_day
        )

    def _standing_then(
        self, db: sqlite3.Connection, plan: _Plan, now: datetime, affinity_on: bool
    ) -> tuple[_Standing, int]:
        """The user's standing at `now`, and how many moments they have had of the plan's
        day, read through `db`."""
        [posted] = db.execute(
            "SELECT COUNT(*) FROM moments WHERE user_id = ? AND day = ?",
            (plan.user_id, plan.day.isoformat()),
        ).fetchone()
        return self._standing(db, plan.user_id, now, affinity_on), posted

    async def _material(
        self, plan: _Plan, character: Character, now: datetime
    ) -> PostMaterial:
        """What she posts the moment planned with, read now."""
        known = await self._her_now.read(plan.user_id, plan.character_id, None, "moments")
        before = await self._db.read(_before, plan.user_id, plan.character_id)
        status = await self._affinities.status(plan.user_id, plan.character_id)
        timezone = effective_timezone(before.profile, None)
        memories = (
            await self._memory.for_reaching_out(
                before.conversation, timezone, last_turn_query(before.messages), posting=True
            )
            if before.conversation is not None else None
        )
        return PostMaterial(
            character,
            self._world.prompt(character.name, local_date(now, timezone)) if self._world else None,
            before.profile,
            self._her_now.lines(
                known, "moments", now, timezone, before.profile, None,
                tier_prompt(status),
            ),
            plan.birthday,
            [_seed(f.text) for f in draw_seeds(character.facts, self._random)],
            memories,
            before.recent,
        )


async def _written(stream: AsyncIterator[Streamed]) -> str:
    """The whole of what the model wrote, its text alone."""
    chunks: list[str] = []
    try:
        async for item in stream:
            if isinstance(item, str):
                chunks.append(item)
    finally:
        if (close := getattr(stream, "aclose", None)) is not None:
            await close()
    return "".join(chunks)


def _seed(text: str) -> str:
    """An entry of her facts as a seed: its heading, then what is under it, on one line."""
    return text.replace("\n", "：", 1).replace("\n", " ")


def _tier(status: Status | None) -> Tier | None:
    """The tier she posts by, trust where affinity is off (`status` None); None if she is
    not to, in a cooldown or below trust."""
    if status is None:
        return "trust"
    if status.cooling or status.tier not in CHANCES:
        return None
    return status.tier


def _open(db: sqlite3.Connection) -> None:
    db.executescript(_SCHEMA)


def _keep_plan(
    db: sqlite3.Connection, user_id: str, day: str, planned: Sequence[Planned]
) -> None:
    """Keep the user's plan for `day`, and that they are planned for it."""
    db.executemany(
        "INSERT INTO moment_plans (user_id, character_id, day, due_at, kind, birthday)"
        " VALUES (?, ?, ?, ?, 'daily', ?)",
        [(user_id, p.character_id, day, p.due_at.astimezone(UTC).isoformat(), int(p.birthday))
         for p in planned],
    )
    db.execute(
        "INSERT INTO moment_users (user_id, planned_day) VALUES (?, ?)"
        " ON CONFLICT (user_id) DO UPDATE SET planned_day = excluded.planned_day",
        (user_id, day),
    )


def _forget_plans(db: sqlite3.Connection) -> None:
    """Forget every moment planned, and that anyone was planned for."""
    db.execute("DELETE FROM moment_plans")
    db.execute("UPDATE moment_users SET planned_day = NULL")


def _due(db: sqlite3.Connection, now: str) -> list[_Plan]:
    """The moments planned whose time has come by `now`, the earliest first."""
    return [
        _Plan(id, user_id, character_id, date.fromisoformat(day),
              datetime.fromisoformat(due_at), bool(birthday))
        for id, user_id, character_id, day, due_at, birthday in db.execute(
            "SELECT id, user_id, character_id, day, due_at, birthday FROM moment_plans"
            " WHERE due_at <= ? ORDER BY due_at, id",
            (now,),
        )
    ]


def _drop_plan(db: sqlite3.Connection, plan_id: int) -> None:
    db.execute("DELETE FROM moment_plans WHERE id = ?", (plan_id,))


def _add_moment(db: sqlite3.Connection, plan: _Plan, ja: str, zh: str, posted_at: str) -> None:
    """Post the moment planned, taking it off the plan."""
    db.execute(
        "INSERT INTO moments (user_id, character_id, ja, zh, day, posted_at)"
        " VALUES (?, ?, ?, ?, ?, ?)",
        (plan.user_id, plan.character_id, ja, zh, plan.day.isoformat(), posted_at),
    )
    _drop_plan(db, plan.id)


def _before(db: sqlite3.Connection, user_id: str, character_id: str) -> _Before:
    conversation = read_current_conversation(db, user_id, character_id)
    messages = (
        [e for e in read_record(db, conversation.id) if isinstance(e, Message)]
        if conversation is not None else []
    )
    recent = [
        ja for (ja,) in db.execute(
            "SELECT ja FROM moments WHERE user_id = ? AND character_id = ?"
            " ORDER BY posted_at DESC, id DESC LIMIT ?",
            (user_id, character_id, RECENT),
        )
    ]
    return _Before(read_profile(db, user_id), conversation, messages, recent)


def _timeline(db: sqlite3.Connection, user_id: str, since: str, now: str) -> list[Moment]:
    return [
        Moment(*row)
        for row in db.execute(
            "SELECT id, character_id, ja, zh, posted_at FROM moments"
            " WHERE user_id = ? AND posted_at > ? AND posted_at <= ?"
            " ORDER BY posted_at DESC, id DESC",
            (user_id, since, now),
        )
    ]
