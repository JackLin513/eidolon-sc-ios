"""The user's own switch for reach-outs (GLOSSARY.md「搭话」): on by default, kept on the server
so that it holds on every device; the account says it where the deployer turns reach-outs on,
nothing where not, and it cannot be set then. One who turns it off is reached out to by none
of the characters, their times left as they are, and comes again by them once it is back on,
a week after the last contact still the end of it.

Driven through the backend's external API, with the reach-outs' ticks taken by hand
(`ReachOuts.run_due`), as in `test_reach_outs`."""

import sqlite3
from dataclasses import replace
from datetime import timedelta

import httpx
import pytest

from eidolon.config import Settings
from tests.conftest import SITE, ClientFactory, sign_in
from tests.fakes import FakeRandom
from tests.test_delete_account import DELETE
from tests.test_reach_outs import (
    REACH_OUT,
    REPLY,
    backend_of,
    last_contact,
    reach_outs,
    record,
    talked,
)
from tests.test_text_turn import send_turn, start_conversation

SWITCH = "/api/account/reach-outs"


@pytest.fixture
def settings(settings: Settings) -> Settings:
    """With reach-outs on in `.env`."""
    return replace(settings, reach_outs=True)


async def switched(client: httpx.AsyncClient) -> bool | None:
    res = await client.get("/api/account")
    assert res.status_code == 200
    return res.json()["reach_outs"]


async def turn(client: httpx.AsyncClient, on: bool) -> None:
    res = await client.put(SWITCH, json={"on": on})
    assert res.status_code == 204, res.text


async def test_the_account_says_nothing_where_the_deployer_has_them_off_else_the_users_switch(
    make_client: ClientFactory, settings: Settings
):
    client, *_ = await talked(make_client, settings=replace(settings, reach_outs=False))
    on, *_ = await talked(make_client, settings=replace(settings, reach_outs=True))
    by_default = await switched(on)

    await turn(on, False)

    assert (await switched(client), by_default, await switched(on)) == (None, True, False)


async def test_turned_off_it_holds_on_every_device_till_turned_on_again(
    make_client: ClientFactory, settings: Settings
):
    client, *_ = await talked(make_client, settings=replace(settings, reach_outs=True))
    backend = backend_of(client)
    async with httpx.AsyncClient(
        transport=client._transport, base_url="http://test", headers=SITE,
        cookies=sign_in(backend.store, "producer", backend.clock()),
    ) as phone:
        await turn(client, False)
        off_on_the_phone = await switched(phone)
        await turn(phone, True)
        on_here = await switched(client)

    assert (off_on_the_phone, on_here) == (False, True)


async def test_it_cannot_be_set_where_the_deployer_has_them_off_nor_to_what_is_not_on_or_off(
    make_client: ClientFactory, settings: Settings
):
    off, *_ = await talked(make_client, settings=replace(settings, reach_outs=False))
    on, *_ = await talked(make_client, settings=replace(settings, reach_outs=True))

    refused = (await off.put(SWITCH, json={"on": False})).status_code
    invalid = [
        (await on.put(SWITCH, json=body)).status_code for body in ({"on": "no"}, {"on": 0}, {})
    ]

    assert (refused, invalid) == (409, [422] * 3)
    assert (await switched(on)) is True


async def test_turned_off_none_of_them_comes_and_turned_on_again_she_comes_when_her_time_is(
    make_client: ClientFactory, settings: Settings
):
    client, _, clock, conversation = await talked(
        make_client, REPLY, REACH_OUT, REACH_OUT, random=FakeRandom(0, 0)
    )
    other = await start_conversation(client, "kogane")
    await send_turn(client, other, "我去练习了")
    for each in (conversation, other):  # trust: 20–36 hours, at its start, as drawn once on
        last_contact(settings.database_path, each, clock.now - timedelta(hours=20))
    reach_out = backend_of(client).reach_outs

    await turn(client, False)
    await reach_out.run_due()
    while_off = [reach_outs(await record(client, each)) for each in (conversation, other)]
    await turn(client, True)
    await reach_out.run_due()

    assert while_off == [[], []]
    assert [len(reach_outs(await record(client, each))) for each in (conversation, other)] == [1, 1]


async def test_turned_on_again_a_week_after_the_last_contact_she_does_not_come(
    make_client: ClientFactory, settings: Settings
):
    client, _, clock, conversation = await talked(make_client, REACH_OUT, random=FakeRandom(0))
    last_contact(settings.database_path, conversation, clock.now - timedelta(hours=20))
    reach_out = backend_of(client).reach_outs

    await turn(client, False)
    await reach_out.run_due()
    clock.advance(days=7)
    await turn(client, True)
    await reach_out.run_due()

    assert reach_outs(await record(client, conversation)) == []


async def test_deleting_the_user_deletes_their_switch(
    make_client: ClientFactory, settings: Settings
):
    client, *_ = await talked(make_client)
    await turn(client, False)

    assert (await client.post("/api/account/delete", json=DELETE)).status_code == 204

    with sqlite3.connect(settings.database_path) as db:
        assert db.execute("SELECT COUNT(*) FROM reach_outs_off").fetchone()[0] == 0
