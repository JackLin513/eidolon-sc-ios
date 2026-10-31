"""Moments over HTTP (GLOSSARY.md「朋友圈」): `/api/moments` reads the signed-in user's
timeline, the latest first, all of it at once; `/api/moments/{id}/image` the picture of one
on it (GLOSSARY.md「配图」, ADR-0024), the user's alone to read: to anyone else, admins too,
there is no such picture (404), and it is the browser's alone to keep, never a shared cache's.
While the deployer has moments off, each is refused with 409."""

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import JSONResponse

from eidolon.assembly import Backend
from eidolon.moments import MomentsOff
from eidolon.sessions import UserId


_PICTURE_CACHE = {"Cache-Control": "private, max-age=31536000, immutable"}
"""A moment's picture never changes once posted."""


def add_moment_routes(app: FastAPI, backend: Backend) -> None:
    @app.exception_handler(MomentsOff)
    async def moments_off(_: Request, e: MomentsOff) -> JSONResponse:
        return JSONResponse({"detail": "朋友圈没有开放"}, status_code=409)

    @app.get("/api/moments")
    async def timeline(user_id: UserId) -> dict:
        """The user's moments that have shown within the last 30 days, the latest first."""
        map_site = backend.moments.map_site
        return {"moments": [m.shown(map_site) for m in await backend.moments.timeline(user_id)]}

    @app.get("/api/moments/{moment_id}/image")
    async def read_picture(moment_id: int, user_id: UserId) -> Response:
        image = await backend.moments.picture(user_id, moment_id)
        if image is None:
            raise HTTPException(404, "配图不存在")
        return Response(image, media_type="image/webp", headers=_PICTURE_CACHE)
