"""Her facts at the bar: those of her character facts a visit's topic finds, for her to talk
from instead of making things up (规格「她的资料」).

What the topic says is the query: embedded, her facts nearest it reranked, the best
`MAX_FACTS` kept, however relevant (the text turns' threshold is calibrated on what users say,
not on a topic). Only her facts are looked in, not the story; her reason for coming has no
part in it. The query never changes, so what it finds is kept for her and the topic while
the server runs; failing, she comes in without, and it is looked up again next time.
"""

import asyncio
import logging
from datetime import timedelta

from eidolon.bar_visits import Topic
from eidolon.characters import Character
from eidolon.embedding import Embedder
from eidolon.facts import CharacterFacts
from eidolon.rerank import Reranker
from eidolon.retrieval import CANDIDATES_PER_SOURCE

log = logging.getLogger(__name__)

MAX_FACTS = 3
"""How many of her facts a visit is told."""

LOOKUP_TIMEOUT = timedelta(seconds=15)
"""How long looking them up may hold her coming in: past it, she comes in without."""


class BarFacts:
    """Looks up her facts for a visit's topic, keeping what it finds."""

    def __init__(self, facts: CharacterFacts, embedder: Embedder, reranker: Reranker) -> None:
        self._facts = facts
        self._embedder = embedder
        self._reranker = reranker
        self._found: dict[tuple[str, str], list[str]] = {}
        """What was found for each character and topic, by their identifiers."""

    async def about(self, character: Character, topic: Topic) -> list[str]:
        """Her facts `topic` finds, best first; none if they cannot be looked up now."""
        key = (character.id, topic.id)
        if (found := self._found.get(key)) is not None:
            return found
        try:
            async with asyncio.timeout(LOOKUP_TIMEOUT.total_seconds()):
                found = await self._looked_up(character, topic.note)
        except Exception:
            log.warning("looking up her facts for a visit failed; she comes in without",
                        exc_info=True)
            return []
        self._found[key] = found
        return found

    async def _looked_up(self, character: Character, query: str) -> list[str]:
        vector = await self._embedder.embed_query(query)
        candidates = await self._facts.search(vector, character, CANDIDATES_PER_SOURCE)
        if not candidates:
            return []
        texts = [c.text for c in candidates]
        ranked = await self._reranker.rerank(query, texts, len(texts))
        return [texts[i] for i, _ in ranked[:MAX_FACTS]]
