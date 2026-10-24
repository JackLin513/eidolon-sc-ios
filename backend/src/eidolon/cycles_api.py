"""Forcing where her cycle has her, for development only (`EIDOLON_DEV_LOGIN=1`): at
`/api/dev/cycles/{character_id}`, PUT has the signed-in user's character in her period on
day `day`, premenstrual with `day` days left, or neither, whatever the day; DELETE has her
where her true cycle has her again. Kept in memory, gone as the server restarts; the
switches still hold. Without development sign-in, there is no such route."""

from typing import Literal, Self

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, model_validator

from eidolon.assembly import Backend
from eidolon.cycles import Forced
from eidolon.her_cycle import LONGEST_PERIOD, PREMENSTRUAL_DAYS
from eidolon.sessions import UserId


class ForcedInput(BaseModel):
    phase: Literal["period", "premenstrual", "neither"]
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
    if not backend.settings.dev_login:
        return

    def character_or_404(character_id: str) -> str:
        if character_id not in backend.characters:
            raise HTTPException(404, "角色不存在")
        return character_id

    @app.put("/api/dev/cycles/{character_id}", status_code=204)
    async def force(character_id: str, body: ForcedInput, user_id: UserId) -> None:
        """Have the user's character where `body` says from now on (development only)."""
        forced = Forced(body.phase, body.day if body.phase != "neither" else 0)
        backend.cycles.force(user_id, character_or_404(character_id), forced)

    @app.delete("/api/dev/cycles/{character_id}", status_code=204)
    async def clear(character_id: str, user_id: UserId) -> None:
        """Have the user's character where her true cycle has her again (development only)."""
        backend.cycles.force(user_id, character_or_404(character_id), None)
