"""The periods the user writes down of each character, and what is estimated of her from them
(GLOSSARY.md「周期」「推算」): written down, changed and deleted, each answered with her
records and estimate; refused, saying why, after today where the producer is, out of 1 to
10 days, or overlapping another of hers; every character's read in idol order, nothing of
her true cycle in it. While the deployment or the user has cycles off, none are read or
written, and they are kept. Deleted with the user, not with a conversation.

Driven through the backend's external API."""

import sqlite3
from dataclasses import replace
from datetime import UTC, datetime

import httpx
import pytest

from eidolon.config import Settings
from tests.conftest import ClientFactory
from tests.fakes import FakeClock, FakeLLM
from tests.test_conversation_events import hang_up
from tests.test_cycles_switch import switch
from tests.test_delete_account import DELETE
from tests.test_schedule_weeks import live_in
from tests.test_text_turn import start_conversation

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=UTC)
"""20:00 on the 25th in Shanghai, 1:00 on the 26th in Auckland."""

CYCLES = "/api/cycles"
MANO = "/api/cycles/mano/records"


@pytest.fixture
def settings(settings: Settings) -> Settings:
    return replace(settings, cycles=True)


def client_of(
    make_client: ClientFactory, settings: Settings, user: str = "producer"
) -> httpx.AsyncClient:
    return make_client(FakeLLM(), user, settings=settings, clock=FakeClock(NOW))


async def add(
    client: httpx.AsyncClient, first_day: str, days: int = 5, character: str = "mano"
) -> httpx.Response:
    return await client.post(
        f"/api/cycles/{character}/records", json={"first_day": first_day, "days": days}
    )


async def added(client: httpx.AsyncClient, first_day: str, days: int = 5) -> dict:
    res = await add(client, first_day, days)
    assert res.status_code == 200, res.text
    return res.json()


async def change(client: httpx.AsyncClient, record: str, first_day: str, days: int = 5):
    return await client.put(
        f"/api/cycles/records/{record}", json={"first_day": first_day, "days": days}
    )


async def read(client: httpx.AsyncClient) -> dict:
    res = await client.get(CYCLES)
    assert res.status_code == 200, res.text
    return res.json()


def firsts(hers: dict) -> list[tuple[str, int]]:
    return [(r["first_day"], r["days"]) for r in hers["records"]]


async def test_written_down_she_is_answered_with_her_records_and_estimate(
    make_client: ClientFactory, settings: Settings
):
    client = client_of(make_client, settings)

    await added(client, "2026-09-25")
    hers = await added(client, "2026-08-26", 4)

    assert hers["character_id"] == "mano"
    assert firsts(hers) == [("2026-08-26", 4), ("2026-09-25", 5)]
    assert hers["estimate"] == {
        "cycle": 30, "period": 5, "reasons": [],
        "periods": [
            {"first_day": "2026-10-25", "days": 5}, {"first_day": "2026-11-24", "days": 5},
            {"first_day": "2026-12-24", "days": 5},
        ],
        "off_by": None,
        "today": {"kind": "estimated"},
    }
    assert (await read(client))["characters"][0] == hers


async def test_changed_and_deleted_the_estimate_follows(
    make_client: ClientFactory, settings: Settings
):
    client = client_of(make_client, settings)
    await added(client, "2026-08-25")
    later = (await added(client, "2026-09-24"))["records"][1]["id"]

    changed = await change(client, later, "2026-09-22", 6)
    deleted = await client.delete(f"/api/cycles/records/{later}")

    assert changed.status_code == 200
    assert firsts(changed.json()) == [("2026-08-25", 5), ("2026-09-22", 6)]
    assert changed.json()["estimate"]["cycle"] == 28
    assert deleted.status_code == 200
    assert firsts(deleted.json()) == [("2026-08-25", 5)]
    assert deleted.json()["estimate"]["reasons"] == ["once", "late"]


async def test_a_first_day_after_today_where_the_producer_is_is_refused(
    make_client: ClientFactory, settings: Settings
):
    client = client_of(make_client, settings)

    in_shanghai = await add(client, "2026-10-26")
    await live_in(client, "Pacific/Auckland")
    in_auckland = await add(client, "2026-10-26")
    tomorrow_there = await add(client, "2026-10-27")

    assert in_shanghai.status_code == 422
    assert in_shanghai.json() == {"detail": "不能记未来", "reason": "future"}
    assert in_auckland.status_code == 200
    assert tomorrow_there.json()["reason"] == "future"


async def test_the_devices_time_zone_counts_where_the_profile_has_none(
    make_client: ClientFactory, settings: Settings
):
    client = client_of(make_client, settings)

    res = await client.post(
        MANO, json={"first_day": "2026-10-26", "days": 5},
        headers={"X-Timezone": "Pacific/Auckland"},
    )

    assert res.status_code == 200


@pytest.mark.parametrize("days", [0, 11])
async def test_days_out_of_1_to_10_are_refused(
    make_client: ClientFactory, settings: Settings, days: int
):
    client = client_of(make_client, settings)

    res = await add(client, "2026-10-01", days)

    assert res.status_code == 422
    assert res.json()["reason"] == "days"
    assert (await read(client))["characters"][0]["records"] == []


async def test_overlapping_another_of_hers_is_refused_but_ending_the_day_before_is_not(
    make_client: ClientFactory, settings: Settings
):
    client = client_of(make_client, settings)
    first = (await added(client, "2026-10-01", 5))["records"][0]

    overlapping = await add(client, "2026-10-05")
    touching = await add(client, "2026-10-06")
    before_it = await add(client, "2026-09-26")
    another_character = await add(client, "2026-10-02", character="kogane")

    assert overlapping.status_code == 422
    assert overlapping.json() == {
        "detail": "和 10月1日 那次重叠了，要改就编辑那一次", "reason": "overlap",
        "overlapping": first,
    }
    assert (touching.status_code, before_it.status_code) == (200, 200)
    assert another_character.status_code == 200


async def test_changed_it_is_not_compared_with_itself_but_with_the_others(
    make_client: ClientFactory, settings: Settings
):
    client = client_of(make_client, settings)
    await added(client, "2026-09-01")
    record = (await added(client, "2026-10-01"))["records"][1]["id"]

    longer = await change(client, record, "2026-10-01", 8)
    onto_the_other = await change(client, record, "2026-09-03", 5)

    assert longer.status_code == 200
    assert onto_the_other.status_code == 422
    assert onto_the_other.json()["overlapping"]["first_day"] == "2026-09-01"


async def test_a_character_not_configured_or_someone_elses_record_is_not_found(
    make_client: ClientFactory, settings: Settings
):
    mine = client_of(make_client, settings)
    theirs = client_of(make_client, settings, "someone")
    record = (await added(mine, "2026-10-01"))["records"][0]["id"]

    nobody = await add(mine, "2026-10-01", character="nobody")
    changed = await change(theirs, record, "2026-10-02")
    deleted = await theirs.delete(f"/api/cycles/records/{record}")
    no_such = await mine.delete("/api/cycles/records/no-such-record")

    assert [r.status_code for r in (nobody, changed, deleted, no_such)] == [404] * 4
    assert firsts((await read(mine))["characters"][0]) == [("2026-10-01", 5)]


async def test_read_every_character_in_idol_order_none_estimated_without_records(
    make_client: ClientFactory, settings: Settings
):
    client = client_of(make_client, settings)
    await added(client, "2026-10-01")

    view = await read(client)

    assert (view["enabled"], view["today"]) == (True, "2026-10-25")
    assert [c["character_id"] for c in view["characters"]] == ["mano", "kogane"]
    assert view["characters"][1] == {"character_id": "kogane", "records": [], "estimate": None}


async def test_nothing_of_her_true_cycle_is_read(
    make_client: ClientFactory, settings: Settings
):
    # Her true cycle is seeded with the secret key: another key, another her, the same page.
    views = []
    for key in ("test-secret-key", "another-secret-key"):
        client = client_of(make_client, replace(settings, secret_key=key), f"producer-{key}")
        await added(client, "2026-08-27", 4)
        await added(client, "2026-09-25", 6)
        view = await read(client)
        for her in view["characters"]:
            for record in her["records"]:
                record.pop("id")
        views.append(view)

    assert views[0] == views[1]


async def test_off_by_the_deployer_none_are_read_or_written(
    make_client: ClientFactory, settings: Settings
):
    client = client_of(make_client, replace(settings, cycles=False))

    view = await read(client)
    written = await add(client, "2026-10-01")
    changed = await change(client, "any", "2026-10-01")
    deleted = await client.delete("/api/cycles/records/any")

    assert view == {"enabled": False}
    assert [r.status_code for r in (written, changed, deleted)] == [409] * 3


async def test_off_by_the_user_none_are_read_or_written_and_on_again_they_are_there(
    make_client: ClientFactory, settings: Settings
):
    client = client_of(make_client, settings)
    record = (await added(client, "2026-10-01"))["records"][0]["id"]

    await switch(client, False)
    view_off = await read(client)
    written = await add(client, "2026-09-01")
    deleted = await client.delete(f"/api/cycles/records/{record}")
    await switch(client, True)

    assert view_off == {"enabled": False}
    assert (written.status_code, deleted.status_code) == (409, 409)
    assert firsts((await read(client))["characters"][0]) == [("2026-10-01", 5)]


async def test_deleted_with_the_user_not_with_a_conversation(
    make_client: ClientFactory, settings: Settings
):
    client = client_of(make_client, settings)
    past = await start_conversation(client)
    await added(client, "2026-10-01")
    hang_up(settings.database_path, past)
    await start_conversation(client)

    assert (await client.delete(f"/api/conversations/{past}")).status_code == 204
    assert firsts((await read(client))["characters"][0]) == [("2026-10-01", 5)]

    assert (await client.post("/api/account/delete", json=DELETE)).status_code == 204
    with sqlite3.connect(settings.database_path) as db:
        assert db.execute("SELECT COUNT(*) FROM cycle_records").fetchone() == (0,)
