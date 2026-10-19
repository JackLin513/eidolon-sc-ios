"""Sponsoring (GLOSSARY.md「赞赏」): the code the deployer sets in the admin console for users
to scan and sponsor the deployment with, kept in the database (`sponsor`) as photos are
(ADR-0024). Users are shown it only while it is switched on and a code is uploaded.

Its picture is kept as a PNG made anew from the upload's pixels, nothing else of it kept,
and no larger than `MAX_SIDE` on its longer side: lossless, so the code still scans."""

import io
import threading
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, UnidentifiedImageError

from eidolon.clock import Clock
from eidolon.database import connect

MAX_UPLOAD_BYTES = 2 * 1024 * 1024
"""The largest picture the admin may upload."""

MAX_SIDE = 1024
"""How many pixels its longer side has at most, kept; a larger one is scaled down."""

MAX_PIXELS = 40_000_000
"""The most pixels an upload may have, so that a small file cannot unpack into a huge one."""

_SCHEMA = """
-- The deployer's sponsor code: one row at most, `id` 1. `image` a PNG, NULL until uploaded;
-- `image_at` when it was, which tells browsers it is new.
CREATE TABLE IF NOT EXISTS sponsor (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    enabled INTEGER NOT NULL DEFAULT 0,
    image BLOB,
    image_at TEXT
);
"""


class NotAPicture(Exception):
    """The upload is not a picture PNG, JPEG or WebP, saying why."""


@dataclass(frozen=True)
class SponsorState:
    enabled: bool
    """Whether the admin switched it on."""
    image_at: str | None
    """When the code was uploaded, ISO 8601; None without one."""

    @property
    def shown(self) -> bool:
        """Whether users see it: switched on, with a code."""
        return self.enabled and self.image_at is not None


def kept_as_png(upload: bytes) -> bytes:
    """`upload` as the code is kept: a PNG of its pixels alone, scaled down to `MAX_SIDE`.
    Raises NotAPicture unless it is a PNG, JPEG or WebP of at most `MAX_PIXELS`."""
    try:
        with Image.open(io.BytesIO(upload), formats=("PNG", "JPEG", "WEBP")) as opened:
            width, height = opened.size
            if width * height > MAX_PIXELS:
                raise NotAPicture(f"{width}×{height} 太大")
            opened.load()
            mode = "RGBA" if "A" in opened.getbands() or "transparency" in opened.info else "RGB"
            pixels = opened.convert(mode)
    except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError) as e:
        raise NotAPicture(str(e)) from None
    # Made anew from its pixels alone, so nothing of what came with it is written.
    bare = Image.frombytes(mode, pixels.size, pixels.tobytes())
    bare.thumbnail((MAX_SIDE, MAX_SIDE), Image.Resampling.LANCZOS)
    out = io.BytesIO()
    bare.save(out, "PNG", optimize=True)
    return out.getvalue()


class Sponsor:
    def __init__(self, path: Path, clock: Clock) -> None:
        self._db = connect(path)
        self._lock = threading.Lock()
        with self._lock, self._db:
            self._db.executescript(_SCHEMA)
        self._clock = clock

    def state(self) -> SponsorState:
        with self._lock:
            row = self._db.execute("SELECT enabled, image_at FROM sponsor WHERE id = 1").fetchone()
        if row is None:
            return SponsorState(False, None)
        return SponsorState(bool(row[0]), row[1])

    def switch(self, enabled: bool) -> SponsorState:
        """Switch it on or off; switched on without a code, users see nothing yet."""
        with self._lock, self._db:
            self._db.execute(
                "INSERT INTO sponsor (id, enabled) VALUES (1, ?)"
                " ON CONFLICT (id) DO UPDATE SET enabled = excluded.enabled",
                (enabled,),
            )
        return self.state()

    def upload(self, upload: bytes) -> SponsorState:
        """Keep `upload` as the code, replacing the one there was; raises NotAPicture."""
        image = kept_as_png(upload)
        with self._lock, self._db:
            self._db.execute(
                "INSERT INTO sponsor (id, image, image_at) VALUES (1, ?, ?)"
                " ON CONFLICT (id) DO UPDATE SET image = excluded.image, image_at = excluded.image_at",
                (image, self._clock().isoformat()),
            )
        return self.state()

    def image(self) -> bytes | None:
        """The code, a PNG; None without one."""
        with self._lock:
            row = self._db.execute("SELECT image FROM sponsor WHERE id = 1").fetchone()
        return None if row is None else row[0]

    def clear(self) -> SponsorState:
        """Switch it off and delete the code."""
        with self._lock, self._db:
            self._db.execute("DELETE FROM sponsor")
        return self.state()

    def close(self) -> None:
        self._db.close()
