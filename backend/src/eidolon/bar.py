"""The bar (GLOSSARY.md「酒吧」「光顾」): characters come to VA-283, order, and the producer
serves them; the chat model writes what is said, the server decides everything else.

`Bar` is all there is to it from outside: reading it (whether it is open, its drinks), a
user coming in, serving a drink, and leaving. Everything a visit draws, judges and writes
down is done in here; the API only carries it over HTTP.

**A visit.** Each user has at most one at a time, kept in memory and named by an id made up
for it; coming in again does away with the one before. As she comes in, the server draws
who she is: the user's character of the day (Beijing's, `affinity.day_of`), by the user and
the day alone, until they have a visit done that day, and from then on anyone, each as
likely; whether she is in a cooldown or not. Then her reason for coming: half the time the
job of hers the producer scheduled today and she has done, if there is one, else one of the
list's not for leaving her out (`not_for`) and none of her `bar_visits.RECENT_VISITS` latest
visits with the user, unless that leaves none; the topic likewise; and how many drinks she
has (`bar_rules.CUPS`). Each of her orders is drawn just before the call that has her order
it (`bar_rules.draw_order`), knowing whether the user is a novice at the bar and what she
wanted the last time.

**Calls.** A visit is written in as many calls as she has drinks, and one more: her coming in
and first order; after each drink served, her reaction, the talk and her next order; after
the last she has, her reaction, a short talk and her farewell (`bar_prompt`). The last she
has is the last planned, or the one that leaves her drunk (`bar_rules.drunk`), who then
talks and says goodbye drunk. Each streams her lines and the producer's as they close
(`bar_reply`); the line she orders in is held back to the end of its call, with what follows
it, and sent with the order memo once it names drinks as it should
(`bar_rules.names_rightly`): if it does not, the call is made again for it alone, told so,
and if that does not either, she says one of the fixed lines instead
(`bar_rules.fixed_order`). A call with no line at all, or failing, ends the visit for now.

**Serving.** What the bar counter holds is matched against the recipes (`DrinkCatalog.match`):
broken, it is refused and nothing changes; anything else is served her and judged
(`bar_rules.judged`), the producer saying one of the fixed lines as he does.

**Done.** A visit is done the moment its farewell is written: one row is written down for it
(`visit_records`, one of a user's data, `database.USER_DATA`): who came, when, why, what about,
each order, whether she got drunk; nothing of what was said. Her visits with the user done
are what she remembers of the bar, next time; a visit left before it is done is not.

Nothing of the bar is told to the conversations, nor written in them or in memory.
"""

import hashlib
import json
import logging
import secrets
import sqlite3
from collections.abc import AsyncGenerator, Callable, Sequence
from dataclasses import dataclass, field, replace
from datetime import date, datetime
from typing import Literal, TypeVar

from eidolon.affinity import Affinities, affinity_prompt, day_of
from eidolon.bar_lines import BarLines
from eidolon.bar_prompt import (
    Remembered,
    farewell_ask,
    opening_ask,
    prompt,
    rewrite_ask,
    serving_ask,
    shared_prompt,
    visit_prompt,
)
from eidolon.bar_reply import BarLine, BarParser
from eidolon.bar_rules import (
    NOVICE_VISITS,
    Had,
    Known,
    Order,
    Reason,
    Serving,
    cups,
    draw_order,
    drunk,
    fixed_order,
    judged,
    names_rightly,
)
from eidolon.bar_visits import RECENT_VISITS, BarVisits, Topic
from eidolon.bar_visits import Reason as ListedReason
from eidolon.characters import Character
from eidolon.clock import Clock
from eidolon.data_access import Database
from eidolon.drink_catalog import DrinkCatalog, Mixture
from eidolon.llm import ChatLLM
from eidolon.own_keys import BroughtKeys, OwnKeyFailed, OwnKeys
from eidolon.producer import producer_prompt
from eidolon.randomness import Random
from eidolon.schedule import HerSchedule, Job, Schedules
from eidolon.store import read_profile
from eidolon.today import today_lines
from eidolon.world import World

log = logging.getLogger(__name__)

FAILED = "出了点问题，这次光顾没能接着写下去，请稍后再来"

_SCHEMA = """
-- One row per visit done (GLOSSARY.md「光顾」): who came to whom, as she came in and as she
-- said goodbye, the day she came in on (Beijing's), her reason for coming (its identifier, or
-- the job's name where it was one of hers done that day) and topic, each order as JSON (what
-- she wanted, how she said it, what was served, whether big, how well), whether she got
-- drunk, and whether the visit was rewarded. Nothing of what was said.
CREATE TABLE IF NOT EXISTS visit_records (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL REFERENCES users(id),
    character_id TEXT NOT NULL,
    entered_at TEXT NOT NULL,
    left_at TEXT NOT NULL,
    entered_on TEXT NOT NULL,
    reason TEXT NOT NULL,
    topic TEXT NOT NULL,
    orders TEXT NOT NULL,
    drunk INTEGER NOT NULL,
    rewarded INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS visit_records_by_her ON visit_records (user_id, character_id, id);
CREATE INDEX IF NOT EXISTS visit_records_by_day ON visit_records (user_id, entered_on);
"""


class BarClosed(Exception):
    """The deployment has the bar off: no one comes in."""

    def __init__(self) -> None:
        super().__init__("酒吧暂时没有开放")


class VisitGone(Exception):
    """There is no such visit of the user's under way: never was, left, done, or done away
    with by another."""

    def __init__(self) -> None:
        super().__init__("这次光顾已经结束了")


class NotWaiting(Exception):
    """She is not waiting for a drink: her lines are still being written."""

    def __init__(self) -> None:
        super().__init__("她还没在等这一杯")


class BrokenDrink(Exception):
    """What the bar counter holds is none of the drinks: it cannot be served."""

    def __init__(self) -> None:
        super().__init__("调坏了，不能上")


@dataclass(frozen=True)
class VisitBegan:
    visit_id: str
    character_id: str

    def shown(self) -> dict:
        return {"type": "visit", "visit_id": self.visit_id, "character_id": self.character_id}


@dataclass(frozen=True)
class Memo:
    """The order memo, after the line she ordered in."""

    text: str

    def shown(self) -> dict:
        return {"type": "memo", "text": self.text}


@dataclass(frozen=True)
class Waiting:
    """The call is written: she waits for her drink."""

    def shown(self) -> dict:
        return {"type": "waiting"}


@dataclass(frozen=True)
class VisitDone:
    """Her farewell is written: the visit is done."""

    def shown(self) -> dict:
        return {"type": "done", "rewarded": None}


@dataclass(frozen=True)
class VisitFailed:
    """The call could not be written: the visit is over."""

    message: str

    def shown(self) -> dict:
        return {"type": "failed", "message": self.message}


BarEvent = VisitBegan | BarLine | Memo | Waiting | VisitDone | VisitFailed

Step = Literal["writing", "waiting"]

_Listed = TypeVar("_Listed", ListedReason, Topic)


@dataclass
class _Visit:
    id: str
    user_id: str
    character: Character
    entered_at: datetime
    entered_on: date
    """Beijing's day she came in on, which the visit is of."""
    reason: Reason
    topic: Topic
    cups: int
    known: Known
    """What her orders are drawn knowing."""
    shared: str
    """The first part of every call's prompt (`bar_prompt.shared_prompt`)."""
    about: str
    """The second (`bar_prompt.visit_prompt`)."""
    orders: list[Order] = field(default_factory=list)
    servings: list[Serving] = field(default_factory=list)
    written: list[tuple[str, list[BarLine]]] = field(default_factory=list)
    """What each call so far asked for, and what was written."""
    drunk: bool = False
    """Whether she has had as much as she holds (`bar_rules.drunk`)."""
    step: Step = "writing"


@dataclass(frozen=True)
class _Before:
    """What a user coming in reads first: whether they have a visit done today, and how many
    they have done, with anyone."""

    done_today: bool
    visits_done: int


@dataclass(frozen=True)
class _Hers:
    """What is read of her visits with the user before she comes in, and who they are."""

    remembered: Remembered
    reasons: frozenset[str]
    """Her latest visits' reasons for coming."""
    topics: frozenset[str]
    about_producer: str


class Bar:
    """The bar, and every user's visit under way."""

    def __init__(
        self,
        db: Database,
        clock: Clock,
        characters: dict[str, Character],
        catalog: DrinkCatalog,
        listed: BarVisits,
        lines: BarLines,
        own_keys: OwnKeys,
        is_on: Callable[[], bool],
        random: Random,
        *,
        world: World | None = None,
        affinities: Affinities | None = None,
        schedules: Schedules | None = None,
    ) -> None:
        """`is_on` tells whether the bar is open now (the live configuration's switch). Without
        `world`, she has no world setting; without `affinities`, no affinity; without
        `schedules`, no job of hers for a reason. Her reasons for coming and topics are drawn
        from `listed`."""
        self._db = db
        self._clock = clock
        self._characters = characters
        self._catalog = catalog
        self._listed = listed
        self._lines = lines
        self._own_keys = own_keys
        self._is_on = is_on
        self._random = random
        self._world = world
        self._affinities = affinities
        self._schedules = schedules
        self._visits: dict[str, _Visit] = {}
        """Each user's visit under way, by user."""
        db.prepare(_open)

    def read(self) -> dict:
        """Whether the bar is open and, if it is, its drinks in catalog order."""
        if not self._is_on():
            return {"enabled": False}
        return {"enabled": True, "drinks": self._catalog.described()}

    async def enter(
        self, user_id: str, brought: BroughtKeys, device_timezone: str | None = None
    ) -> AsyncGenerator[BarEvent, None]:
        """A visit begun for the user, bringing `brought`, their device in `device_timezone`,
        doing away with any of theirs under way: its first call's events, from the visit's
        id and who she is on. Raises BarClosed while the bar is off."""
        if not self._is_on():
            raise BarClosed()
        now = self._clock()
        today = day_of(now)
        before = await self._db.read(_before, user_id, today)
        everyone = list(self._characters.values())
        if before.done_today:
            character = everyone[self._random(len(everyone))]
        else:
            character = everyone[_of_the_day(user_id, today, len(everyone))]
        her_jobs = (
            await self._schedules.hers(user_id, character.id, device_timezone)
            if self._schedules is not None else None
        )
        hers = await self._db.read(_hers, user_id, character.id)
        status = (
            await self._affinities.status(user_id, character.id)
            if self._affinities is not None else None
        )
        reason = self._reason(character, _done_today(her_jobs), hers.reasons)
        topic = self._topic(character, hers.topics)
        drinks = cups(self._random)
        known = Known(
            before.visits_done < NOVICE_VISITS,
            frozenset(h.wanted for h in hers.remembered.last_orders),
        )
        first = draw_order(character, self._catalog, self._random, [], known)
        world = self._world
        visit = _Visit(
            secrets.token_urlsafe(16), user_id, character, now, today, reason, topic, drinks,
            known,
            shared_prompt(character, world.prompt(character.name, today) if world else None),
            visit_prompt(
                hers.about_producer, reason, topic, drinks,
                affinity_prompt(status.tier, None) if status is not None else [],
                today_lines(
                    now, character, everyone, "apart", world.lives_of(character.name) if world else ()
                ),
                hers.remembered, now, character, self._catalog,
            ),
            [first],
        )
        self._visits[user_id] = visit
        return self._call(
            visit, brought, opening_ask(visit.orders[0]), VisitBegan(visit.id, character.id)
        )

    def serve(
        self, user_id: str, visit_id: str, served: Mixture | str, brought: BroughtKeys
    ) -> AsyncGenerator[BarEvent, None]:
        """Serve her what the bar counter holds, or a bottled drink by its identifier, in the
        user's visit `visit_id`, bringing `brought`: the events of the call after it, from the
        producer saying one of the fixed lines on. Raises VisitGone unless it is the user's
        visit under way; NotWaiting unless she waits for a drink; BrokenDrink, changing
        nothing, if what is served is none of the drinks."""
        visit = self._under_way(user_id, visit_id)
        if visit.step != "waiting":
            raise NotWaiting()
        glass = self._catalog.match(served)
        if glass is None:
            raise BrokenDrink()
        serving = judged(visit.orders[-1], glass, visit.character)
        visit.servings.append(serving)
        visit.drunk = drunk(visit.character, visit.servings)
        visit.step = "writing"
        enjoy = self._lines.enjoy[self._random(len(self._lines.enjoy))]
        if len(visit.servings) < visit.cups and not visit.drunk:
            ordered = [o.target.id for o in visit.orders]
            order = draw_order(visit.character, self._catalog, self._random, ordered, visit.known)
            visit.orders.append(order)
            ask = serving_ask(serving, enjoy, order)
        else:
            ask = farewell_ask(serving, enjoy, visit.servings, drunk=visit.drunk)
        return self._call(visit, brought, ask, BarLine("producer", enjoy))

    def leave(self, user_id: str, visit_id: str) -> None:
        """The user leaves their visit `visit_id`, which is over. Raises VisitGone unless it is
        theirs under way."""
        self._end(self._under_way(user_id, visit_id))

    def _under_way(self, user_id: str, visit_id: str) -> _Visit:
        visit = self._visits.get(user_id)
        if visit is None or visit.id != visit_id:
            raise VisitGone()
        return visit

    def _end(self, visit: _Visit) -> None:
        if self._visits.get(visit.user_id) is visit:
            del self._visits[visit.user_id]

    def _reason(self, character: Character, job: Job | None, recent: frozenset[str]) -> Reason:
        """Her reason for coming: half the time `job`, if any; else one of the list's for her,
        none of the `recent` unless that leaves none."""
        if job is not None and self._random(2) == 0:
            return Reason(job.name, job.note, None, job=True)
        listed = self._fresh(
            [r for r in self._listed.reasons if character.id not in r.not_for], recent
        )
        return Reason(listed.id, listed.note, listed.mood)

    def _topic(self, character: Character, recent: frozenset[str]) -> Topic:
        return self._fresh(
            [t for t in self._listed.topics if character.id not in t.not_for], recent
        )

    def _fresh(self, entries: Sequence[_Listed], recent: frozenset[str]) -> _Listed:
        """One of `entries`, none of the `recent` unless that leaves none."""
        fresh = [e for e in entries if e.id not in recent] or entries
        return fresh[self._random(len(fresh))]

    async def _call(
        self, visit: _Visit, brought: BroughtKeys, ask: str, first: BarEvent
    ) -> AsyncGenerator[BarEvent, None]:
        """A call of `visit`, asking for `ask`, sending `first` before it: its lines as they
        close, held back from the line she orders in on, if she is to order; then the memo
        and that she waits, or that the visit is done. A visit left or done away with
        meanwhile is written no further, and the call ends there."""
        yield first
        ordering = len(visit.orders) > len(visit.servings)
        keys = self._own_keys.for_turn(brought)
        over = True
        try:
            said: list[BarLine] = []
            held: list[BarLine] = []
            parser = BarParser()
            stream = keys.llms.chat.stream(prompt(visit.shared, visit.about, visit.written, ask))
            try:
                async for chunk in stream:
                    if not isinstance(chunk, str):
                        continue
                    if self._visits.get(visit.user_id) is not visit:
                        return  # left, or done away with by another: written no further
                    for line in parser.feed(chunk):
                        for shown in _holding(line, held, ordering):
                            said.append(shown)
                            yield shown
                for line in parser.finish():
                    for shown in _holding(line, held, ordering):
                        said.append(shown)
                        yield shown
            finally:
                if (close := getattr(stream, "aclose", None)) is not None:
                    await close()
            if ordering:
                if not held:
                    raise _Unwritten("she did not order")
                if not any(line.order for line in held):
                    held[0] = replace(held[0], order=True)
                held = await self._named(visit, keys.llms.chat, ask, said, held)
                if self._visits.get(visit.user_id) is not visit:
                    return
                said += held
                for line in held:
                    yield line
            if not said:
                raise _Unwritten("nothing was written")
            if self._visits.get(visit.user_id) is not visit:
                return
            visit.written.append((ask, said))
            if ordering:
                visit.step = "waiting"
                over = False
                yield Memo(visit.orders[-1].memo("".join(line.zh for line in held if line.order)))
                yield Waiting()
                return
            await self._db.write(_write_down, visit, self._clock())
            yield VisitDone()
        except OwnKeyFailed as e:  # theirs to fix, so they are told what went wrong
            log.warning("a visit's call failed on the user's own key: %s", e.service)
            yield VisitFailed(e.message)
        except Exception:
            log.exception("a visit's call failed")
            yield VisitFailed(FAILED)
        finally:
            keys.release()
            if over:
                self._end(visit)


    async def _named(
        self, visit: _Visit, chat: ChatLLM, ask: str, said: list[BarLine], held: list[BarLine]
    ) -> list[BarLine]:
        """`held`, her order and what follows it in a call asking for `ask`, after `said`, with
        her order naming drinks as it should: as written, rewritten in another call, or else
        said in a fixed line, the visit's last order then changed to how that line says it (an
        analogy to conditions)."""
        order = visit.orders[-1]
        rest = [line for line in held if not line.order]
        if names_rightly(order, [line for line in held if line.order], self._catalog):
            return held
        rewritten = await self._rewritten(visit, chat, rewrite_ask(ask, order, said))
        if rewritten and names_rightly(order, rewritten, self._catalog):
            return [*rewritten, *rest]
        visit.orders[-1], fixed = fixed_order(order, self._lines, self._random)
        return [*fixed, *rest]

    async def _rewritten(self, visit: _Visit, chat: ChatLLM, ask: str) -> list[BarLine]:
        """Her order as a call asking for `ask` writes it: her lines marked as her order, or
        else her last; none if it writes none of hers, or fails."""
        parser = BarParser()
        lines: list[BarLine] = []
        stream = chat.stream(prompt(visit.shared, visit.about, visit.written, ask))
        try:
            async for chunk in stream:
                if isinstance(chunk, str):
                    lines += parser.feed(chunk)
            lines += parser.finish()
        except Exception:
            log.exception("rewriting an order failed")
            return []
        finally:
            if (close := getattr(stream, "aclose", None)) is not None:
                await close()
        hers = [line for line in lines if line.speaker == "her"]
        return [line for line in hers if line.order] or [replace(h, order=True) for h in hers[-1:]]


class _Unwritten(RuntimeError):
    """The model wrote no line a call needs."""


def _holding(line: BarLine, held: list[BarLine], ordering: bool) -> list[BarLine]:
    """The lines to send now that `line` has closed, `held` keeping those not to be sent yet:
    in a call she orders in, her latest line and what follows it, which may be her order,
    and anything from a line marked as her order on."""
    if not ordering:
        return [line]
    if any(h.order for h in held):
        held.append(line)
        return []
    if line.speaker == "her":
        sent = list(held)
        held[:] = [line]
        return sent
    if held:
        held.append(line)
        return []
    return [line]


def _of_the_day(user_id: str, today: date, characters: int) -> int:
    """Which character is the user's of the day `today`."""
    digest = hashlib.sha256(f"{user_id}/{today.isoformat()}".encode()).digest()
    return int.from_bytes(digest[:8], "big") % characters


def _done_today(schedule: HerSchedule | None) -> Job | None:
    """The job of hers the producer scheduled today where they are and she has done, the
    latest if more than one; None without."""
    if schedule is None:
        return None
    today = schedule.local.weekday()
    done = [
        j for j in schedule.jobs
        if j.week == schedule.this_week and j.day == today
        and schedule.time_of(j.week, j.day, j.slot + j.job.length - 1) == "past"
    ]
    return done[-1].job if done else None


def _open(db: sqlite3.Connection) -> None:
    db.executescript(_SCHEMA)


def _before(db: sqlite3.Connection, user_id: str, today: date) -> _Before:
    found = db.execute(
        "SELECT 1 FROM visit_records WHERE user_id = ? AND entered_on = ? LIMIT 1",
        (user_id, today.isoformat()),
    ).fetchone()
    (done,) = db.execute(
        "SELECT COUNT(*) FROM visit_records WHERE user_id = ?", (user_id,)
    ).fetchone()
    return _Before(found is not None, done)


def _hers(db: sqlite3.Connection, user_id: str, character_id: str) -> _Hers:
    (count,) = db.execute(
        "SELECT COUNT(*) FROM visit_records WHERE user_id = ? AND character_id = ?",
        (user_id, character_id),
    ).fetchone()
    rows = db.execute(
        "SELECT left_at, reason, topic, orders, drunk FROM visit_records"
        " WHERE user_id = ? AND character_id = ? ORDER BY id DESC LIMIT ?",
        (user_id, character_id, RECENT_VISITS),
    ).fetchall()
    remembered = Remembered(count)
    if rows:
        left_at, _, _, orders, drunk = rows[0]
        remembered = Remembered(
            count, datetime.fromisoformat(left_at),
            tuple(Had(**o) for o in json.loads(orders)), bool(drunk),
        )
    return _Hers(
        remembered, frozenset(r[1] for r in rows), frozenset(r[2] for r in rows),
        producer_prompt(read_profile(db, user_id)),
    )


def _write_down(db: sqlite3.Connection, visit: _Visit, now: datetime) -> None:
    orders = [
        {
            "target": s.order.target.id, "phrasing": s.order.phrasing,
            "served": s.served.drink.id, "big": s.served.big, "tier": s.tier,
        }
        for s in visit.servings
    ]
    db.execute(
        "INSERT INTO visit_records (user_id, character_id, entered_at, left_at, entered_on,"
        " reason, topic, orders, drunk, rewarded) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)",
        (
            visit.user_id, visit.character.id, visit.entered_at.isoformat(), now.isoformat(),
            visit.entered_on.isoformat(), visit.reason.id, visit.topic.id,
            json.dumps(orders), int(visit.drunk),
        ),
    )
