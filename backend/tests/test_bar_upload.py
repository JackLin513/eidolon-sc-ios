"""Uploading the original game's tracks and sound effects to the stands' bucket
(`eidolon bar upload`): what the list in the repository names, from the deployer's
extracted `audio/`, under `bar/`, and last the manifest of what the bucket has. Checked
against the fake bucket of the stands' upload."""

import json
from pathlib import Path

import pytest

from eidolon.bar_upload import BarAudio, bar_audio_path, load_bar_audio, upload_bar_audio
from tests.conftest import Admin
from tests.test_stand_upload import FakeBucket

REPOSITORY_LIST = Path(__file__).parents[2] / "characters" / "bar_audio.json"


def write_list(path: Path) -> Path:
    path.write_text(
        json.dumps({
            "tracks": [
                {"id": 22, "file": "022_every_day_is_night.ogg", "title": "Every Day is Night"},
                {"id": 21, "file": "021_dusk.ogg", "title": "Dusk"},
            ],
            "default_playlist": [22, 21],
            "sfx": [
                {"name": "door", "file": "095_door.ogg"},
                {"name": "bleep_high", "file": "083_bleep_high.ogg"},
            ],
        }),
        encoding="utf-8",
    )
    return path


@pytest.fixture
def catalog(tmp_path: Path) -> BarAudio:
    return load_bar_audio(write_list(tmp_path / "bar_audio.json"))


@pytest.fixture
def audio_dir(tmp_path: Path) -> Path:
    """The extracted `audio/`, with every file the list names and one it does not."""
    directory = tmp_path / "audio"
    directory.mkdir()
    for name in ("022_every_day_is_night.ogg", "021_dusk.ogg", "095_door.ogg", "083_bleep_high.ogg", "007_ambient_sound.ogg"):
        (directory / name).write_bytes(f"ogg {name}".encode())
    return directory


@pytest.fixture
def storage() -> FakeBucket:
    return FakeBucket()


async def upload(audio_dir: Path, catalog: BarAudio, storage: FakeBucket):
    bucket = storage.bucket()
    try:
        return await upload_bar_audio(audio_dir, catalog, bucket)
    finally:
        await bucket.aclose()


def manifest(storage: FakeBucket) -> dict:
    return json.loads(storage.objects["bar/manifest.json"][0])


async def test_uploads_the_tracks_and_sound_effects_the_list_names_and_the_manifest_last(
    audio_dir: Path, catalog: BarAudio, storage: FakeBucket
):
    report = await upload(audio_dir, catalog, storage)

    assert sorted(storage.objects) == [
        "bar/manifest.json",
        "bar/music/21.ogg",
        "bar/music/22.ogg",
        "bar/sfx/bleep_high.ogg",
        "bar/sfx/door.ogg",
    ]
    assert storage.objects["bar/music/22.ogg"][0] == b"ogg 022_every_day_is_night.ogg"
    assert storage.objects["bar/sfx/door.ogg"][0] == b"ogg 095_door.ogg"
    assert storage.puts[-1] == "bar/manifest.json"
    assert manifest(storage) == {"tracks": [22, 21], "sfx": ["door", "bleep_high"]}
    assert report.uploaded == 4
    assert report.missing == []

    # The audio is cached for good; the manifest is checked every time.
    def headers(key: str) -> tuple[str, str]:
        sent = storage.objects[key][1]
        return sent["content-type"], sent["cache-control"]

    assert headers("bar/music/22.ogg") == ("audio/ogg", "public, max-age=31536000, immutable")
    assert headers("bar/sfx/door.ogg") == ("audio/ogg", "public, max-age=31536000, immutable")
    assert headers("bar/manifest.json") == ("application/json", "no-cache")


async def test_what_the_bucket_has_as_it_is_is_not_uploaded_again(
    audio_dir: Path, catalog: BarAudio, storage: FakeBucket
):
    await upload(audio_dir, catalog, storage)
    storage.puts.clear()
    (audio_dir / "021_dusk.ogg").write_bytes(b"dusk, extracted again")

    report = await upload(audio_dir, catalog, storage)

    assert storage.puts == ["bar/music/21.ogg", "bar/manifest.json"]
    assert storage.objects["bar/music/21.ogg"][0] == b"dusk, extracted again"
    assert report.uploaded == 1
    assert report.unchanged == 3


async def test_a_missing_file_is_reported_and_the_rest_uploaded_and_listed(
    audio_dir: Path, catalog: BarAudio, storage: FakeBucket
):
    (audio_dir / "021_dusk.ogg").unlink()
    (audio_dir / "095_door.ogg").unlink()

    report = await upload(audio_dir, catalog, storage)

    assert report.missing == ["021_dusk.ogg", "095_door.ogg"]
    assert sorted(storage.objects) == ["bar/manifest.json", "bar/music/22.ogg", "bar/sfx/bleep_high.ogg"]
    assert manifest(storage) == {"tracks": [22], "sfx": ["bleep_high"]}


async def test_the_manifest_lists_what_the_bucket_already_has_though_missing_here(
    audio_dir: Path, catalog: BarAudio, storage: FakeBucket
):
    await upload(audio_dir, catalog, storage)
    (audio_dir / "021_dusk.ogg").unlink()

    report = await upload(audio_dir, catalog, storage)

    assert report.missing == ["021_dusk.ogg"]
    assert manifest(storage) == {"tracks": [22, 21], "sfx": ["door", "bleep_high"]}


async def test_a_bucket_that_fails_writes_no_manifest(audio_dir: Path, catalog: BarAudio, storage: FakeBucket):
    from eidolon.s3 import S3Error

    storage.down = True

    with pytest.raises(S3Error, match="503"):
        await upload(audio_dir, catalog, storage)
    assert "bar/manifest.json" not in storage.objects


def test_the_list_is_the_one_beside_the_character_configuration():
    assert bar_audio_path(REPOSITORY_LIST.parent / "characters.toml") == REPOSITORY_LIST
    load_bar_audio(REPOSITORY_LIST)


def test_a_broken_list_is_an_error(tmp_path: Path):
    path = tmp_path / "bar_audio.json"
    path.write_text('{"tracks": [{"id": 22}]}', encoding="utf-8")

    with pytest.raises(RuntimeError, match="bar_audio.json"):
        load_bar_audio(path)
    with pytest.raises(RuntimeError, match="bar_audio.json"):
        load_bar_audio(tmp_path / "missing" / "bar_audio.json")


def test_the_command_needs_the_extracted_audio_directory(
    admin: Admin, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    for name, value in {
        "ENDPOINT": "http://storage.test",
        "BUCKET": "stands",
        "ACCESS_KEY_ID": "key-id",
        "SECRET_ACCESS_KEY": "secret",
    }.items():
        monkeypatch.setenv(f"EIDOLON_STAND_S3_{name}", value)
    write_list(tmp_path / "bar_audio.json")

    code, _, err = admin.invoke(
        "bar", "upload", str(tmp_path / "VA11_extract" / "audio"), "--characters", str(tmp_path / "characters.toml")
    )

    assert code == 1
    assert "VA11_extract" in err
