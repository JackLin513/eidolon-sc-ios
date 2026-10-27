"""The mirror's files with the game's own asset server behind it (ADR-0032): what the
mirror cannot give is asked of the server, and what neither has is missing only when the
mirror said so."""

import json
import zlib
from collections.abc import AsyncIterator

import pytest

from eidolon import official_cdn
from eidolon.mirror import Mirror, MirrorError, Script
from tests.fakes import FakeShinyColorsDB

SCRIPT = "produce_events/200100401"
FRAMES = [{"id": 1, "speaker": "真乃", "text": "ほわ……"}]
STAND = "spine/idols/stand/1030010010/"
PNG = b"\x89PNG\r\n\x1a\n texture"


@pytest.fixture
def site() -> FakeShinyColorsDB:
    return FakeShinyColorsDB()


@pytest.fixture
async def mirror(site: FakeShinyColorsDB) -> AsyncIterator[Mirror]:
    mirror = site.mirror()
    yield mirror
    await mirror.aclose()


def test_a_file_is_asked_for_under_the_hash_of_its_path():
    # As the game's asset server answered for it.
    assert official_cdn.asset_url("json/produce_events/100100101.json") == (
        "https://shinycolors.enza.fun/assets/93bd5e2c42256659c85cb3139509080221ffbcf441f92b31ac0f6f955e268cc9"
    )


async def test_a_script_the_mirror_lacks_comes_from_the_server(site: FakeShinyColorsDB, mirror: Mirror):
    site.official.files[f"json/{SCRIPT}.json"] = json.dumps(FRAMES, ensure_ascii=False).encode()

    answer = await mirror.script(SCRIPT, None)

    assert isinstance(answer, Script)
    assert json.loads(answer.content) == FRAMES
    assert answer.etag is not None


async def test_a_script_neither_has_is_missing(mirror: Mirror):
    assert await mirror.script(SCRIPT, None) == "missing"


async def test_a_script_the_mirror_has_is_not_asked_of_the_server(site: FakeShinyColorsDB, mirror: Mirror):
    site.add_script(SCRIPT, FRAMES)
    site.official.files[f"json/{SCRIPT}.json"] = b"[]"

    answer = await mirror.script(SCRIPT, None)

    assert isinstance(answer, Script) and json.loads(answer.content) == FRAMES
    assert site.official.sent == []


async def test_a_script_comes_from_the_server_when_the_viewer_cannot_be_reached(
    site: FakeShinyColorsDB, mirror: Mirror
):
    site.viewer_down = True
    site.official.files[f"json/{SCRIPT}.json"] = json.dumps(FRAMES).encode()

    answer = await mirror.script(SCRIPT, None)

    assert isinstance(answer, Script) and json.loads(answer.content) == FRAMES
    # The server having sent one, its page for another is no maintenance page.
    assert await mirror.script("produce_events/200100402", None) == "missing"


async def test_a_server_with_no_such_script_while_the_viewer_cannot_be_reached_is_an_error(
    site: FakeShinyColorsDB, mirror: Mirror
):
    # The server may be down for maintenance, answering everything with its page: that is
    # no sign the script is not in the game.
    site.viewer_down = True
    site.official.files[f"json/{SCRIPT}.json"] = json.dumps(FRAMES).encode()
    site.official.maintenance = True

    with pytest.raises(MirrorError):
        await mirror.script(SCRIPT, None)


async def test_a_script_the_mirror_lacks_is_missing_when_the_server_fails(site: FakeShinyColorsDB, mirror: Mirror):
    # As before the server was asked: a sync goes on past it.
    site.official.down = True
    assert await mirror.script(SCRIPT, None) == "missing"

    site.official.down = False
    site.official.files[f"json/{SCRIPT}.json"] = b'{"not": "frames"}'
    assert await mirror.script(SCRIPT, None) == "missing"


async def test_when_both_cannot_be_reached_it_is_an_error(site: FakeShinyColorsDB, mirror: Mirror):
    site.viewer_down = True
    site.official.down = True

    with pytest.raises(MirrorError, match="官方 CDN"):
        await mirror.script(SCRIPT, None)


async def test_a_stand_file_the_cdn_lacks_comes_from_the_server_decrypted(site: FakeShinyColorsDB, mirror: Mirror):
    site.official.files[f"{STAND}data.atlas"] = b"\ndata.png\nsize: 2048,2048\n"
    site.official.files[f"{STAND}data.png"] = PNG

    assert await mirror.stand_file(f"{STAND}data.atlas") == b"\ndata.png\nsize: 2048,2048\n"
    assert await mirror.stand_file(f"{STAND}data.png") == PNG
    assert await mirror.stand_file(f"{STAND}data.json") is None


async def test_a_page_the_cdn_sends_for_a_stand_file_is_passed_over_for_the_servers_file(
    site: FakeShinyColorsDB, mirror: Mirror
):
    site.cdn_pages = True
    site.official.files[f"{STAND}data.png"] = PNG

    assert await mirror.stand_file(f"{STAND}data.png") == PNG


def test_a_file_from_the_server_cut_short_is_not_taken_for_whole():
    whole = b"\ndata.png\nsize: 2048,2048\n" * 50
    gzipper = zlib.compressobj(wbits=zlib.MAX_WBITS | 16)
    sent = official_cdn.xor(gzipper.compress(whole) + gzipper.flush(zlib.Z_SYNC_FLUSH))

    assert official_cdn.decode(f"{STAND}data.atlas", sent) == whole
    with pytest.raises(ValueError):
        official_cdn.decode(f"{STAND}data.atlas", sent[:-3])
