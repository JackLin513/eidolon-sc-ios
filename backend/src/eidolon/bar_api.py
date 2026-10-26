"""The bar over HTTP (GLOSSARY.md「酒吧」), for users who agreed to the terms: `/api/bar`
reads it, the drink catalog the bar counter and the recipe book are drawn from; or, while
the bar is closed, only that."""

from fastapi import FastAPI

from eidolon.assembly import Backend
from eidolon.sessions import UserId


def add_bar_routes(app: FastAPI, backend: Backend) -> None:
    config, drink_catalog = backend.config, backend.drink_catalog

    @app.get("/api/bar")
    async def read(_: UserId) -> dict:
        """Whether the bar is open and, if it is, its drinks in catalog order."""
        if not config.bar_on:
            return {"enabled": False}
        return {"enabled": True, "drinks": drink_catalog.described()}
