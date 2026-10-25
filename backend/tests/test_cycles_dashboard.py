"""The dashboard's count of producers who wrote down periods (GLOSSARY.md「看板」「周期」): how
many users have any record now, however many characters they wrote down, counted as the
dashboard is opened, whatever its range; none where the deployer has cycles off. It goes
with the「好感度」section, and is there with affinity off too."""

from dataclasses import replace

import pytest

from eidolon.config import Settings
from tests.conftest import ClientFactory
from tests.fakes import FAKE_JUDGE, FakeIdentityProvider
from tests.test_activity_records import dashboard
from tests.test_admin_users import ADMIN, admin_beside
from tests.test_cycle_records import add, client_of


@pytest.fixture
def settings(settings: Settings) -> Settings:
    """With an admin, affinity and cycles on."""
    return replace(
        settings, admins=frozenset({ADMIN}), judge=FAKE_JUDGE, affinity_and_gifts=True,
        cycles=True,
    )


async def test_it_counts_who_has_any_record_once_whatever_the_range(
    make_client: ClientFactory, settings: Settings, github: FakeIdentityProvider
):
    producer = client_of(make_client, settings)
    await add(producer, "2026-01-01")
    await add(producer, "2026-10-01")
    await add(producer, "2026-10-01", character="kogane")
    friend = client_of(make_client, settings, "friend")
    gone = (await add(friend, "2026-10-01")).json()["records"][0]["id"]
    await friend.delete(f"/api/cycles/records/{gone}")
    await add(client_of(make_client, settings, "another"), "2026-10-02")

    async with admin_beside(producer, github) as admin:
        boards = [await dashboard(admin, range) for range in ("24h", "90d")]

    assert [b["recorded_cycles"] for b in boards] == [2, 2]


@pytest.mark.parametrize(
    ("affinity", "cycles", "shown"), [(True, False, None), (False, True, 0)]
)
async def test_it_is_there_with_cycles_on_affinity_or_not(
    make_client: ClientFactory,
    settings: Settings,
    github: FakeIdentityProvider,
    affinity: bool,
    cycles: bool,
    shown: int | None,
):
    client = client_of(
        make_client, replace(settings, affinity_and_gifts=affinity, cycles=cycles)
    )

    async with admin_beside(client, github) as admin:
        board = await dashboard(admin)

    assert (board["affinity"] is None, board["recorded_cycles"]) == (not affinity, shown)
