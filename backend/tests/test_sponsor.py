"""Sponsoring (GLOSSARY.md「赞赏」): admins upload a code and switch it on in the admin console;
users see it, its version from their account and the code at an address of that version, only
while it is both. The code is kept as a lossless PNG of its pixels alone, upright and opaque,
no larger than 1024 pixels a side."""

import io
from dataclasses import replace

import httpx
import pytest
from PIL import Image

from eidolon.config import Settings
from tests.conftest import ClientFactory
from tests.fakes import FakeClock, FakeIdentityProvider, FakeLLM
from tests.test_admin_users import ADMIN, admin_client


@pytest.fixture
def settings(settings: Settings) -> Settings:
    return replace(settings, admins=frozenset({ADMIN}))


def picture(size: tuple[int, int], format: str = "PNG", **saved) -> bytes:
    """A picture of `size`, black and white squares as a code is."""
    image = Image.new("RGB", size, "white")
    for x in range(0, size[0], 8):
        for y in range(0, size[1], 8):
            if (x // 8 + y // 8) % 2:
                image.putpixel((x, y), (0, 0, 0))
    out = io.BytesIO()
    image.save(out, format, **saved)
    return out.getvalue()


async def upload(admin: httpx.AsyncClient, body: bytes) -> httpx.Response:
    return await admin.put(
        "/api/admin/sponsor/image", content=body, headers={"Content-Type": "application/octet-stream"}
    )


async def switch(admin: httpx.AsyncClient, enabled: bool) -> dict:
    res = await admin.put("/api/admin/sponsor", json={"enabled": enabled})
    assert res.status_code == 200, res.text
    return res.json()


async def shown(user: httpx.AsyncClient) -> str | None:
    res = await user.get("/api/account")
    assert res.status_code == 200, res.text
    return res.json()["sponsor_version"]


async def test_users_see_the_code_once_it_is_uploaded_and_switched_on(
    make_client: ClientFactory, github: FakeIdentityProvider
):
    clock = FakeClock()
    admin = await admin_client(make_client, github, clock=clock)
    user = make_client(FakeLLM(), clock=clock)
    assert (await admin.get("/api/admin/sponsor")).json() == {"enabled": False, "image_at": None}
    assert await shown(user) is None

    uploaded = await upload(admin, picture((300, 300)))
    assert uploaded.status_code == 200, uploaded.text
    assert uploaded.json() == {"enabled": False, "image_at": clock().isoformat()}
    assert await shown(user) is None
    assert (await user.get("/api/sponsor/image")).status_code == 404

    assert await switch(admin, True) == {"enabled": True, "image_at": clock().isoformat()}

    assert await shown(user) == clock().isoformat()
    res = await user.get("/api/sponsor/image", params={"v": clock().isoformat()})
    assert res.status_code == 200
    assert res.headers["content-type"] == "image/png"
    assert res.headers["cache-control"] == "private, max-age=31536000, immutable"
    assert Image.open(io.BytesIO(res.content)).size == (300, 300)


async def test_a_version_since_replaced_is_given_the_new_code_not_to_keep(
    make_client: ClientFactory, github: FakeIdentityProvider
):
    clock = FakeClock()
    admin = await admin_client(make_client, github, clock=clock)
    user = make_client(FakeLLM(), clock=clock)
    await upload(admin, picture((100, 100)))
    await switch(admin, True)
    old = await shown(user)
    clock.advance(minutes=5)
    await upload(admin, picture((200, 200)))

    res = await user.get("/api/sponsor/image", params={"v": old})

    assert res.headers["cache-control"] == "no-store"
    assert Image.open(io.BytesIO(res.content)).size == (200, 200)


async def test_switched_on_without_a_code_users_see_nothing(
    make_client: ClientFactory, github: FakeIdentityProvider
):
    admin = await admin_client(make_client, github)
    user = make_client(FakeLLM())

    await switch(admin, True)

    assert await shown(user) is None
    assert (await user.get("/api/sponsor/image")).status_code == 404


async def test_switched_off_users_no_longer_see_it_but_admins_still_preview_it(
    make_client: ClientFactory, github: FakeIdentityProvider
):
    admin = await admin_client(make_client, github)
    user = make_client(FakeLLM())
    await upload(admin, picture((100, 100)))
    await switch(admin, True)

    await switch(admin, False)

    assert await shown(user) is None
    assert (await user.get("/api/sponsor/image")).status_code == 404
    assert (await admin.get("/api/admin/sponsor/image")).status_code == 200


async def test_a_new_code_replaces_the_old_and_is_read_at_a_new_address(
    make_client: ClientFactory, github: FakeIdentityProvider
):
    clock = FakeClock()
    admin = await admin_client(make_client, github, clock=clock)
    user = make_client(FakeLLM(), clock=clock)
    await upload(admin, picture((100, 100)))
    await switch(admin, True)
    first = await shown(user)
    clock.advance(minutes=5)

    await upload(admin, picture((200, 200)))

    assert await shown(user) == clock().isoformat() != first
    res = await user.get("/api/sponsor/image")
    assert Image.open(io.BytesIO(res.content)).size == (200, 200)


async def test_clearing_switches_it_off_and_deletes_the_code(
    make_client: ClientFactory, github: FakeIdentityProvider
):
    admin = await admin_client(make_client, github)
    user = make_client(FakeLLM())
    await upload(admin, picture((100, 100)))
    await switch(admin, True)

    res = await admin.delete("/api/admin/sponsor")

    assert res.status_code == 200, res.text
    assert res.json() == {"enabled": False, "image_at": None}
    assert await shown(user) is None
    assert (await admin.get("/api/admin/sponsor/image")).status_code == 404


async def test_the_code_is_kept_lossless_scaled_down_and_without_its_metadata(
    make_client: ClientFactory, github: FakeIdentityProvider
):
    admin = await admin_client(make_client, github)
    exif = Image.Exif()
    exif[0x010F] = "某品牌手机"  # Make
    await upload(admin, picture((64, 64), "JPEG", quality=95, exif=exif.tobytes()))

    kept = Image.open(io.BytesIO((await admin.get("/api/admin/sponsor/image")).content))

    assert kept.format == "PNG"
    assert not kept.getexif()

    sent = picture((64, 64), "WEBP", lossless=True)
    await upload(admin, sent)
    kept = Image.open(io.BytesIO((await admin.get("/api/admin/sponsor/image")).content))
    assert kept.convert("RGB").tobytes() == Image.open(io.BytesIO(sent)).convert("RGB").tobytes()

    await upload(admin, picture((3000, 1500)))
    kept = Image.open(io.BytesIO((await admin.get("/api/admin/sponsor/image")).content))
    assert kept.size == (1024, 512)


async def test_the_code_is_kept_upright_and_on_white(
    make_client: ClientFactory, github: FakeIdentityProvider
):
    """A photo of a code is turned as the camera said; a transparent code is put on white,
    or it would vanish on the dark viewer."""
    admin = await admin_client(make_client, github)
    sideways = Image.Exif()
    sideways[0x0112] = 6  # Orientation: turned 90° clockwise to view
    await upload(admin, picture((200, 100), "JPEG", exif=sideways.tobytes()))

    kept = Image.open(io.BytesIO((await admin.get("/api/admin/sponsor/image")).content))

    assert kept.size == (100, 200)

    transparent = Image.new("RGBA", (10, 10), (0, 0, 0, 0))
    transparent.putpixel((0, 0), (0, 0, 0, 255))
    out = io.BytesIO()
    transparent.save(out, "PNG")
    await upload(admin, out.getvalue())
    kept = Image.open(io.BytesIO((await admin.get("/api/admin/sponsor/image")).content))
    assert kept.mode == "RGB"
    assert kept.getpixel((5, 5)) == (255, 255, 255)
    assert kept.getpixel((0, 0)) == (0, 0, 0)


async def test_what_is_not_a_png_jpeg_or_webp_or_too_large_is_refused_keeping_the_code(
    make_client: ClientFactory, github: FakeIdentityProvider
):
    admin = await admin_client(make_client, github)
    first = (await upload(admin, picture((100, 100)))).json()

    gif = await upload(admin, picture((100, 100), "GIF"))
    too_large = await upload(admin, b"\0" * (2 * 1024 * 1024 + 1))

    assert gif.status_code == 422
    assert too_large.status_code == 413
    assert (await admin.get("/api/admin/sponsor")).json() == first


async def test_only_admins_set_it(make_client: ClientFactory, github: FakeIdentityProvider):
    user = make_client(FakeLLM())

    assert (await user.get("/api/admin/sponsor")).status_code == 404
    assert (await user.put("/api/admin/sponsor", json={"enabled": True})).status_code == 404
    assert (await upload(user, picture((100, 100)))).status_code == 404
    assert (await user.delete("/api/admin/sponsor")).status_code == 404
    assert (await user.get("/api/admin/sponsor/image")).status_code == 404
