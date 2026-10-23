"""Reset cards granted in the admin console (GLOSSARY.md「重置卡」): an admin gives every user
there is a reset card at once, banned ones and admins too, to make up for a time the judge
model misjudged; whoever signs up afterwards gets none. One who has had no draw chances
yet is given the new user's one that day as well. Each grant is kept, when and how many,
saying nothing of who granted it or to whom, so it stays when a user is deleted. Closed,
none can be granted. No one but an admin sees there is any of this. Driven through the
backend's external API, the clock moved by hand."""

import sqlite3
from dataclasses import replace
from pathlib import Path

import httpx
import pytest

from eidolon.config import Settings
from tests.conftest import ClientFactory
from tests.fakes import FAKE_JUDGE, FakeClock, FakeIdentityProvider, FakeLLM
from tests.test_admin_users import ADMIN, admin_client
from tests.test_delete_account import user_id
from tests.test_gift_backpack import state

GIFTS = "/api/admin/gifts"
GRANT = "/api/admin/gifts/reset-card-grants"


@pytest.fixture
def settings(settings: Settings) -> Settings:
    """With an admin, the judge model, and affinity and gifts on in `.env`."""
    return replace(
        settings, admins=frozenset({ADMIN}), judge=FAKE_JUDGE, affinity_and_gifts=True
    )


async def read(admin: httpx.AsyncClient) -> dict:
    res = await admin.get(GIFTS)
    assert res.status_code == 200, res.text
    return res.json()


async def grant(admin: httpx.AsyncClient) -> dict:
    res = await admin.post(GRANT)
    assert res.status_code == 200, res.text
    return res.json()


def cards(database: Path, name: str) -> int | None:
    """How many reset cards the user named `name` has as kept; None for no row of theirs."""
    with sqlite3.connect(database) as db:
        row = db.execute(
            "SELECT reset_cards FROM gift_balances WHERE user_id = ?", (user_id(database, name),)
        ).fetchone()
    return row and row[0]


async def test_not_an_admin_finds_nothing_there(make_client: ClientFactory, settings: Settings):
    user = make_client(FakeLLM())

    for res in [await user.get(GIFTS), await user.post(GRANT)]:
        assert res.status_code == 404, res.text
    assert cards(settings.database_path, "producer") is None


async def test_every_user_there_is_gets_one_banned_and_admins_too_and_later_ones_none(
    make_client: ClientFactory, settings: Settings, github: FakeIdentityProvider
):
    clock = FakeClock()
    admin = await admin_client(make_client, github, clock=clock)
    producer = make_client(FakeLLM(), clock=clock)  # has had no draw chances yet
    drawn = make_client(FakeLLM(), "drawn", clock=clock)
    await state(drawn)
    make_client(FakeLLM(), "banned", clock=clock)
    banned_id = user_id(settings.database_path, "banned")
    assert (await admin.post(f"/api/admin/users/{banned_id}/ban", json={})).status_code == 200
    before = await read(admin)
    clock.advance(minutes=5)

    granted = await grant(admin)

    later = make_client(FakeLLM(), "later", clock=clock)
    assert before == {"users": 4, "last_grant": None, "open": True}
    assert granted == {"granted_at": clock().isoformat(), "count": 4}
    assert await read(admin) == {"users": 5, "last_grant": granted, "open": True}
    for client, name in [(producer, "producer"), (drawn, "drawn"), (admin, "boss")]:
        seen = await state(client)
        assert (seen["reset_cards"], seen["draws"]) == (1, 2), name
    assert cards(settings.database_path, "banned") == 1
    assert (await state(later))["reset_cards"] == 0


async def test_granting_again_gives_each_another(
    make_client: ClientFactory, github: FakeIdentityProvider
):
    clock = FakeClock()
    admin = await admin_client(make_client, github, clock=clock)
    producer = make_client(FakeLLM(), clock=clock)
    await grant(admin)
    clock.advance(days=1)

    again = await grant(admin)

    assert again == {"granted_at": clock().isoformat(), "count": 2}
    assert (await read(admin))["last_grant"] == again
    assert (await state(producer))["reset_cards"] == 2


async def test_closed_none_are_granted(
    make_client: ClientFactory, settings: Settings, github: FakeIdentityProvider
):
    admin = await admin_client(make_client, github)
    assert (await admin.put("/api/admin/config/affinity", json={"enabled": False})).status_code == 200

    res = await admin.post(GRANT)

    assert res.status_code == 409
    assert res.json()["gifts_closed"] is True
    assert await read(admin) == {"users": 1, "last_grant": None, "open": False}
    assert cards(settings.database_path, "boss") is None


async def test_a_grant_stays_when_a_user_is_deleted(
    make_client: ClientFactory, settings: Settings, github: FakeIdentityProvider
):
    admin = await admin_client(make_client, github)
    make_client(FakeLLM())
    granted = await grant(admin)

    res = await admin.delete(f"/api/admin/users/{user_id(settings.database_path, 'producer')}")

    assert res.status_code == 204, res.text
    assert await read(admin) == {"users": 1, "last_grant": granted, "open": True}
