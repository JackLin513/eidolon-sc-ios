"""Letters over HTTP (GLOSSARY.md「信」): `/api/letters` lists the signed-in user's letters,
the latest first; `/api/letters/{id}` reads one; `/api/letters/{id}/read` has it read (PUT),
on every device. Another's letter, or none, is none (404), to admins too. Whether the
deployer has letters on or off, the letters written stay to be read."""

from fastapi import FastAPI, HTTPException

from eidolon.assembly import Backend
from eidolon.sessions import UserId


def add_letter_routes(app: FastAPI, backend: Backend) -> None:
    @app.get("/api/letters")
    async def letters(user_id: UserId) -> dict:
        """The user's letters, the latest first."""
        return {"letters": [each.shown() for each in await backend.letters.listed(user_id)]}

    @app.get("/api/letters/{letter_id}")
    async def letter(letter_id: int, user_id: UserId) -> dict:
        found = await backend.letters.letter(user_id, letter_id)
        if found is None:
            raise HTTPException(404, "信不存在")
        return found.shown()

    @app.put("/api/letters/{letter_id}/read", status_code=204)
    async def mark_read(letter_id: int, user_id: UserId) -> None:
        if not await backend.letters.mark_read(user_id, letter_id):
            raise HTTPException(404, "信不存在")
