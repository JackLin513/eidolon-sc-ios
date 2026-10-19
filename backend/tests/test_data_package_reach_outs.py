"""Reach-outs in data packages (GLOSSARY.md「搭话」「数据包」): what she said first in a
conversation goes into a package with it, as the model wrote it, delivery cues and all, and
comes out of it into another deployment as it was, seen; packages of the format before them
still import. The user's switch and when she is to come next stay behind. Deleting a past
conversation deletes its reach-outs and when she was to come in it. Driven through the API,
reach-outs made as `test_reach_outs.py` makes them."""

from dataclasses import replace
from datetime import timedelta
from pathlib import Path

from eidolon.config import Settings
from tests.conftest import ClientFactory
from tests.fakes import FakeLLM, FakeRandom
from tests.test_data_package import MANIFEST, export, import_package, package_of, unzipped
from tests.test_data_package_conversations import packaged_conversation, records
from tests.test_delete_account import rows_mentioning
from tests.test_past_conversations import hers
from tests.test_reach_outs import (
    MIDDLE,
    REACH_OUT,
    backend_of,
    last_contact,
    reach_outs,
    record,
    settings,  # noqa: F401  reach-outs on in `.env`
    talked,
)
from tests.test_text_turn import start_conversation
from tests.test_unseen_reach_outs import unseen

PACKAGED_REACH_OUT = {
    "ja": "[happily] プロデューサーさん！レッスン終わったよ",
    "zh": "制作人！练习结束了哦",
    "segments": [
        {"ja": "[happily] プロデューサーさん！", "zh": "制作人！"},
        {"ja": "レッスン終わったよ", "zh": "练习结束了哦"},
    ],
}
"""`REACH_OUT` as a package keeps it, but for its time."""


async def test_her_reach_outs_move_to_another_deployment_as_they_were_and_seen(
    make_client: ClientFactory, settings: Settings, tmp_path: Path
):
    here, _, clock, conversation = await talked(
        make_client, REACH_OUT, random=FakeRandom(MIDDLE)
    )
    last_contact(settings.database_path, conversation, clock.now - timedelta(hours=28))
    await backend_of(here).reach_outs.run_due()
    assert await unseen(here) == {"mano": True}
    there = make_client(
        FakeLLM(), settings=replace(settings, database_path=tmp_path / "there.db")
    )

    package = await export(here, "conversations")
    _, manifest, data = unzipped(package)
    assert manifest["format"] == 2
    [packaged] = data["conversations"][0]["reach_outs"]
    assert packaged == PACKAGED_REACH_OUT | {"created_at": packaged["created_at"]}
    res = await import_package(there, package, "conversations")

    assert res.status_code == 200, res.text
    assert res.json()["conversations"] == 1
    assert await unseen(there) == {"mano": False}
    assert await records(there) == await records(here)
    assert len(reach_outs(await record(there, (await hers(there))[0]["id"]))) == 1
    _, _, again = unzipped(await export(there, "conversations"))
    assert again["conversations"][0]["reach_outs"] == [packaged]


async def test_a_package_of_the_format_before_reach_outs_still_imports(
    make_client: ClientFactory, settings: Settings
):
    client = make_client(FakeLLM())
    conversation = packaged_conversation("1", "2026-09-01")
    old = {**MANIFEST, "format": 1, "categories": ["conversations"],
           "counts": {"conversations": 1}}

    res = await import_package(client, package_of(old, {"conversations": [conversation]}),
                               "conversations")
    with_reach_outs = await import_package(client, package_of(old, {"conversations": [
        packaged_conversation("2", "2026-09-02")
        | {"reach_outs": [PACKAGED_REACH_OUT | {"created_at": conversation["created_at"]}]},
    ]}), "conversations")

    assert res.status_code == 200, res.text
    assert res.json()["conversations"] == 1
    assert with_reach_outs.status_code == 422
    assert with_reach_outs.json()["code"] == "broken"
    [only] = await hers(client)
    assert reach_outs(await record(client, only["id"])) == []


async def test_a_past_conversation_deleted_leaves_none_of_her_reach_outs_or_when_she_was_to_come(
    make_client: ClientFactory, settings: Settings
):
    client, _, clock, past = await talked(make_client, REACH_OUT, random=FakeRandom(MIDDLE))
    last_contact(settings.database_path, past, clock.now - timedelta(hours=28))
    await backend_of(client).reach_outs.run_due()
    assert set(rows_mentioning(settings.database_path, past)) >= {
        "reach_outs", "reach_out_schedules",
    }
    await start_conversation(client)

    assert (await client.delete(f"/api/conversations/{past}")).status_code == 204

    assert rows_mentioning(settings.database_path, past) == {}
