"""The switches for cycles (GLOSSARY.md「周期」). The deployment's: `EIDOLON_CYCLES` in
`.env`, on unless set to 0, anything but 0 or 1 refused as the backend starts; the admin
console's「周期」card overrides it, its change in effect from the next turn on
(`test_her_days`). The user's own: on by default, kept on the server so that it holds on
every device; the account says it where the deployer has cycles on, nothing where not, and
it cannot be set then; deleted with the account."""

import sqlite3
from dataclasses import replace

import httpx
import pytest

from eidolon.config import Settings
from tests.conftest import ClientFactory
from tests.fakes import FakeIdentityProvider, FakeLLM
from tests.test_admin_users import ADMIN, admin_beside
from tests.test_delete_account import DELETE

CYCLES = "/api/admin/config/cycles"
SWITCH = "/api/account/cycles"


async def switched_on(client: httpx.AsyncClient) -> bool | None:
    res = await client.get("/api/account")
    assert res.status_code == 200
    return res.json()["cycles"]


async def switch(client: httpx.AsyncClient, on: bool) -> None:
    res = await client.put(SWITCH, json={"on": on})
    assert res.status_code == 204, res.text


def test_unset_in_env_it_is_on(monkeypatch: pytest.MonkeyPatch):
    # 0, 1 and anything else are every switch's (`config._switch`), as test_exempting_keys has.
    monkeypatch.setenv("CHAT_LLM_BASE_URL", "https://llm.example.com/v1")
    monkeypatch.setenv("CHAT_LLM_API_KEY", "sk-deployer")
    monkeypatch.setenv("CHAT_LLM_MODEL", "deployer-model")
    monkeypatch.delenv("EIDOLON_CYCLES", raising=False)

    assert Settings.from_env().cycles is True


async def test_the_admin_console_reads_overrides_and_restores_it(
    make_client: ClientFactory, settings: Settings, github: FakeIdentityProvider
):
    on = replace(settings, admins=frozenset({ADMIN}), cycles=True)
    client = make_client(FakeLLM(), settings=on)

    async with admin_beside(client, github) as admin:
        described = (await admin.get("/api/admin/config")).json()["cycles"]
        turned_off = await admin.put(CYCLES, json={"enabled": False})
        refused = await admin.put(CYCLES, json={"enabled": "no"})
        restored = await admin.delete(CYCLES)

    assert described == {
        "status": "env", "env": {"enabled": True}, "effective": {"enabled": True},
        "override": None, "failure": None,
    }
    assert turned_off.json()["cycles"]["override"] == {"enabled": False}
    assert turned_off.json()["cycles"]["effective"] == {"enabled": False}
    assert refused.status_code == 422
    assert restored.json()["cycles"]["effective"] == {"enabled": True}


async def test_the_account_says_nothing_where_the_deployer_has_them_off_else_the_users_switch(
    make_client: ClientFactory, settings: Settings
):
    off = make_client(FakeLLM(), "someone", settings=replace(settings, cycles=False))
    on = make_client(FakeLLM(), settings=replace(settings, cycles=True))
    by_default = await switched_on(on)

    await switch(on, False)

    assert (await switched_on(off), by_default, await switched_on(on)) == (None, True, False)


async def test_it_cannot_be_set_where_the_deployer_has_them_off_nor_to_what_is_not_on_or_off(
    make_client: ClientFactory, settings: Settings
):
    off = make_client(FakeLLM(), "someone", settings=replace(settings, cycles=False))
    on = make_client(FakeLLM(), settings=replace(settings, cycles=True))

    refused = (await off.put(SWITCH, json={"on": False})).status_code
    invalid = (await on.put(SWITCH, json={"on": "no"})).status_code

    assert (refused, invalid) == (409, 422)
    assert (await switched_on(on)) is True


async def test_deleting_the_user_deletes_their_switch(
    make_client: ClientFactory, settings: Settings
):
    client = make_client(FakeLLM(), settings=replace(settings, cycles=True))
    await switch(client, False)

    assert (await client.post("/api/account/delete", json=DELETE)).status_code == 204

    with sqlite3.connect(settings.database_path) as db:
        assert db.execute("SELECT COUNT(*) FROM cycles_off").fetchone() == (0,)
