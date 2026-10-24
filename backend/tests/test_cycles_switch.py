"""The deployment's switch for cycles (GLOSSARY.md「周期」): `EIDOLON_CYCLES` in `.env`, on
unless set to 0, anything but 0 or 1 refused as the backend starts; the admin console's
「周期」card overrides it, its change in effect from the next turn on
(`test_her_days`)."""

from dataclasses import replace

import pytest

from eidolon.config import Settings
from tests.conftest import ClientFactory
from tests.fakes import FakeIdentityProvider, FakeLLM
from tests.test_admin_users import ADMIN, admin_beside

CYCLES = "/api/admin/config/cycles"


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
