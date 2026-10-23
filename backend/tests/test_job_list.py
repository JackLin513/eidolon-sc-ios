"""The job list (GLOSSARY.md「工作」) comes from configuration beside the characters', as the
gift catalog does: some 40 jobs the weeks' jobs are drawn from, checked as the backend
starts."""

import tomllib
from collections import Counter

import pytest

from eidolon.job_list import JOBS_FILE

from tests.conftest import REPO_JOBS, CharacterConfig, ClientFactory
from tests.fakes import FakeLLM


def job(id: str, length: int = 1, category: str = "practice", slots: str | None = None) -> str:
    entry = (
        f'[[jobs]]\nid = "{id}"\nname = "{id}"\nnote = "说明"\ncategory = "{category}"\n'
        f"length = {length}\n"
    )
    return entry + (f"slots = {slots}\n" if slots is not None else "")


def test_the_repositorys_list_has_some_40_jobs_about_three_of_work_to_one_private():
    jobs = tomllib.loads(REPO_JOBS.read_text(encoding="utf-8"))["jobs"]

    by_category = Counter(j["category"] for j in jobs)
    work = by_category["practice"] + by_category["appearance"] + by_category["business"]
    assert 36 <= len(jobs) <= 44
    assert all(by_category[c] for c in ("practice", "appearance", "business", "private"))
    assert 2.5 <= work / by_category["private"] <= 3.5
    assert 0 < sum("slots" in j for j in jobs) <= 8  # only the few that make no sense otherwise
    assert not any("演出" in j["name"] + j["note"] for j in jobs)


async def test_the_repositorys_list_starts_the_backend(make_client: ClientFactory):
    client = make_client(FakeLLM())

    assert (await client.get("/api/health")).status_code == 200


@pytest.mark.parametrize(
    ("jobs", "named"),
    [
        (job("lesson") + job("lesson"), "lesson"),
        ('[[jobs]]\nid = "lesson"\nname = "上课"\ncategory = "practice"\nlength = 1\n', "note"),
        (job("lesson", length=4), "lesson"),
        (job("lesson", category="live"), "live"),
        (job("dinner", slots='["night"]'), "night"),
        (job("trip", length=3, slots='["morning", "afternoon", "evening"]'), "trip"),
        (job("lesson").replace('note = "说明"', 'note = "说\\n明"'), "lesson"),
        ("[[jobs]\n", JOBS_FILE),
    ],
)
def test_a_broken_list_keeps_the_backend_from_starting_naming_what_is_wrong(
    make_client: ClientFactory, characters: CharacterConfig, jobs: str, named: str
):
    characters.write(JOBS_FILE, jobs)

    with pytest.raises(RuntimeError, match=named):
        make_client(FakeLLM())
