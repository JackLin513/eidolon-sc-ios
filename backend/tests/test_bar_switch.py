"""The bar's switch (GLOSSARY.md「酒吧」) and what reading it gives. The deployment's switch is
`EIDOLON_BAR` in `.env`, on unless set to 0, anything but 0 or 1 refused as the backend
starts; the admin console's「酒吧」card overrides it. `/api/bar` is for users who agreed to
the terms (`test_consent`): off, it says only that; on, it has the drink catalog the bar
counter and the recipe book are drawn from, without what only the model is given (the
Japanese names, the recipe cards' descriptions), and nothing of any character's tastes."""

from dataclasses import replace

import pytest

from eidolon.config import Settings
from tests.conftest import ClientFactory
from tests.fakes import FakeIdentityProvider, FakeLLM
from tests.test_admin_users import ADMIN, admin_beside

BAR = "/api/admin/config/bar"


def test_unset_in_env_it_is_on(monkeypatch: pytest.MonkeyPatch):
    # 0, 1 and anything else are every switch's (`config._switch`), as test_exempting_keys has.
    monkeypatch.setenv("CHAT_LLM_BASE_URL", "https://llm.example.com/v1")
    monkeypatch.setenv("CHAT_LLM_API_KEY", "sk-deployer")
    monkeypatch.setenv("CHAT_LLM_MODEL", "deployer-model")
    monkeypatch.delenv("EIDOLON_BAR", raising=False)

    assert Settings.from_env().bar is True


async def test_on_reading_gives_the_drink_catalog_without_what_only_the_model_is_given(
    make_client: ClientFactory,
):
    client = make_client(FakeLLM())

    res = await client.get("/api/bar")

    assert res.status_code == 200
    bar = res.json()
    assert set(bar) == {"enabled", "drinks"}
    assert bar["enabled"] is True
    drinks = {d["id"]: d for d in bar["drinks"]}
    assert len(drinks) == 28
    assert drinks["sugar-rush"] == {
        "id": "sugar-rush", "name": "Sugar Rush", "short_name": "Sugar Rush",
        "flavor": "sweet", "kind": "girly", "method": "mix",
        "adelhyde": 2, "bronson_extract": 0, "powdered_delta": 1, "flanergide": 0,
        "karmotrine": "optional", "ice": False, "aged": False, "big": False, "page": 21,
    }
    assert drinks["zen-star"]["big"] is True
    assert drinks["mulan-tea"] == {
        "id": "mulan-tea", "name": "Mulan Tea", "short_name": "Tea",
        "flavor": "sweet", "kind": "classic", "method": "bottle",
        "description": "调味茶", "karmotrine": 0,
    }
    assert not any("name_ja" in d for d in drinks.values())


async def test_off_reading_says_only_that_and_the_admin_console_overrides_env(
    make_client: ClientFactory, settings: Settings, github: FakeIdentityProvider
):
    client = make_client(FakeLLM(), settings=replace(settings, admins=frozenset({ADMIN})))

    async with admin_beside(client, github) as admin:
        described = (await admin.get("/api/admin/config")).json()["bar"]
        turned_off = await admin.put(BAR, json={"enabled": False})
        read_off = (await client.get("/api/bar")).json()
        refused = await admin.put(BAR, json={"enabled": "no"})
        restored = await admin.delete(BAR)
        read_on = (await client.get("/api/bar")).json()

    assert described == {
        "status": "env", "env": {"enabled": True}, "effective": {"enabled": True},
        "override": None, "failure": None,
    }
    assert turned_off.json()["bar"]["override"] == {"enabled": False}
    assert read_off == {"enabled": False}
    assert refused.status_code == 422
    assert restored.json()["bar"]["effective"] == {"enabled": True}
    assert read_on["enabled"] is True
