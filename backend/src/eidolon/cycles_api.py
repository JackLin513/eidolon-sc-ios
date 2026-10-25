"""Cycles over HTTP (GLOSSARY.md「周期」「推算」).

The periods the user writes down of each character, and what is estimated of her from
them, both in the producer's time zone, their profile's, else their device's
(`X-Timezone`): `/api/cycles` reads every character's, in idol order; POST
`/api/cycles/{character_id}/records` writes one down, PUT and DELETE
`/api/cycles/records/{record_id}` change and delete one, each answering with that
character's records and estimate. A record refused says why with 422 and `reason`
(`future`, `days`, `overlap`, the last with the record it overlaps, `overlapping`). While
the deployment or the user has cycles off, reading says only that, and writing is refused
with 409; a character not configured, or a record not the user's, is not found.

Forcing where her cycle has her, for development only (`EIDOLON_DEV_LOGIN=1`): at
`/api/dev/cycles/{character_id}`, PUT has the signed-in user's character in her period on
day `day`, premenstrual with `day` days left, or neither, whatever the day; DELETE has her
where her true cycle has her again. Kept in memory, gone as the server restarts; the
switches still hold. Without development sign-in, there is no such route."""

from datetime import date
from typing import Self

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, model_validator

from eidolon.assembly import Backend
from eidolon.cycle_records import NotFound, Refused
from eidolon.cycles import CyclesOff, Forced, Phase
from eidolon.her_cycle import LONGEST_PERIOD, PREMENSTRUAL_DAYS
from eidolon.sessions import DeviceTimezone, UserId


class RecordInput(BaseModel):
    first_day: date
    """The calendar day it began, where the producer is."""
    days: int


class ForcedInput(BaseModel):
    phase: Phase
    day: int = 0
    """The day of her period, from 1; or how many days are left before it, from 1; none
    for neither."""

    @model_validator(mode="after")
    def _day_within(self) -> Self:
        most = {"period": LONGEST_PERIOD, "premenstrual": max(PREMENSTRUAL_DAYS)}.get(self.phase)
        if most is not None and not 1 <= self.day <= most:
            raise ValueError(f"day 应在 1 到 {most} 之间")
        return self


def add_cycle_routes(app: FastAPI, backend: Backend) -> None:
    records = backend.cycle_records

    @app.exception_handler(Refused)
    async def refused(_: Request, e: Refused) -> JSONResponse:
        body: dict[str, object] = {"detail": str(e), "reason": e.reason}
        if e.overlapping is not None:
            body["overlapping"] = e.overlapping.shown()
        return JSONResponse(body, status_code=422)

    @app.exception_handler(NotFound)
    async def not_found(_: Request, e: NotFound) -> JSONResponse:
        return JSONResponse({"detail": "没有这条记录或这位角色"}, status_code=404)

    @app.exception_handler(CyclesOff)
    async def cycles_off(_: Request, e: CyclesOff) -> JSONResponse:
        return JSONResponse({"detail": "周期没有开"}, status_code=409)

    @app.get("/api/cycles")
    async def read(user_id: UserId, device_timezone: DeviceTimezone = None) -> dict:
        """Today, and every character's records and estimate; or only that cycles are off."""
        view = await records.read(user_id, device_timezone)
        return view.shown() if view is not None else {"enabled": False}

    @app.post("/api/cycles/{character_id}/records")
    async def add(
        character_id: str,
        body: RecordInput,
        user_id: UserId,
        device_timezone: DeviceTimezone = None,
    ) -> dict:
        """Write down a period of hers: her records and estimate after."""
        return (await records.add(
            user_id, character_id, body.first_day, body.days, device_timezone
        )).shown()

    @app.put("/api/cycles/records/{record_id}")
    async def change(
        record_id: str, body: RecordInput, user_id: UserId, device_timezone: DeviceTimezone = None
    ) -> dict:
        """Change a record: its character's records and estimate after."""
        return (await records.change(
            user_id, record_id, body.first_day, body.days, device_timezone
        )).shown()

    @app.delete("/api/cycles/records/{record_id}")
    async def remove(
        record_id: str, user_id: UserId, device_timezone: DeviceTimezone = None
    ) -> dict:
        """Delete a record: its character's records and estimate after."""
        return (await records.remove(user_id, record_id, device_timezone)).shown()

    if backend.settings.dev_login:
        _add_dev_routes(app, backend)


def _add_dev_routes(app: FastAPI, backend: Backend) -> None:
    def character_or_404(character_id: str) -> str:
        if character_id not in backend.characters:
            raise HTTPException(404, "角色不存在")
        return character_id

    @app.put("/api/dev/cycles/{character_id}", status_code=204)
    async def force(character_id: str, body: ForcedInput, user_id: UserId) -> None:
        """Have the user's character where `body` says from now on (development only)."""
        backend.cycles.force(
            user_id, character_or_404(character_id), Forced(body.phase, body.day)
        )

    @app.delete("/api/dev/cycles/{character_id}", status_code=204)
    async def clear(character_id: str, user_id: UserId) -> None:
        """Have the user's character where her true cycle has her again (development only)."""
        backend.cycles.force(user_id, character_or_404(character_id), None)
