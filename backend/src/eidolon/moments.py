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
sets a day at most. One with jobs in the user's schedule done that day in Tokyo, done already
or not yet, posts of them, after the last is done; the others, and one planned too long after
that, of their everyday (`kind`); all of their everyday while schedules are off. Once planned, a user is not again that day: a
character first talked to, or come up to trust, that day waits for the next. The plan is
kept, and read again after a restart.

While the deployer has moments off, nothing is planned nor posted; turned on again, what was
planned is forgotten, and each user planned for anew from what is left of the day.

As a moment's time comes, it is looked at again: the deployer still has moments on; the user
is still active, not banned, nor let take no turns; she is in trust or above and not in a
cooldown; the user has had fewer moments of its day than the deployer sets. If not, it is
passed over, for good. One whose time came before the backend started is passed over too,
not made up for. Each is taken off the plan once posted or passed over. One of her jobs whose
time comes as she is still at one, the producer having scheduled her more since, is put off
till after the last as it was planned, past midnight if so, still of the day planned for.

She posts on the deployer's chat model as text turns use it, whoever's LLM the user brings,
held only while she does: nothing counts towards the user's limits. Her prompt is put
together from what is read beforehand (`moment_prompt.PostMaterial`): what she knows of now on
the `moments` occasion; her jobs done that day, each its name and what it is, or else
`SEEDS` entries of her facts; the memories she was told herself, found with the last turn of
her current conversation (`Memories.for_reaching_out`); her latest `RECENT` moments; as many
as `moment_draws.CANDIDATES` places of the pool for her to say she was at one of
(`moment_draws.draw_places`), of her jobs only of the kinds they take her to, only those
under a roof in rain, snow or thunder; Tokyo's weather as she posts (`weather`), kept with the
moment, none if it cannot be had. Each has an activity record of its own (`moment`), on the
deployer's keys, its service calls under it, and what of it was made do without
(`moment_prompt.Post.degraded`); one the model fails, or writes nothing to post in, is
recorded failed, and not tried again. What she posts is posted as it is written: that is when
it shows.

She posts it with her circle (`moment_draws.draw_circle`), of the other idols, the office's
staff in no one's: her unit mates, as the world setting has them; those a section of her
facts on the people she knows is on, by their names in its heading (but for those on the
producer and on the other idols, `NOT_ONE`); and the others. Of those she writes like it and
comment on it, each shows at a time of its own (`moment_draws.draw_shown`), whatever comes of
her affinity or her cooldowns after.

The timeline (`timeline`) is the user's moments of the last `KEPT`, the latest first, each
place with a link to it on the map the deployer chooses (`map_link`), each with the likes
and comments of her circle that have shown, in the order they did."""

import asyncio
import logging
import sqlite3
from collections.abc import AsyncIterator, Mapping, Sequence
from dataclasses import dataclass, replace
from datetime import UTC, date, datetime, timedelta
from typing import TypeVar
from urllib.parse import quote, urlencode

from eidolon.activity import ActivityLog
from eidolon.affinity import Affinities, Status, Tier, tier_prompt
from eidolon.characters import Character
from eidolon.clock import Clock
from eidolon.config import MapSite
from eidolon.data_access import Database
from eidolon.her_now import HerNow
from eidolon.live_config import LiveConfig
from eidolon.llm import Streamed
from eidolon.memory import Memories, last_turn_query
from eidolon.moment_draws import (
    CHANCES,
    KEPT_APART,
    RELATIONS,
    Eligible,
    Kind,
    Planned,
    draw_circle,
    draw_places,
    draw_seeds,
    draw_shown,
    plan_day,
    work_time,
)
from eidolon.moment_prompt import Comment, Member, PostMaterial, parse_post, post_prompt
from eidolon.place_pool import Place
from eidolon.producer import ProducerProfile, effective_timezone, is_birthday, local_date
from eidolon.randomness import Random
from eidolon.schedule import DayJob, Schedules
from eidolon.store import (
    Conversation,
    InTouch,
    Message,
    read_current_conversation,
    read_in_touch,
    read_profile,
    read_record,
)
from eidolon.today import tokyo_date, venues_on_this_day
from eidolon.usage import read_user_limits
from eidolon.weather import ALL_KINDS, Weather, Weathers
from eidolon.world import World

log = logging.getLogger(__name__)

_T = TypeVar("_T")

_LIKE, _COMMENT = "like", "comment"
"""The kinds of what `moment_circle` keeps: a like, a comment."""

TICK = timedelta(minutes=1)
"""How often it is looked whose time has come."""

ACTIVE = timedelta(days=7)
"""How recently a user must have been in touch with a character to have moments."""

RECENT = 5
"""How many of her latest moments she is told of, not to post the same again."""

KEPT = timedelta(days=30)
"""How long moments show on the timeline."""

NOT_ONE = ("制作人", "プロデューサー", "其他偶像")
"""What is in the heading of a section of her facts on the people she knows that is on no
one of her circle."""

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

-- The likes and comments of her circle on a moment (GLOSSARY.md「动态」): whose, a like
-- (`like`) or a comment (`comment`, `kind`), a comment's Japanese and subtitle (NULL for a like), where it is in
-- what she wrote (`position`, from 0, likes and comments each on their own), and when it shows.
CREATE TABLE IF NOT EXISTS moment_circle (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    moment_id INTEGER NOT NULL REFERENCES moments(id),
    character_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    ja TEXT,
    zh TEXT,
    position INTEGER NOT NULL,
    shown_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS moment_circle_by_moment ON moment_circle(moment_id, shown_at);
"""


class MomentsOff(Exception):
    """The deployer has moments off."""


@dataclass(frozen=True)
class ShownPlace:
    """A moment's copy of the place she was at: its name and where it is, in WGS-84."""

    name: str
    lat: float
    lon: float


def map_link(site: MapSite, place: ShownPlace) -> str:
    """Where `place` is on the map of `site`, marked, its coordinates as they are (WGS-84):
    none of them needs a key."""
    lat, lon = place.lat, place.lon
    if site == "google":  # Maps URLs
        return "https://www.google.com/maps/search/?" + urlencode(
            {"api": 1, "query": f"{lat},{lon}"}
        )
    if site == "amap":
        return (
            f"https://uri.amap.com/marker?position={lon},{lat}"
            f"&name={quote(place.name)}&coordinate=wgs84"
        )
    return f"https://www.openstreetmap.org/?mlat={lat}&mlon={lon}#map=17/{lat}/{lon}"


@dataclass(frozen=True)
class Moment:
    """A moment as the timeline shows it: whose, what she posted, when it showed, where she
    was, as it was then (None for nowhere), Tokyo's weather then (None for none known), and
    who of her circle has liked it and commented on it so far, in the order they showed."""

    id: int
    character_id: str
    ja: str
    zh: str
    posted_at: str
    place: ShownPlace | None = None
    weather: Weather | None = None
    likes: tuple[str, ...] = ()
    comments: tuple[Comment, ...] = ()

    def shown(self, map_site: MapSite) -> dict:
        """As the browser is told it, its place linked to on `map_site`; no picture yet."""
        place = (
            {"name": self.place.name, "map": map_link(map_site, self.place)}
            if self.place is not None else None
        )
        return {
            "id": self.id, "character_id": self.character_id, "ja": self.ja, "zh": self.zh,
            "image": None, "place": place,
            "weather": self.weather.shown() if self.weather is not None else None,
            "posted_at": self.posted_at,
            "likes": list(self.likes),
            "comments": [
                {"character_id": c.character_id, "ja": c.ja, "zh": c.zh} for c in self.comments
            ],
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
    kind: Kind = "daily"


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
    conversation and its messages, her latest moments' Japanese, the latest first, and the
    places the user's moments were at within `KEPT_APART`, by identifier."""

    profile: ProducerProfile
    conversation: Conversation | None
    messages: list[Message]
    recent: list[str]
    used: set[str]


class Moments:
    """Her moments, in `db`, on the deployer's models of `config`, each recorded in
    `activity`; `random` draws who posts and when. A time that came before `clock` says it is
    as they begin is missed. She posts in Tokyo's weather as `weathers` has it, of her jobs in
    the user's schedule, as `schedules` has them, and may be at one of `places`."""

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
        weathers: Weathers,
        schedules: Schedules,
        world: World | None = None,
        places: Sequence[Place] = (),
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
        self._places = places
        self._weathers = weathers
        self._schedules = schedules
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
        characters there are, as are the likes and comments on them; raise `MomentsOff`
        where the deployer has them off."""
        if not self._config.moments.enabled:
            raise MomentsOff
        now = self._clock()
        moments = await self._db.read(
            _timeline, user_id, (now - KEPT).astimezone(UTC).isoformat(),
            now.astimezone(UTC).isoformat(),
        )
        return [
            replace(
                m,
                likes=tuple(id for id in m.likes if id in self._characters),
                comments=tuple(c for c in m.comments if c.character_id in self._characters),
            )
            for m in moments if m.character_id in self._characters
        ]

    @property
    def map_site(self) -> MapSite:
        """The map the places on the timeline link to now."""
        return self._config.moments.map

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
            try:
                jobs = await self._schedules.done_on(user_id, day)
                eligible = [
                    Eligible(
                        id, tier, is_birthday(self._characters[id].birthday, day),
                        jobs[id][-1].done_at if id in jobs else None,
                    )
                    for id, tier in tiers.items() if tier is not None
                ]
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
        """Post the moment planned, unless it is to be passed over, or is of her jobs while
        she is still at one, then put off till after the last, and looked at again then;
        posted or passed over, take it off the plan."""
        if plan.due_at < self._started or not await self._still(plan):
            await self._db.write(_drop_plan, plan.id)
            return
        now = self._clock()
        jobs: list[DayJob] = []
        if plan.kind == "work":
            jobs = (await self._schedules.done_on(plan.user_id, plan.day)).get(
                plan.character_id, []
            )
            if jobs and jobs[-1].done_at > now:  # scheduled more since it was planned
                due = work_time(jobs[-1].done_at, now, self._random)
                assert due is not None  # the last is done after now
                await self._db.write(_put_off, plan.id, due.astimezone(UTC).isoformat())
                return
        character = self._characters[plan.character_id]
        weather = await self._weathers.at(now)
        material = await self._material(plan, character, now, weather, jobs)
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
        post = parse_post(written, material)
        if post is None:
            log.warning("posting a moment to user %s failed: nothing to post", plan.user_id)
            await self._db.write(_drop_plan, plan.id)
            await recording.finish("failed")
            return
        recording.degraded = dict(post.degraded) or None
        posted_at = self._clock()
        likes_at, comments_at = draw_shown(
            posted_at, len(post.likes), len(post.comments), self._random
        )
        await self._db.write(
            _add_moment, plan, post.ja, post.zh, post.place, weather,
            posted_at.astimezone(UTC).isoformat(),
            _when(post.likes, likes_at), _when(post.comments, comments_at),
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
        self,
        plan: _Plan,
        character: Character,
        now: datetime,
        weather: Weather | None,
        jobs: Sequence[DayJob],
    ) -> PostMaterial:
        """What she posts the moment planned with, read now, in `weather` (None for none
        known): of `jobs`, her jobs done that day, if any, else of her everyday. Of her jobs,
        her places are of the kinds they take her to, none if none takes her anywhere."""
        known = await self._her_now.read(plan.user_id, plan.character_id, None, "moments")
        before = await self._db.read(
            _before, plan.user_id, plan.character_id,
            (now - KEPT_APART).astimezone(UTC).isoformat(),
        )
        status = await self._affinities.status(plan.user_id, plan.character_id)
        timezone = effective_timezone(before.profile, None)
        memories = (
            await self._memory.for_reaching_out(
                before.conversation, timezone, last_turn_query(before.messages), posting=True
            )
            if before.conversation is not None else None
        )
        kinds = {kind for each in jobs for kind in each.places or ()}
        places = (
            draw_places(
                self._places, character.id, None if jobs else character.place_likes,
                venues_on_this_day(now, character, self._world), now, before.used,
                self._random, roofed=weather is not None and weather.wet,
                within=kinds if jobs else None,
            )
            if kinds or not jobs else []
        )
        seeds = [] if jobs else [_seed(f.text) for f in draw_seeds(character.facts, self._random)]
        return PostMaterial(
            character,
            self._world.prompt(character.name, local_date(now, timezone)) if self._world else None,
            before.profile,
            self._her_now.lines(
                known, "moments", now, timezone, before.profile, None,
                tier_prompt(status), weather,
            ),
            plan.birthday,
            seeds,
            memories,
            before.recent,
            places,
            [f"{each.job.name}：{each.job.note}" for each in jobs],
            self._circle(character, tokyo_date(now), plan.birthday),
        )

    def _circle(self, character: Character, day: date, birthday: bool) -> list[Member]:
        """Her circle on `day` in Tokyo, on her `birthday` or not, as drawn."""
        world = self._world
        others = {
            id: each for id, each in self._characters.items()
            if id != character.id and not (world is not None and world.is_staff(each.name))
        }
        relations = _relations(character, others)
        unit = set(world.unit_mates(character.name)) if world is not None else set()
        mates = [id for id, each in others.items() if each.name in unit]
        related = [id for id in relations if id not in mates]
        strangers = [id for id in others if id not in mates and id not in relations]
        birthdays = {id for id, each in others.items() if is_birthday(each.birthday, day)}
        drawn = draw_circle(mates, related, strangers, birthdays, birthday, self._random)
        return [Member(others[id], relations.get(id)) for id in drawn]


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


def _when(shown: Sequence[_T], at: Sequence[datetime]) -> list[tuple[_T, str]]:
    """Each of `shown` with when it shows, as the database writes it."""
    return [(each, when.astimezone(UTC).isoformat()) for each, when in zip(shown, at, strict=True)]


def _relations(character: Character, others: Mapping[str, Character]) -> dict[str, str]:
    """What a section of her facts on the people she knows says of each of `others` whose
    name is in its heading, but for sections whose headings have `NOT_ONE` in them, without
    their headings: the first for one in two."""
    relations: dict[str, str] = {}
    for fact in character.facts:
        headings = fact.headings
        if headings[:1] != [RELATIONS] or len(headings) < 2:
            continue
        if any(word in headings[-1] for word in NOT_ONE):
            continue
        for id, each in others.items():
            if each.name in headings[-1]:
                relations.setdefault(id, fact.body)
    return relations


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
        " VALUES (?, ?, ?, ?, ?, ?)",
        [(user_id, p.character_id, day, p.due_at.astimezone(UTC).isoformat(), p.kind,
          int(p.birthday))
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
              datetime.fromisoformat(due_at), bool(birthday), kind)
        for id, user_id, character_id, day, due_at, birthday, kind in db.execute(
            "SELECT id, user_id, character_id, day, due_at, birthday, kind FROM moment_plans"
            " WHERE due_at <= ? ORDER BY due_at, id",
            (now,),
        )
    ]


def _put_off(db: sqlite3.Connection, plan_id: int, due_at: str) -> None:
    db.execute("UPDATE moment_plans SET due_at = ? WHERE id = ?", (due_at, plan_id))


def _drop_plan(db: sqlite3.Connection, plan_id: int) -> None:
    db.execute("DELETE FROM moment_plans WHERE id = ?", (plan_id,))


def _add_moment(
    db: sqlite3.Connection,
    plan: _Plan,
    ja: str,
    zh: str,
    place: Place | None,
    weather: Weather | None,
    posted_at: str,
    likes: Sequence[tuple[str, str]],
    comments: Sequence[tuple[Comment, str]],
) -> None:
    """Post the moment planned, at a copy of `place`, in `weather`, with the `likes` and
    `comments` of her circle, each with when it shows; taking it off the plan."""
    moment_id = db.execute(
        "INSERT INTO moments (user_id, character_id, ja, zh, place_id, place_name, place_lat,"
        " place_lon, weather, temperature, day, posted_at)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (plan.user_id, plan.character_id, ja, zh,
         *((place.id, place.name, place.lat, place.lon) if place else (None,) * 4),
         *((weather.kind, weather.temperature) if weather else (None, None)),
         plan.day.isoformat(), posted_at),
    ).lastrowid
    db.executemany(
        "INSERT INTO moment_circle (moment_id, character_id, kind, ja, zh, position, shown_at)"
        " VALUES (?, ?, ?, ?, ?, ?, ?)",
        [(moment_id, id, _LIKE, None, None, i, at) for i, (id, at) in enumerate(likes)]
        + [(moment_id, c.character_id, _COMMENT, c.ja, c.zh, i, at)
           for i, (c, at) in enumerate(comments)],
    )
    _drop_plan(db, plan.id)


def _before(db: sqlite3.Connection, user_id: str, character_id: str, since: str) -> _Before:
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
    used = {
        place_id for (place_id,) in db.execute(
            "SELECT place_id FROM moments WHERE user_id = ? AND posted_at > ?"
            " AND place_id IS NOT NULL",
            (user_id, since),
        )
    }
    return _Before(read_profile(db, user_id), conversation, messages, recent, used)


def _timeline(db: sqlite3.Connection, user_id: str, since: str, now: str) -> list[Moment]:
    likes: dict[int, list[str]] = {}
    comments: dict[int, list[Comment]] = {}
    for moment_id, character_id, kind, ja, zh in db.execute(
        "SELECT c.moment_id, c.character_id, c.kind, c.ja, c.zh"
        " FROM moment_circle c JOIN moments m ON m.id = c.moment_id"
        " WHERE m.user_id = ? AND m.posted_at > ? AND c.shown_at <= ?"
        " ORDER BY c.shown_at, c.position",
        (user_id, since, now),
    ):
        if kind == _LIKE:
            likes.setdefault(moment_id, []).append(character_id)
        else:
            comments.setdefault(moment_id, []).append(Comment(character_id, ja, zh))
    return [
        Moment(id, character_id, ja, zh, posted_at,
               ShownPlace(name, lat, lon) if name is not None else None,
               Weather(kind, temperature) if kind in ALL_KINDS else None,
               tuple(likes.get(id, ())), tuple(comments.get(id, ())))
        for id, character_id, ja, zh, posted_at, name, lat, lon, kind, temperature
        in db.execute(
            "SELECT id, character_id, ja, zh, posted_at, place_name, place_lat, place_lon,"
            " weather, temperature FROM moments"
            " WHERE user_id = ? AND posted_at > ? AND posted_at <= ?"
            " ORDER BY posted_at DESC, id DESC",
            (user_id, since, now),
        )
    ]
