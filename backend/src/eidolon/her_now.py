"""What she knows of now (GLOSSARY.md「此刻」), each time she speaks, whatever the occasion:
typing, in a call, reaching out (GLOSSARY.md「搭话」), visiting the bar (GLOSSARY.md「光顾」).

`HerNow` gives it in two steps. The first reads: her jobs, counting those done, so that her
affinity read after it has them counted; where her cycle has her; her job done today; and, for
a visit, her affinity too. The second gives the lines of now for the occasion, as its table
(`CARRIES`) has them, from what the first read and what the caller read besides (the producer
profile, when they were last in touch, the affinity lines). Where in the prompt they go is the
caller's to say (ADR-0020).

What every prompt of hers opens with (her sheet, her birthday, the world setting) is not now:
it stays the same all day, for a service to cache (`today.always_known`)."""

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime
from typing import Literal

from eidolon.affinity import Affinities, Status
from eidolon.characters import Character
from eidolon.cycles import Cycles, HerDays, always_neither, cycle_lines
from eidolon.producer import ProducerProfile, Talking, now_prompt
from eidolon.schedule import HerSchedule, Job, Schedules, schedule_lines
from eidolon.today import today_lines
from eidolon.world import World

Occasion = Talking | Literal["visit"]
"""Where she speaks: typing, in a call, reaching out (`apart`), or visiting the bar."""


@dataclass(frozen=True)
class Carries:
    """Which of what she knows of now an occasion tells her: the time, the producer's
    birthday and when they were last in touch (`now_prompt`); the day it is in Tokyo
    (`today_lines`); her jobs of this week and the next (`schedule_lines`); where her cycle
    has her (`cycle_lines`); how she feels toward the producer (the affinity lines)."""

    time: bool
    today: bool
    schedule: bool
    cycle: bool
    affinity: bool


CARRIES: dict[Occasion, Carries] = {
    "typing": Carries(time=True, today=True, schedule=True, cycle=True, affinity=True),
    "in_call": Carries(time=True, today=True, schedule=True, cycle=True, affinity=True),
    "apart": Carries(time=True, today=True, schedule=True, cycle=True, affinity=True),
    # The bar's story is only ever on the night shift: no time, nor the producer's birthday;
    # her cycle does not follow her there, and her jobs only tell why she came.
    "visit": Carries(time=False, today=True, schedule=False, cycle=False, affinity=True),
}
"""What each occasion tells her of now. Anything more she is to know of now goes here, for
every occasion."""


@dataclass(frozen=True)
class KnownNow:
    """What the first step read of now (GLOSSARY.md「此刻」), for the user's `character`: her
    jobs of their week and the next, those done counted (None while schedules are off); where
    her cycle has her at any time (neither, whenever, while cycles are off, or on an occasion
    that does not tell her of it); her job done today, the latest if more than one (None
    without); and, for a visit, her affinity, read after her jobs (None otherwise, or while
    affinity is off)."""

    character: Character
    her_jobs: HerSchedule | None
    her_days: HerDays
    done_today: Job | None
    affinity: Status | None


class HerNow:
    def __init__(
        self,
        characters: Mapping[str, Character],
        world: World | None = None,
        schedules: Schedules | None = None,
        cycles: Cycles | None = None,
        affinities: Affinities | None = None,
    ) -> None:
        """Without `world`, she knows only the birthdays and holiday of the day; without
        `schedules`, no jobs; without `cycles`, no days of hers; without `affinities`, she
        reads no affinity for a visit."""
        self._characters = characters
        self._world = world
        self._schedules = schedules
        self._cycles = cycles
        self._affinities = affinities

    async def read(
        self, user_id: str, character_id: str, device_timezone: str | None, occasion: Occasion
    ) -> KnownNow:
        """The first step, for the user's character on `occasion`, their device in
        `device_timezone` (None reaching out): her jobs read, those done counted towards her
        affinity, her cycle where the occasion tells her of it, her job done today, and for a visit her affinity. Whoever reads
        her affinity otherwise is to read it after this, so that it has her jobs done
        counted."""
        her_jobs = (
            await self._schedules.hers(user_id, character_id, device_timezone)
            if self._schedules is not None else None
        )
        her_days = (
            await self._cycles.her_days(user_id, character_id)
            if CARRIES[occasion].cycle and self._cycles is not None else always_neither
        )
        affinity = (
            await self._affinities.status(user_id, character_id)
            if occasion == "visit" and self._affinities is not None else None
        )
        return KnownNow(
            self._characters[character_id], her_jobs, her_days,
            her_jobs.done_today() if her_jobs is not None else None, affinity,
        )

    def lines(
        self,
        known: KnownNow,
        occasion: Occasion,
        now: datetime,
        timezone: str,
        profile: ProducerProfile,
        last_contact: datetime | None,
        affinity_lines: Sequence[str],
    ) -> list[str]:
        """The second step: the lines of now for `occasion` (`CARRIES`), at `now`, the
        producer in `timezone` with `profile`, last in touch at `last_contact` (None if never,
        or in a call), she feeling as `affinity_lines` say; her cycle where it has her at
        `now`. Joined by new lines, they make one section: the time and the rest of
        `now_prompt`, the affinity lines last in it; the day in Tokyo; her jobs; her cycle."""
        carries = CARRIES[occasion]
        character = known.character
        felt = affinity_lines if carries.affinity else ()
        lines: list[str] = []
        if carries.time:
            assert occasion != "visit"
            lines.append(now_prompt(profile, now, timezone, occasion, felt, last_contact))
        else:
            lines += felt
        if carries.today:
            lines += today_lines(now, character, self._characters.values(), self._world)
        if carries.schedule and known.her_jobs is not None:
            lines += schedule_lines(known.her_jobs)
        if carries.cycle:
            lines += cycle_lines(known.her_days(now, timezone))
        return lines
