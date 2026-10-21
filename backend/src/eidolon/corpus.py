"""The story corpus: episodes the characters can recall, and their vector index.

Each episode is keyed by its source identifier (the game script it came from), so
saving the same episode again replaces it. Each episode also records the format it was
imported from, so an import can leave alone a better version from another. Episodes
are split into passages of consecutive lines; each passage is embedded and searched
by cosine similarity, only among the episodes the asking character is in the cast of. Passages whose
text has not changed keep their vectors, so re-importing costs no embedding calls.
An episode with no cast is kept but not embedded: no character could recall it.

Each passage keeps one vector, from the embedding model it was last embedded with;
only passages embedded with the current model are searched. After the model changes,
`embed_missing` re-embeds the rest from their stored text (`eidolon reembed`).

The story catalog is read from the same tables: each character's episodes, grouped
by the card or event they belong to, so it is always in step with the last import.

Everything lives in the same SQLite file as the rest of the relational data, which
stays out of the repository (ADR-0003), read and written through the data access layer.
"""

import asyncio
import sqlite3
import typing
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Literal

from eidolon.data_access import Database
from eidolon.embedding import Document, Embedder, nearest, to_blob

_SCHEMA = """
CREATE TABLE IF NOT EXISTS episodes (
    id TEXT PRIMARY KEY,
    category TEXT NOT NULL,
    source TEXT NOT NULL,
    title TEXT NOT NULL,
    imported_from TEXT NOT NULL DEFAULT 'csv',
    imported_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS episode_cast (
    episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
    character_id TEXT NOT NULL,
    PRIMARY KEY (episode_id, character_id)
);
CREATE INDEX IF NOT EXISTS episode_cast_by_character ON episode_cast(character_id);
CREATE TABLE IF NOT EXISTS episode_lines (
    episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
    seq INTEGER NOT NULL,
    speaker TEXT,
    ja TEXT NOT NULL,
    zh TEXT,
    PRIMARY KEY (episode_id, seq)
);
CREATE TABLE IF NOT EXISTS episode_passages (
    episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
    seq INTEGER NOT NULL,
    text TEXT NOT NULL,
    model TEXT NOT NULL,
    embedding BLOB NOT NULL,
    PRIMARY KEY (episode_id, seq)
);
"""

_PASSAGE_CHARS = 1200
"""Roughly how much text goes into one passage before a new one starts."""
REEMBED_BATCH = 200
"""How many passages (or memories) `eidolon reembed` embeds before committing them."""


ImportFormat = Literal["csv", "json"]
"""`csv` for SCTranslationData, `json` for the game's own scripts."""


@dataclass(frozen=True)
class Line:
    """One line of dialogue; `speaker` is None for narration."""

    speaker: str | None
    ja: str
    zh: str | None = None


@dataclass(frozen=True)
class Episode:
    id: str
    """The source identifier, e.g. `produce_events/100100101`."""
    category: str
    source: str
    """The card or event the episode belongs to."""
    title: str
    cast: frozenset[str]
    """Identifiers of the configured characters who appear in it."""
    lines: tuple[Line, ...]
    imported_from: ImportFormat = "csv"

    @property
    def translated(self) -> bool:
        """Whether it is SCTranslationData's translation, not just the untranslated
        script."""
        return self.imported_from == "csv"


@dataclass(frozen=True)
class CatalogEntry:
    """One episode in the story catalog."""

    episode_id: str
    title: str


@dataclass(frozen=True)
class CatalogSource:
    """A card or event in the story catalog, with the episodes one character is cast in."""

    category: str
    source: str
    episodes: tuple[CatalogEntry, ...]


@dataclass(frozen=True)
class Passage:
    episode: Episode
    text: str
    score: float


class StoryCorpus:
    def __init__(self, db: Database, embedder: Embedder) -> None:
        """Its tables made, or brought up to date, as it is opened."""
        self._db = db
        self._embedder = embedder
        self.missing_vectors_at_open: int = db.prepare(_open, embedder.model)
        """How many passages had no vector from this corpus's embedder as it was opened,
        and so cannot be found: those embedded before the embedding service, model or
        dimensions changed."""

    async def save(self, episodes: list[Episode]) -> int:
        """Insert or replace these episodes; returns how many passages had to be embedded."""
        passages = {e.id: _passages(e) if e.cast else [] for e in episodes}
        titles = {t: passage_title(e.source, e.title) for e in episodes for t in passages[e.id]}
        model = self._embedder.model
        known = await self._db.read(_known_vectors, list(passages), model)
        missing = sorted(titles.keys() - known.keys())
        if missing:
            vectors = await self._embedder.embed_documents(
                [Document(t, titles[t]) for t in missing]
            )
            known.update(zip(missing, (to_blob(v) for v in vectors), strict=True))
        now = datetime.now(UTC).isoformat()
        await self._db.write(_save, episodes, passages, model, known, now)
        return len(missing)

    async def remove(self, episode_id: str) -> bool:
        """Remove an episode if present; returns whether it was."""
        return await self._db.write(_delete, episode_id)

    async def get(self, episode_id: str) -> Episode | None:
        return await self._db.read(_get, episode_id)

    async def episodes(self, episode_ids: Iterable[str]) -> list[Episode]:
        """The episodes of `episode_ids` still in the corpus, in that order."""
        return await self._db.read(_episodes, list(episode_ids))

    async def imported_from(self, episode_id: str) -> ImportFormat | None:
        """The format an episode was imported from, or None if it is not in the corpus."""
        return await self._db.read(_imported_from, episode_id)

    async def is_translated(self, episode_id: str) -> bool:
        """Whether the corpus has the episode's translation (from SCTranslationData), not
        just its untranslated script."""
        return await self.imported_from(episode_id) == "csv"

    async def episode_ids(self, prefix: str = "") -> list[str]:
        """The identifiers of the episodes whose identifier starts with `prefix`, in order."""
        return await self._db.read(_episode_ids, prefix)

    async def list_episodes(self, character_id: str | None = None) -> list[Episode]:
        """All episodes, or those `character_id` appears in, ordered by source identifier."""
        return await self._db.read(_list_episodes, character_id)

    async def catalog(self, character_id: str) -> list[CatalogSource]:
        """The story catalog for one character: character → card or event → episode.

        Cards and events come in the order of their first episode, episodes in
        source identifier order, which is the order the game numbers them in.
        """
        return await self._db.read(_catalog, character_id)

    async def search(self, query: str, character_id: str, limit: int = 5) -> list[Passage]:
        """The passages most similar to `query`, from episodes `character_id` appears in."""
        return await self.search_by_vector(
            await self._embedder.embed_query(query), character_id, limit
        )

    async def search_by_vector(
        self, query_vector: Sequence[float], character_id: str, limit: int = 5
    ) -> list[Passage]:
        """Like `search`, for a query already embedded with this corpus's embedder."""
        rows = await self._db.read(_passages_of_cast, character_id, self._embedder.model)
        best = await asyncio.to_thread(nearest, [r["embedding"] for r in rows], query_vector, limit)
        found = await self.episodes(dict.fromkeys(rows[i]["episode_id"] for i, _ in best))
        episodes = {e.id: e for e in found}
        return [
            Passage(episodes[rows[i]["episode_id"]], rows[i]["text"], score)
            for i, score in best
            if rows[i]["episode_id"] in episodes  # unless removed since
        ]

    async def embed_missing(
        self, batch: int = REEMBED_BATCH, progress: Callable[[int], None] | None = None
    ) -> int:
        """Re-embed, from their stored text, the passages that have no vector from this
        corpus's embedder, replacing their old vectors (a passage keeps only one), `batch`
        at a time; returns how many it embedded, telling `progress` the count so far after
        each batch. Interrupted, what it finished is kept. A passage an import rewrites
        meanwhile is left to the import, and not counted."""
        model = self._embedder.model
        done = 0
        after = ("", -1)
        while True:
            rows = await self._db.read(_unembedded, model, after, batch)
            if not rows:
                return done
            vectors = await self._embedder.embed_documents(
                [Document(r["text"], passage_title(r["source"], r["title"])) for r in rows]
            )
            done += await self._db.write(
                _reembed,
                [
                    (model, to_blob(v), r["episode_id"], r["seq"], r["text"])
                    for r, v in zip(rows, vectors, strict=True)
                ],
            )
            after = (rows[-1]["episode_id"], rows[-1]["seq"])
            if progress is not None:
                progress(done)


def _by_name(db: sqlite3.Connection) -> sqlite3.Cursor:
    """A cursor on `db` whose rows are read by name, leaving the connection's, which other
    modules share, as they are."""
    cursor = db.cursor()
    cursor.row_factory = sqlite3.Row
    return cursor


def _open(db: sqlite3.Connection, model: str) -> int:
    """Make the tables, or bring them up to date; how many passages have no vector from
    `model`."""
    db.executescript(_SCHEMA)
    columns = {r["name"] for r in _by_name(db).execute("PRAGMA table_info(episodes)")}
    if "imported_from" not in columns:  # corpora from before JSON import were all CSV
        db.execute("ALTER TABLE episodes ADD COLUMN imported_from TEXT NOT NULL DEFAULT 'csv'")
    return db.execute(
        "SELECT count(*) FROM episode_passages WHERE model != ?", (model,)
    ).fetchone()[0]


def _save(
    db: sqlite3.Connection,
    episodes: list[Episode],
    passages: dict[str, list[str]],
    model: str,
    known: dict[str, bytes],
    now: str,
) -> None:
    for episode in episodes:
        _delete(db, episode.id)
        db.execute(
            "INSERT INTO episodes (id, category, source, title, imported_from, imported_at)"
            " VALUES (?, ?, ?, ?, ?, ?)",
            (
                episode.id,
                episode.category,
                episode.source,
                episode.title,
                episode.imported_from,
                now,
            ),
        )
        db.executemany(
            "INSERT INTO episode_cast (episode_id, character_id) VALUES (?, ?)",
            [(episode.id, c) for c in sorted(episode.cast)],
        )
        db.executemany(
            "INSERT INTO episode_lines (episode_id, seq, speaker, ja, zh)"
            " VALUES (?, ?, ?, ?, ?)",
            [(episode.id, i, line.speaker, line.ja, line.zh) for i, line in enumerate(episode.lines)],
        )
        db.executemany(
            "INSERT INTO episode_passages (episode_id, seq, text, model, embedding)"
            " VALUES (?, ?, ?, ?, ?)",
            [
                (episode.id, i, text, model, known[text])
                for i, text in enumerate(passages[episode.id])
            ],
        )


def _get(db: sqlite3.Connection, episode_id: str) -> Episode | None:
    row = _by_name(db).execute("SELECT * FROM episodes WHERE id = ?", (episode_id,)).fetchone()
    return _episode(db, row) if row else None


def _episodes(db: sqlite3.Connection, episode_ids: list[str]) -> list[Episode]:
    return [e for id in episode_ids if (e := _get(db, id)) is not None]


def _imported_from(db: sqlite3.Connection, episode_id: str) -> ImportFormat | None:
    row = db.execute("SELECT imported_from FROM episodes WHERE id = ?", (episode_id,)).fetchone()
    return typing.cast(ImportFormat, row[0]) if row else None


def _episode_ids(db: sqlite3.Connection, prefix: str) -> list[str]:
    rows = db.execute(
        "SELECT id FROM episodes WHERE substr(id, 1, ?) = ? ORDER BY id",
        (len(prefix), prefix),
    ).fetchall()
    return [id for (id,) in rows]


def _list_episodes(db: sqlite3.Connection, character_id: str | None) -> list[Episode]:
    if character_id is None:
        rows = _by_name(db).execute("SELECT * FROM episodes ORDER BY id").fetchall()
    else:
        rows = _by_name(db).execute(
            "SELECT e.* FROM episodes e JOIN episode_cast c ON c.episode_id = e.id"
            " WHERE c.character_id = ? ORDER BY e.id",
            (character_id,),
        ).fetchall()
    return [_episode(db, row) for row in rows]


def _catalog(db: sqlite3.Connection, character_id: str) -> list[CatalogSource]:
    rows = db.execute(
        "SELECT e.id, e.category, e.source, e.title FROM episodes e"
        " JOIN episode_cast c ON c.episode_id = e.id"
        " WHERE c.character_id = ? ORDER BY e.id",
        (character_id,),
    ).fetchall()
    sources: dict[tuple[str, str], list[CatalogEntry]] = {}
    for id, category, source, title in rows:
        sources.setdefault((category, source), []).append(CatalogEntry(id, title))
    return [
        CatalogSource(category, source, tuple(entries))
        for (category, source), entries in sources.items()
    ]


def _passages_of_cast(
    db: sqlite3.Connection, character_id: str, model: str
) -> list[sqlite3.Row]:
    """The episode, text and vector from `model` of each passage of the episodes
    `character_id` is cast in."""
    return _by_name(db).execute(
        "SELECT p.episode_id, p.text, p.embedding FROM episode_passages p"
        " JOIN episode_cast c ON c.episode_id = p.episode_id"
        " WHERE c.character_id = ? AND p.model = ?",
        (character_id, model),
    ).fetchall()


def _unembedded(
    db: sqlite3.Connection, model: str, after: tuple[str, int], batch: int
) -> list[sqlite3.Row]:
    """As many as `batch` passages without a vector from `model`, after `after` (an
    episode, and a passage's place in it), with where each comes from."""
    return _by_name(db).execute(
        "SELECT p.episode_id, p.seq, p.text, e.source, e.title"
        " FROM episode_passages p JOIN episodes e ON e.id = p.episode_id"
        " WHERE p.model != ? AND (p.episode_id, p.seq) > (?, ?)"
        " ORDER BY p.episode_id, p.seq LIMIT ?",
        (model, *after, batch),
    ).fetchall()


def _reembed(db: sqlite3.Connection, rows: list[tuple[str, bytes, str, int, str]]) -> int:
    """Each passage's new model and vector, unless an import rewrote its text since; how
    many were."""
    return db.executemany(
        "UPDATE episode_passages SET model = ?, embedding = ?"
        " WHERE episode_id = ? AND seq = ? AND text = ?",
        rows,
    ).rowcount


def _known_vectors(
    db: sqlite3.Connection, episode_ids: list[str], model: str
) -> dict[str, bytes]:
    """Vectors already stored for these episodes' passages, by passage text."""
    known = {}
    for episode_id in episode_ids:
        for text, embedding in db.execute(
            "SELECT text, embedding FROM episode_passages"
            " WHERE episode_id = ? AND model = ?",
            (episode_id, model),
        ):
            known[text] = embedding
    return known


def _delete(db: sqlite3.Connection, episode_id: str) -> bool:
    """Its cast, lines and passages go with it (ON DELETE CASCADE)."""
    return db.execute("DELETE FROM episodes WHERE id = ?", (episode_id,)).rowcount > 0


def _episode(db: sqlite3.Connection, row: sqlite3.Row) -> Episode:
    episode_id = row["id"]
    cast = db.execute(
        "SELECT character_id FROM episode_cast WHERE episode_id = ?", (episode_id,)
    ).fetchall()
    lines = db.execute(
        "SELECT speaker, ja, zh FROM episode_lines WHERE episode_id = ? ORDER BY seq",
        (episode_id,),
    ).fetchall()
    return Episode(
        id=episode_id,
        category=row["category"],
        source=row["source"],
        title=row["title"],
        cast=frozenset(character_id for (character_id,) in cast),
        lines=tuple(Line(speaker, ja, zh) for speaker, ja, zh in lines),
        imported_from=typing.cast(ImportFormat, row["imported_from"]),
    )


def passage_title(source: str, title: str) -> str:
    """Where a passage comes from: its episode's card or event, and the episode's title."""
    return f"{source}「{title}」"


def _passages(episode: Episode) -> list[str]:
    """Consecutive lines grouped into passages, each headed by where it comes from."""
    header = passage_title(episode.source, episode.title) + "\n"
    passages: list[str] = []
    current: list[str] = []
    size = 0
    for line in episode.lines:
        text = f"{line.speaker}：{line.ja}" if line.speaker else line.ja
        if line.zh:
            text += f"（{line.zh}）"
        if current and size + len(text) > _PASSAGE_CHARS:
            passages.append(header + "\n".join(current))
            current, size = [], 0
        current.append(text)
        size += len(text)
    if current:
        passages.append(header + "\n".join(current))
    return passages

