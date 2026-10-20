"""Gifts over HTTP (GLOSSARY.md「礼物」「抽奖」), for users who agreed to the terms: the
catalog at `/api/gifts/catalog`, what the user has at `/api/gifts`, and drawing at
`/api/gifts/draws`, the latter two having given the draw chances due today; giving one to
a character at `/api/characters/{id}/gifts`; using a reset card at `/api/gifts/resets`.
None says which gifts a character likes: the gifts page gives none of that away. Admins give every user a reset card at
`/api/admin/gifts/reset-card-grants`, which answers 404 to anyone else as the rest of the
admin console does. Gifts not open, drawing, giving, using a reset card and granting them
are refused with 409 and `gifts_closed`, told apart from a cooldown's 409, so the page shows
them closed."""

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from eidolon.admin_api import Admin
from eidolon.assembly import Backend
from eidolon.gifts import (
    GiftsClosed,
    NoDraws,
    NoneLeft,
    NoOneToReset,
    NoResetCards,
    NoSuchCharacter,
)
from eidolon.sessions import UserId


class DrawInput(BaseModel):
    all: bool = False
    """Draw every chance the user has, not just one."""


class GiftInput(BaseModel):
    gift_id: str


def add_gift_routes(app: FastAPI, backend: Backend) -> None:
    catalog, gifts, store = backend.gift_catalog, backend.gifts, backend.store
    happenings = backend.happenings

    @app.exception_handler(GiftsClosed)
    async def gifts_closed(_: Request, e: GiftsClosed) -> JSONResponse:
        return JSONResponse({"detail": str(e), "gifts_closed": True}, status_code=409)

    @app.exception_handler(NoDraws)
    @app.exception_handler(NoneLeft)
    @app.exception_handler(NoResetCards)
    @app.exception_handler(NoOneToReset)
    async def none_to_use(_: Request, e: Exception) -> JSONResponse:
        return JSONResponse({"detail": str(e)}, status_code=409)

    @app.get("/api/gifts/catalog")
    def read_catalog(_: UserId) -> list[dict]:
        """Every gift, retired ones too (whoever has one still sees it), in catalog order."""
        return [g.described() for g in catalog.values()]

    @app.get("/api/gifts")
    def read_state(user_id: UserId) -> dict:
        """What the user has, having been given the draw chances due today; whether gifts
        are open, and if so when the next chance is given and each character's affinity,
        for choosing whom to give to, and how far the user is with today's daily tasks."""
        daily_tasks = happenings.daily_tasks(user_id)
        return gifts.state(user_id).shown() | {
            "daily_tasks": daily_tasks and daily_tasks.shown()
        }

    @app.post("/api/gifts/draws")
    def draw(body: DrawInput, user_id: UserId) -> dict:
        """Draw once or every chance, having been given those due today: what each draw
        gave, in order, and how many chances are left."""
        return gifts.draw(user_id, all=body.all).shown()

    @app.post("/api/characters/{character_id}/gifts")
    def give(character_id: str, body: GiftInput, user_id: UserId) -> dict:
        """Give her one of the gift: where its record went, how her affinity changed, where
        it is now, how many of the gift are left, and what giving it was rewarded with (None
        if nothing). Not a turn: no limit or cooldown holds
        it, and the user need not bring their own LLM."""
        try:
            given = gifts.give(user_id, body.gift_id, character_id)
        except NoSuchCharacter as e:
            raise HTTPException(404, str(e)) from None
        rewarded = happenings.gift_given(user_id, character_id)
        return given.shown() | {"rewarded": rewarded and rewarded.shown()}

    @app.post("/api/gifts/resets")
    def use_reset_card(user_id: UserId) -> dict:
        """Use a reset card: whom it brought back to trust, and how many cards are left."""
        return gifts.use_reset_card(user_id).shown()

    @app.get("/api/admin/gifts")
    def read_admin_gifts(_: Admin) -> dict:
        """How many users there are now, each to be given a reset card; when they last were,
        and how many; and whether gifts are open."""
        last = gifts.last_grant()
        return {
            "users": len(store.list_users()),
            "last_grant": last and last.shown(),
            "open": backend.config.affinity_on,
        }

    @app.post("/api/admin/gifts/reset-card-grants")
    def grant_reset_cards(_: Admin) -> dict:
        """Give every user there is now a reset card: when, and how many were given."""
        return gifts.grant_reset_cards().shown()
