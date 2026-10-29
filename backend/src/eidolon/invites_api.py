"""Invite links over HTTP (GLOSSARY.md「邀请链接」): admins list, make and delete them under
`/api/admin/invites`, which answers 404 to anyone else as the rest of the admin console does.
Each is shown with its address, whether it can still be used, and who signed up through it.
They are made whatever the deployment's way of signing up (GLOSSARY.md「注册方式」), but only
asked for while only those invited may sign up."""

from datetime import timedelta
from typing import Literal

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from eidolon.admin_api import Admin
from eidolon.assembly import Backend
from eidolon.invites import MAX_USES, Invite


class InviteInput(BaseModel):
    note: str | None = Field(None, max_length=100)
    """For whom, or where it was sent; for the admins only."""
    max_uses: int = Field(1, ge=1, le=MAX_USES)
    lifetime_days: Literal[1, 7, 30] | None = 7
    """How many days it can be used for; None for ever."""


def add_invite_routes(app: FastAPI, backend: Backend) -> None:
    invites, settings, clock = backend.invites, backend.settings, backend.clock

    def described(invite: Invite) -> dict:
        return {
            "id": invite.id,
            "link": f"{settings.public_origin}/login?invite={invite.code}",
            "note": invite.note,
            "max_uses": invite.max_uses,
            "used": invite.used,
            "expires_at": invite.expires_at,
            "created_at": invite.created_at,
            "state": invite.state(clock()),
            "invited": [{"id": i.user_id, "name": i.name} for i in invite.invited],
        }

    @app.get("/api/admin/invites")
    async def list_invites(_: Admin) -> dict:
        """Every link, the newest first."""
        return {"invites": [described(i) for i in await invites.all()]}

    @app.post("/api/admin/invites", status_code=201)
    async def create_invite(body: InviteInput, _: Admin) -> dict:
        """A new link, the note trimmed, an empty one none."""
        lifetime = None if body.lifetime_days is None else timedelta(days=body.lifetime_days)
        return described(
            await invites.create((body.note or "").strip() or None, body.max_uses, lifetime)
        )

    @app.delete("/api/admin/invites/{invite_id}", status_code=204)
    async def delete_invite(invite_id: int, _: Admin) -> None:
        """Delete the link, at once unusable; those who signed up through it stay users."""
        if not await invites.delete(invite_id):
            raise HTTPException(404, "没有这条邀请链接")
