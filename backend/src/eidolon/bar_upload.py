"""Uploading the bar's music and sound effects to the bucket browsers download them from:
`eidolon bar upload`.

They are the original game's Ogg files, which may not go in the repository: what goes up
is what the list beside the character configuration (`bar_audio.json`, which the
frontend reads too) names, from the deployer's own extraction of the game's `audio/`.
Each track goes up as `bar/music/<id>.ogg`, each sound effect as `bar/sfx/<name>.ogg`,
and last `bar/manifest.json`, naming the tracks and sound effects the bucket has, so
that a browser never reads one that names a file not uploaded yet. A file missing from
the extraction is reported and the rest uploaded; the manifest still names it if the
bucket has it from before.

An object the bucket already has as it is (its ETag is the file's MD5) is not uploaded
again. The audio is cached for good; the manifest is checked every time. Emptying the
`bar/` prefix takes the audio down, and the bar plays on in silence.
"""

import asyncio
import hashlib
import json
from dataclasses import dataclass, field
from pathlib import Path

from eidolon.s3 import Bucket

BAR_AUDIO_FILE = "bar_audio.json"
PREFIX = "bar/"
MANIFEST_KEY = f"{PREFIX}manifest.json"
AUDIO_CACHE = "public, max-age=31536000, immutable"
MANIFEST_CACHE = "no-cache"
_CONCURRENT_UPLOADS = 8


@dataclass(frozen=True)
class Track:
    id: int
    file: str
    title: str


@dataclass(frozen=True)
class SoundEffect:
    name: str
    file: str


@dataclass(frozen=True)
class BarAudio:
    """The list of the jukebox's tracks, in the original's order, and the sound effects."""

    tracks: list[Track]
    sfx: list[SoundEffect]


def bar_audio_path(characters_path: Path) -> Path:
    """Where the list is: beside the character configuration."""
    return characters_path.parent / BAR_AUDIO_FILE


def load_bar_audio(path: Path) -> BarAudio:
    """The list at `path`. Raises RuntimeError if it is missing or broken."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        tracks = [Track(int(t["id"]), str(t["file"]), str(t["title"])) for t in data["tracks"]]
        sfx = [SoundEffect(str(s["name"]), str(s["file"])) for s in data["sfx"]]
    except FileNotFoundError:
        raise RuntimeError(f"找不到曲目表和音效清单 {path}") from None
    except (json.JSONDecodeError, UnicodeDecodeError, KeyError, TypeError, ValueError) as e:
        raise RuntimeError(f"曲目表和音效清单 {path} 格式有误（{e!r}）") from None
    return BarAudio(tracks, sfx)


def track_key(track: Track) -> str:
    return f"{PREFIX}music/{track.id}.ogg"


def sfx_key(sfx: SoundEffect) -> str:
    return f"{PREFIX}sfx/{sfx.name}.ogg"


@dataclass
class BarUploadReport:
    uploaded: int = 0
    uploaded_bytes: int = 0
    unchanged: int = 0
    missing: list[str] = field(default_factory=list)
    """Files the list names that the extraction lacks, so were not uploaded."""


async def upload_bar_audio(audio_dir: Path, catalog: BarAudio, bucket: Bucket) -> BarUploadReport:
    """Upload what `catalog` names, from `audio_dir`, to `bucket`, and then the manifest.
    Raises S3Error if the bucket fails, having uploaded what it could before but not the
    manifest; running it again picks up from there."""
    report = BarUploadReport()
    files = [(track_key(t), audio_dir / t.file) for t in catalog.tracks] + [
        (sfx_key(s), audio_dir / s.file) for s in catalog.sfx
    ]
    etags = await bucket.etags(PREFIX)
    in_bucket = set(etags)
    slots = asyncio.Semaphore(_CONCURRENT_UPLOADS)

    async def upload(key: str, path: Path) -> None:
        async with slots:  # also so that only a few files are read into memory at once
            try:
                body = path.read_bytes()
            except FileNotFoundError:
                report.missing.append(path.name)
                return
            if etags.get(key) == hashlib.md5(body).hexdigest():
                report.unchanged += 1
                return
            await bucket.put(key, body, "audio/ogg", AUDIO_CACHE)
        in_bucket.add(key)
        report.uploaded += 1
        report.uploaded_bytes += len(body)

    try:
        async with asyncio.TaskGroup() as uploads:  # one failing stops the rest
            for key, path in files:
                uploads.create_task(upload(key, path))
    except ExceptionGroup as failed:
        raise failed.exceptions[0] from None
    report.missing.sort(key=[path.name for _, path in files].index)

    manifest = {
        "tracks": [t.id for t in catalog.tracks if track_key(t) in in_bucket],
        "sfx": [s.name for s in catalog.sfx if sfx_key(s) in in_bucket],
    }
    await bucket.put(MANIFEST_KEY, json.dumps(manifest).encode(), "application/json", MANIFEST_CACHE)
    return report
