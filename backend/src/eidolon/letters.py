"""Letters (GLOSSARY.md「信」): what she writes the producer on an occasion between them, for
the producer to keep and read again.

Only where the deployer turns them on (`LiveConfig.letters_on`). The occasions so far are
those the achievements tell (`Happenings`): her affinity first reaching close, first reaching
intimate, and her being complete. Each is kept, in the transaction the achievement is, as a
letter to be written that day where the producer is, in the profile's time zone (or
`Asia/Shanghai`), from then on (`happened`); none while the deployer has letters off, and
none for what was reached before the achievements launched. Every `TICK` the backend writes
those whose time has come (`run_due`): those of one character and one day together, in one
letter. One of a day she has written a letter on already is put off to the next.

Each is looked at again as it is written: the deployer still has letters on; the user is not
banned, nor let take no turns on the deployer's keys; she is not cold or distant, nor in a
cooldown. If not, it is passed over, for good. While the deployer has letters off, every one
not written is passed over.

She writes on the deployer's chat model as text turns use it, whoever's LLM the user brings,
held only while she does: nothing counts towards the user's limits. What she writes with is
read beforehand (`letter_prompt.LetterMaterial`): the tier she writes in, that reached for a
letter on it, else hers then; the day they first talked and how many turns they have had; her
own `MEMORIES` latest memories of the producer not superseded; their `MESSAGES` latest
messages across every conversation; the `EARLIER` letters she wrote them last. A body longer
than `LONGEST` she is asked once to write shorter; still longer, it is kept as it is. Each
letter has an activity record of its own (`letter`), on the deployer's keys, its service
calls under it; one the model fails, or writes no letter in, is recorded failed, and passed
over.

The user's letters are theirs alone to read (`listed`, `letter`), the latest first; reading
one has it read, on every device (`mark_read`). Turned off, the deployer's letters stay to be
read. Deleting the user deletes them (`database.USER_DATA`); deleting a conversation does
not."""

import asyncio
import json
import logging
import sqlite3
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, replace
from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from eidolon.activity import ActivityLog
from eidolon.affinity import BELOW_TRUST, Affinities, Tier
from eidolon.characters import Character
from eidolon.clock import Clock
from eidolon.data_access import Database
from eidolon.letter_prompt import (
    OCCASIONS,
    Earlier,
    LetterMaterial,
    Occasion,
    Paragraph,
    Said,
    Written,
    letter_prompt,
    parse_letter,
    shorter_prompt,
    shown,
)
from eidolon.live_config import LiveConfig
from eidolon.llm import ChatLLM
from eidolon.moments import written_whole
from eidolon.producer import effective_timezone, local_date
from eidolon.store import read_profile
from eidolon.usage import read_user_limits

log = logging.getLogger(__name__)

TICK = timedelta(minutes=1)
"""How often the letters whose time has come are written."""

LONGEST = 330
"""How long a letter's body may be, in characters of its Japanese without delivery cues,
before she is asked to write it shorter."""

MEMORIES = 30
"""How many of her latest memories of the producer she writes with."""

MESSAGES = 60
"""How many of their latest messages she writes with."""

EARLIER = 3
"""How many of the letters she wrote the producer last she writes with."""

_SCHEMA = """
-- A letter she wrote the user (GLOSSARY.md「信」): on what (a JSON array of occasions), the
-- day where the producer is, when, and what it says, the Japanese of its paragraphs with
-- delivery cues (a JSON array of {"ja", "zh"}); when the user read it, and when it popped up
-- on its own, NULL for not yet; the activity record it was written under.
CREATE TABLE IF NOT EXISTS letters (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL REFERENCES users(id),
    character_id TEXT NOT NULL,
    occasions TEXT NOT NULL,
    day TEXT NOT NULL,
    written_at TEXT NOT NULL,
    salutation TEXT NOT NULL,
    paragraphs TEXT NOT NULL,
    read_at TEXT,
    popped_at TEXT,
    record_id INTEGER
);
CREATE INDEX IF NOT EXISTS letters_by_user ON letters(user_id, character_id, day);
-- A letter read aloud, block by block: 0 the salutation, then each paragraph; MP3.
CREATE TABLE IF NOT EXISTS letter_voices (
    letter_id INTEGER NOT NULL REFERENCES letters(id),
    block INTEGER NOT NULL,
    mp3 BLOB NOT NULL,
    PRIMARY KEY (letter_id, block)
);
-- A letter to be written: of which occasion, the day it is of where the producer is, from
-- when, and how many times it has been tried.
CREATE TABLE IF NOT EXISTS letters_due (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL REFERENCES users(id),
    character_id TEXT NOT NULL,
    occasion TEXT NOT NULL,
    day TEXT NOT NULL,
    due_at TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS letters_due_by_time ON letters_due(due_at);
"""


@dataclass(frozen=True)
class Listed:
    """A letter in the user's letters: whose, on what, the day, and whether they have read
    it, and whether it has popped up."""

    id: int
    character_id: str
    occasions: tuple[Occasion, ...]
    day: date
    read: bool
    popped: bool

    def shown(self) -> dict:
        """As the browser is told it."""
        return {
            "id": self.id,
            "character_id": self.character_id,
            "occasions": list(self.occasions),
            "day": self.day.isoformat(),
            "read": self.read,
            "popped": self.popped,
        }


@dataclass(frozen=True)
class Letter:
    """A letter as the user reads it: whose, on what, the day, what it says, and the name she
    signs it with."""

    id: int
    character_id: str
    occasions: tuple[Occasion, ...]
    day: date
    written: Written
    signed: str

    def shown(self) -> dict:
        """As the browser is told it: without delivery cues; no voice nor music yet, and her
        name written out for her signature."""
        return {
            "id": self.id,
            "character_id": self.character_id,
            "occasions": list(self.occasions),
            "day": self.day.isoformat(),
            "salutation": shown(self.written.salutation),
            "paragraphs": [{"ja": shown(p.ja), "zh": p.zh} for p in self.written.paragraphs],
            "signature": {"image": None, "text": self.signed},
            "voice": None,
            "music": None,
        }


@dataclass(frozen=True)
class _Standing:
    """What is read of the user, at one moment, to tell whether and how she writes them a
    letter: her tier with them (None where affinity is off), the producer's time zone, and
    whether she has written them a letter that day already."""

    tier: Tier | None
    zone: ZoneInfo
    written_today: bool


@dataclass(frozen=True)
class _Due:
    """The letters to be written of one character and one day, together, whose time has
    come."""

    ids: tuple[int, ...]
    user_id: str
    character_id: str
    occasions: tuple[Occasion, ...]
    day: date


class Letters:
    """Her letters, in `db`, on the deployer's chat model of `config`, each recorded in
    `activity`."""

    def __init__(
        self,
        db: Database,
        characters: Mapping[str, Character],
        config: LiveConfig,
        affinities: Affinities,
        activity: ActivityLog,
        clock: Clock,
    ) -> None:
        self._db = db
        self._characters = characters
        self._config = config
        self._affinities = affinities
        self._activity = activity
        self._clock = clock
        db.prepare(_open)

    async def keep_writing(self) -> None:
        """`run_due` at every `TICK`, until cancelled."""
        while True:
            await asyncio.sleep(TICK.total_seconds())
            try:
                await self.run_due()
            except Exception:
                log.exception("writing letters failed")

    async def run_due(self) -> None:
        """Write every letter whose time has come, one after another; one going wrong keeps
        none of the others from it. While the deployer has letters off, pass over every one
        to be written; without the chat model, write none."""
        if not self._config.letters_on:
            await self._db.write(_forget_due)
            return
        if not self._config.has_service("chat_llm"):
            return
        now = self._clock()
        for due in await self._db.read(_due, _utc(now)):
            try:
                await self._write(due, now)
            except Exception:
                log.exception("a letter to user %s failed", due.user_id)
                await self._db.write(_drop, due.ids)

    def happened(
        self,
        db: sqlite3.Connection,
        user_id: str,
        occasions: Sequence[tuple[str, Occasion]],
        now: datetime,
    ) -> None:
        """Each character of `occasions` has her occasion with the user `now`: kept, through
        `db`, in the transaction it happened in, as a letter to be written that day where the
        producer is; none while the deployer has letters off."""
        if not occasions or not self._config.letters_on:
            return
        day = local_date(now, effective_timezone(read_profile(db, user_id), None))
        db.executemany(
            "INSERT INTO letters_due (user_id, character_id, occasion, day, due_at)"
            " VALUES (?, ?, ?, ?, ?)",
            [(user_id, c, o, day.isoformat(), _utc(now)) for c, o in occasions],
        )

    async def listed(self, user_id: str) -> list[Listed]:
        """The user's letters, the latest first."""
        return await self._db.read(_listed, user_id)

    async def letter(self, user_id: str, letter_id: int) -> Letter | None:
        """The user's letter; None if it is not theirs, or there is none."""
        letter = await self._db.read(_letter, user_id, letter_id)
        if letter is None:
            return None
        character = self._characters.get(letter.character_id)
        return replace(letter, signed=character.name) if character is not None else letter

    async def mark_read(self, user_id: str, letter_id: int) -> bool:
        """Have the user's letter read, now, if not before; False if it is not theirs."""
        return await self._db.write(_mark_read, user_id, letter_id, self._clock().isoformat())

    async def _write(self, due: _Due, now: datetime) -> None:
        """Write the letter, unless she is not to, or has written one that day already, then
        put off to the next."""
        if due.character_id not in self._characters:
            await self._db.write(_drop, due.ids)
            return
        affinity_on = self._affinities.on
        standing = await self._db.read(self._standing, due, affinity_on)
        if standing is None:
            await self._db.write(_drop, due.ids)
            return
        tier, zone = standing.tier, standing.zone
        if standing.written_today:
            await self._db.write(_put_off, due.ids, due.day + timedelta(days=1), zone)
            return
        if "intimate" in due.occasions:
            tier = "intimate"
        elif "close" in due.occasions:
            tier = "close"
        material = await self._db.read(self._material, due, tier, zone)
        recording = self._activity.begin(
            "letter", due.user_id, due.character_id, own_llm=False, exempt=False
        )
        lease = self._config.lease()
        try:
            with recording.current():
                written = await self._written(lease.keys.chat_llm, material)
        except Exception as e:
            # Not logged with what was raised: a service's error may repeat what it was asked.
            log.warning("a letter to user %s failed: %s", due.user_id, type(e).__name__)
            written = None
        finally:
            lease.release()
        if written is None:
            await self._db.write(_drop, due.ids)
            await recording.finish("failed")
            return
        letter_id = await self._db.write(_add_letter, due, written, self._clock().isoformat())
        await recording.finish("success")
        await self._db.write(_recorded_as, letter_id, recording.row_id)

    async def _written(self, llm: ChatLLM, material: LetterMaterial) -> Written | None:
        """The letter she writes on `llm`; once more, shorter, if too long, kept as it is if
        still too long, or if she writes no letter the second time. None if she writes none."""
        prompt = letter_prompt(material)
        text = await written_whole(llm.stream(prompt))
        written = parse_letter(text)
        if written is None:
            log.warning("a letter failed: the model wrote no letter")
            return None
        if written.length <= LONGEST:
            return written
        try:
            shorter = parse_letter(await written_whole(llm.stream(shorter_prompt(prompt, text))))
        except Exception as e:
            log.warning("rewriting a letter shorter failed: %s", type(e).__name__)
            shorter = None
        return shorter or written

    def _standing(
        self, db: sqlite3.Connection, due: _Due, affinity_on: bool
    ) -> _Standing | None:
        """The user's standing for the letter, read through `db`; None if she is not to write
        it: the user gone or banned, let take no turns, or she cold, distant, or in a
        cooldown."""
        user = db.execute(
            "SELECT banned_at FROM users WHERE id = ?", (due.user_id,)
        ).fetchone()
        if user is None or user[0] is not None:
            return None
        limits = read_user_limits(db, due.user_id)
        if limits is not None and limits.turns_per_hour == 0:
            return None
        tier = None
        if affinity_on:
            status = self._affinities.read_status(db, due.user_id, due.character_id)
            if status.cooling or status.tier in BELOW_TRUST:
                return None
            tier = status.tier
        zone = ZoneInfo(effective_timezone(read_profile(db, due.user_id), None))
        written = db.execute(
            "SELECT 1 FROM letters WHERE user_id = ? AND character_id = ? AND day = ?",
            (due.user_id, due.character_id, due.day.isoformat()),
        ).fetchone()
        return _Standing(tier, zone, written is not None)

    def _material(
        self, db: sqlite3.Connection, due: _Due, tier: Tier | None, zone: ZoneInfo
    ) -> LetterMaterial:
        """What she writes the letter with, in `tier`, read through `db`."""
        user_id, character_id = due.user_id, due.character_id
        in_hers = (
            "FROM messages m JOIN conversations c ON c.id = m.conversation_id"
            " WHERE c.user_id = ? AND c.character_id = ?"
        )
        first, turns = db.execute(
            f"SELECT MIN(m.created_at), SUM(m.role = 'user') {in_hers}", (user_id, character_id)
        ).fetchone()
        memories = [
            text for (text,) in db.execute(
                "SELECT text FROM memories WHERE user_id = ? AND source_character_id = ?"
                " AND superseded_by IS NULL ORDER BY created_at DESC, id DESC LIMIT ?",
                (user_id, character_id, MEMORIES),
            )
        ]
        said = []
        for role, text, ja, at in db.execute(
            f"SELECT m.role, m.text, m.ja, m.created_at {in_hers}"
            " ORDER BY m.created_at DESC, m.id DESC LIMIT ?",
            (user_id, character_id, MESSAGES),
        ):
            words = shown(ja or "") if role == "character" else (text or "").strip()
            if words:
                said.append(Said(_day_of(at, zone), role == "character", words))
        earlier = [
            Earlier(date.fromisoformat(day), _occasions(occasions), _written(salutation, body))
            for day, occasions, salutation, body in db.execute(
                "SELECT day, occasions, salutation, paragraphs FROM letters"
                " WHERE user_id = ? AND character_id = ? ORDER BY written_at DESC, id DESC"
                " LIMIT ?",
                (user_id, character_id, EARLIER),
            )
        ]
        return LetterMaterial(
            self._characters[character_id],
            read_profile(db, user_id),
            tier,
            _day_of(first, zone) if first else None,
            turns or 0,
            memories[::-1],
            said[::-1],
            earlier[::-1],
            due.occasions,
            due.day,
        )


def _open(db: sqlite3.Connection) -> None:
    db.executescript(_SCHEMA)


def _utc(at: datetime) -> str:
    """`at` as the tables keep times: in UTC, so that they compare as text."""
    return at.astimezone(UTC).isoformat()


def _day_of(at: str, zone: ZoneInfo) -> date:
    return datetime.fromisoformat(at).astimezone(zone).date()


def _occasions(stored: str) -> tuple[Occasion, ...]:
    return tuple(json.loads(stored))


def _written(salutation: str, paragraphs: str) -> Written:
    return Written(salutation, tuple(Paragraph(p["ja"], p["zh"]) for p in json.loads(paragraphs)))


def _due(db: sqlite3.Connection, now: str) -> list[_Due]:
    """The letters to be written whose time has come by `now`, those of one character and one
    day together, the earliest first."""
    grouped: dict[tuple[str, str, str], list[tuple[int, str]]] = {}
    for id, user_id, character_id, occasion, day in db.execute(
        "SELECT id, user_id, character_id, occasion, day FROM letters_due WHERE due_at <= ?"
        " ORDER BY due_at, id",
        (now,),
    ):
        grouped.setdefault((user_id, character_id, day), []).append((id, occasion))
    return [
        _Due(
            tuple(id for id, _ in rows), user_id, character_id,
            tuple(o for o in OCCASIONS if any(o == occasion for _, occasion in rows)),
            date.fromisoformat(day),
        )
        for (user_id, character_id, day), rows in grouped.items()
    ]


def _drop(db: sqlite3.Connection, ids: Sequence[int]) -> None:
    db.executemany("DELETE FROM letters_due WHERE id = ?", [(id,) for id in ids])


def _forget_due(db: sqlite3.Connection) -> None:
    db.execute("DELETE FROM letters_due")


def _put_off(db: sqlite3.Connection, ids: Sequence[int], day: date, zone: ZoneInfo) -> None:
    """Put the letters to be written off to `day`, from its beginning where the producer is."""
    begins = _utc(datetime.combine(day, time(), zone))
    db.executemany(
        "UPDATE letters_due SET day = ?, due_at = ? WHERE id = ?",
        [(day.isoformat(), begins, id) for id in ids],
    )


def _add_letter(db: sqlite3.Connection, due: _Due, written: Written, at: str) -> int:
    """Keep the letter written `at`, taking what it was written for off those to be written."""
    letter_id = db.execute(
        "INSERT INTO letters (user_id, character_id, occasions, day, written_at, salutation,"
        " paragraphs) VALUES (?, ?, ?, ?, ?, ?, ?)",
        (
            due.user_id, due.character_id, json.dumps(list(due.occasions)), due.day.isoformat(),
            at, written.salutation,
            json.dumps([{"ja": p.ja, "zh": p.zh} for p in written.paragraphs], ensure_ascii=False),
        ),
    ).lastrowid
    _drop(db, due.ids)
    assert letter_id is not None
    return letter_id


def _recorded_as(db: sqlite3.Connection, letter_id: int, record_id: int | None) -> None:
    db.execute("UPDATE letters SET record_id = ? WHERE id = ?", (record_id, letter_id))


def _listed(db: sqlite3.Connection, user_id: str) -> list[Listed]:
    return [
        Listed(id, character_id, _occasions(occasions), date.fromisoformat(day),
               read_at is not None, popped_at is not None)
        for id, character_id, occasions, day, read_at, popped_at in db.execute(
            "SELECT id, character_id, occasions, day, read_at, popped_at FROM letters"
            " WHERE user_id = ? ORDER BY written_at DESC, id DESC",
            (user_id,),
        )
    ]


def _letter(db: sqlite3.Connection, user_id: str, letter_id: int) -> Letter | None:
    """The user's letter, signed with her id till her name is known."""
    row = db.execute(
        "SELECT character_id, occasions, day, salutation, paragraphs FROM letters"
        " WHERE id = ? AND user_id = ?",
        (letter_id, user_id),
    ).fetchone()
    if row is None:
        return None
    character_id, occasions, day, salutation, paragraphs = row
    return Letter(
        letter_id, character_id, _occasions(occasions), date.fromisoformat(day),
        _written(salutation, paragraphs), character_id,
    )


def _mark_read(db: sqlite3.Connection, user_id: str, letter_id: int, at: str) -> bool:
    if db.execute(
        "SELECT 1 FROM letters WHERE id = ? AND user_id = ?", (letter_id, user_id)
    ).fetchone() is None:
        return False
    db.execute(
        "UPDATE letters SET read_at = ? WHERE id = ? AND read_at IS NULL", (at, letter_id)
    )
    return True
