"""Reach-outs (GLOSSARY.md「搭话」): what she says first in her current conversation with the
user, the user not talking to her, once her time comes; whether or not the user is there to
see it.

Only where the deployer turns them on (`LiveConfig.reach_outs`). Every `TICK` the backend
runs, each user's current conversation with each character (GLOSSARY.md「当前对话」) is looked
at, if they were last in touch in it within `WINDOW`: when her last turn was recorded, or a
call that connected ended, whichever was later; gifts are not being in touch. Her time is
then the last contact and a time drawn from her tier's range (`INTERVALS`), at a place in it
drawn once for each contact (`PLACES`), drawn anew as the contact changes; trust's where
affinity is off. A conversation she is not to reach out in is passed over, its time left as
it is, to be looked at again at the next tick: one she has ended; one without a turn yet;
one she has reached out in since the last contact, so that she waits for the user to answer
first; one she is in a cooldown in, or cold or distant.

She reaches out on the deployer's chat model as text turns use it, whoever's LLM the user
brings, held only while she does (`ConversationEngine.reach_out`): nothing counts towards the
user's limits. Each reach-out has an activity record of its own (`reach_out`), on the
deployer's keys, its service calls under it, so that the dashboard's usage and costs count
them; one that fails, the model failing or saying nothing she could say, is recorded failed,
and not tried again until the user and she are in touch again.
"""

import asyncio
import logging
import threading
from collections.abc import Mapping
from datetime import datetime, timedelta
from pathlib import Path

from eidolon.activity import ActivityLog
from eidolon.affinity import Affinities, Tier
from eidolon.characters import Character
from eidolon.clock import Clock
from eidolon.database import connect
from eidolon.engine import ConversationEngine
from eidolon.live_config import LiveConfig
from eidolon.randomness import Random
from eidolon.store import Conversation, ConversationEnded, CurrentConversation, Store

log = logging.getLogger(__name__)

TICK = timedelta(minutes=1)
"""How often it is looked whose time has come."""

WINDOW = timedelta(days=7)
"""How long after the last contact she may still reach out."""

INTERVALS: dict[Tier, tuple[timedelta, timedelta]] = {
    "intimate": (timedelta(hours=3), timedelta(hours=6)),
    "close": (timedelta(hours=8), timedelta(hours=16)),
    "trust": (timedelta(hours=20), timedelta(hours=36)),
}
"""How long after the last contact she reaches out, by her tier: the closer, the sooner. None
in the tiers not here."""

PLACES = 1000
"""How many places in a tier's range her time may be drawn at, evenly apart."""

_SCHEMA = """
-- When she is to reach out in a conversation (GLOSSARY.md「搭话」): the last contact it was
-- drawn for (`contact_at`), and where in her tier's range (`place`, from 0 to 1). The other
-- two are for times put off: to the morning, where in its hours; and a time set instead.
CREATE TABLE IF NOT EXISTS reach_out_schedules (
    conversation_id TEXT PRIMARY KEY REFERENCES conversations(id),
    contact_at TEXT NOT NULL,
    place REAL NOT NULL,
    morning_place REAL,
    due_at TEXT
);
"""


class ReachOuts:
    """Her reach-outs, on the database at `path` beside the conversations of `store`, on the
    deployer's models of `config`, each recorded in `activity`; `random` draws when."""

    def __init__(
        self,
        path: Path,
        store: Store,
        engine: ConversationEngine,
        characters: Mapping[str, Character],
        config: LiveConfig,
        affinities: Affinities,
        activity: ActivityLog,
        clock: Clock,
        random: Random,
    ) -> None:
        self._store = store
        self._engine = engine
        self._characters = characters
        self._config = config
        self._affinities = affinities
        self._activity = activity
        self._clock = clock
        self._random = random
        self._db = connect(path)
        self._lock = threading.Lock()
        with self._lock, self._db:
            self._db.executescript(_SCHEMA)

    async def keep_reaching_out(self) -> None:
        """`run_due` at every `TICK`, until cancelled."""
        while True:
            await asyncio.sleep(TICK.total_seconds())
            try:
                await self.run_due()
            except Exception:
                log.exception("reaching out failed")

    async def run_due(self) -> None:
        """Reach out in every conversation whose time has come, one after another; one going
        wrong keeps none of the others from it."""
        if not self._config.reach_outs.enabled:
            return
        now = self._clock()
        for current in await asyncio.to_thread(self._store.current_conversations):
            try:
                if await asyncio.to_thread(self._due, current, now):
                    await self._reach_out(current)
            except Exception:
                log.exception("reaching out in conversation %s failed", current.conversation.id)

    def close(self) -> None:
        with self._lock:
            self._db.close()

    def _due(self, current: CurrentConversation, now: datetime) -> bool:
        """Whether her time to reach out in the conversation has come, and she is to."""
        conversation, contact = current.conversation, current.last_contact
        if conversation.character_id not in self._characters or current.ended:
            return False
        if not current.has_turns or contact is None:
            return False
        if now - contact > WINDOW:
            return False
        if current.reached_out_at is not None and current.reached_out_at >= contact:
            return False
        tier = self._tier(conversation)
        if tier is None:
            return False
        place, due = self._schedule(conversation.id, contact)
        if due is None:
            low, high = INTERVALS[tier]
            due = contact + low + (high - low) * place
        return now >= due

    def _tier(self, conversation: Conversation) -> Tier | None:
        """The tier she reaches out by, trust where affinity is off; None if she is not to,
        in a cooldown or in a tier without a range."""
        status = self._affinities.status(conversation.user_id, conversation.character_id)
        if status is None:
            return "trust"
        if status.cooling or status.tier not in INTERVALS:
            return None
        return status.tier

    def _schedule(self, conversation_id: str, contact: datetime) -> tuple[float, datetime | None]:
        """Where in her tier's range her time is, drawn for the last `contact`, and the time set
        instead, if one is."""
        at = contact.isoformat()
        with self._lock, self._db:
            row = self._db.execute(
                "SELECT contact_at, place, due_at FROM reach_out_schedules"
                " WHERE conversation_id = ?",
                (conversation_id,),
            ).fetchone()
            if row is not None and row[0] == at:
                return row[1], datetime.fromisoformat(row[2]) if row[2] else None
            place = self._random(PLACES) / PLACES
            self._db.execute(
                "INSERT OR REPLACE INTO reach_out_schedules (conversation_id, contact_at, place)"
                " VALUES (?, ?, ?)",
                (conversation_id, at, place),
            )
        return place, None

    def _give_up(self, conversation_id: str, contact: datetime) -> None:
        """Not try again until the user and she are in touch again: her time for `contact` is
        put past `WINDOW`."""
        with self._lock, self._db:
            self._db.execute(
                "UPDATE reach_out_schedules SET due_at = ?"
                " WHERE conversation_id = ? AND contact_at = ?",
                ((contact + WINDOW + TICK).isoformat(), conversation_id, contact.isoformat()),
            )

    async def _reach_out(self, current: CurrentConversation) -> None:
        conversation = current.conversation
        recording = self._activity.begin(
            "reach_out", conversation.user_id, conversation.character_id,
            own_llm=False, exempt=False,
        )
        lease = self._config.lease()
        try:
            with recording.current():
                said = await self._engine.reach_out(conversation, lease.keys.chat_llm)
        except Exception as e:
            # Not logged with what was raised: a service's error may repeat what it was asked.
            log.warning("reaching out in conversation %s failed: %s", conversation.id,
                        type(e).__name__)
            recording.finish("failed")
            assert current.last_contact is not None  # it was due
            await asyncio.to_thread(self._give_up, conversation.id, current.last_contact)
            return
        finally:
            lease.release()
        recording.finish("success")
        try:
            await asyncio.to_thread(
                self._store.add_reach_out, conversation.id, said, recording.row_id
            )
        except ConversationEnded:  # meanwhile
            pass
