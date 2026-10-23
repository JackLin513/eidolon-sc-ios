"""The dashboard's count of producers who scheduled this week (GLOSSARY.md「看板」「日程」): how
many users saved any job into the week Beijing is in, counted as the dashboard is opened,
whatever its range; none where schedules are off. It goes with the「好感度」section, and is
there with affinity off too."""

from dataclasses import replace
from datetime import timedelta

import pytest

from eidolon.config import Settings
from tests.conftest import ClientFactory
from tests.fakes import FAKE_JUDGE, FakeClock, FakeIdentityProvider, FakeLLM
from tests.test_activity_records import dashboard
from tests.test_admin_users import ADMIN, admin_beside
from tests.test_schedule_saving import WEDNESDAY_AFTERNOON, WEEK, placed, publish, save


@pytest.fixture
def settings(settings: Settings) -> Settings:
    """With an admin, and affinity on."""
    return replace(
        settings, admins=frozenset({ADMIN}), judge=FAKE_JUDGE, affinity_and_gifts=True
    )


async def test_it_counts_who_saved_any_of_this_week_and_not_of_another(
    make_client: ClientFactory, settings: Settings, github: FakeIdentityProvider
):
    clock = FakeClock(WEDNESDAY_AFTERNOON - timedelta(weeks=1))
    last_weeks = make_client(FakeLLM(), "last", clock=clock)
    publish(settings.database_path, "2026-09-14", ("old", 1, None))
    publish(settings.database_path, WEEK, ("lesson", 1, None), ("talk", 1, None))
    await save(last_weeks, "2026-09-14", placed("old", 4, 0))
    clock.advance(weeks=1)
    for name, job in (("producer", "lesson"), ("friend", "talk")):
        client = make_client(FakeLLM(), name, clock=clock)
        assert (await save(client, WEEK, placed(job, 4, 0))).json()["returned"] == []
    assert (await save(client, WEEK, placed("lesson", 5, 0))).json()["returned"] == []  # theirs too

    async with admin_beside(last_weeks, github) as admin:
        board = await dashboard(admin, "90d")

    assert board["scheduled_this_week"] == 2


@pytest.mark.parametrize(
    ("affinity", "schedule", "shown"), [(True, False, None), (False, True, 0)]
)
async def test_it_is_there_with_schedules_on_affinity_or_not(
    make_client: ClientFactory,
    settings: Settings,
    github: FakeIdentityProvider,
    affinity: bool,
    schedule: bool,
    shown: int | None,
):
    client = make_client(
        FakeLLM(), settings=replace(settings, affinity_and_gifts=affinity, schedule=schedule)
    )

    async with admin_beside(client, github) as admin:
        board = await dashboard(admin)

    assert (board["affinity"] is None, board["scheduled_this_week"]) == (not affinity, shown)
