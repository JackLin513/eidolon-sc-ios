"""Moments over HTTP (GLOSSARY.md「朋友圈」): `/api/moments` reads the signed-in user's
timeline, the latest first, all of it at once. While the deployer has moments off, it is
refused with 409."""

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from eidolon.assembly import Backend
from eidolon.moments import MomentsOff
from eidolon.sessions import UserId


def add_moment_routes(app: FastAPI, backend: Backend) -> None:
    @app.exception_handler(MomentsOff)
    async def moments_off(_: Request, e: MomentsOff) -> JSONResponse:
        return JSONResponse({"detail": "朋友圈没有开放"}, status_code=409)

    @app.get("/api/moments")
    async def timeline(user_id: UserId) -> dict:
        """The user's moments that have shown within the last 30 days, the latest first."""
        map_site = backend.moments.map_site
        return {"moments": [m.shown(map_site) for m in await backend.moments.timeline(user_id)]}
