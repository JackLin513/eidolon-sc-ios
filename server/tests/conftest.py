"""两个测试文件共用的夹具（spec #120、#122）。"""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient

from eidolon_server.db import connect
from eidolon_server.main import create_app
from eidolon_server.settings import Settings

PASSWORD = "hunter22"


@pytest.fixture()
def settings(tmp_path) -> Settings:
    return Settings(database=tmp_path / "db.sqlite3", packages=tmp_path / "packages")


@pytest.fixture()
def db(settings) -> sqlite3.Connection:
    return connect(settings.database)


@pytest.fixture()
def client(settings, db) -> TestClient:
    stamp = datetime.now(UTC).replace(microsecond=0).isoformat()
    db.execute(
        "INSERT INTO invites (code, created_at, expires_at) VALUES (?, ?, ?)",
        ("GOODCODE", stamp, None),
    )
    db.execute(
        "INSERT INTO invites (code, created_at, expires_at) VALUES (?, ?, ?)",
        ("OLDCODE", "2026-01-01T00:00:00+00:00", "2026-01-08T00:00:00+00:00"),
    )
    return TestClient(create_app(settings))


def register(client: TestClient, invite: str = "GOODCODE", username: str = "jack") -> None:
    response = client.post(
        "/v1/register", json={"invite": invite, "username": username, "password": PASSWORD}
    )
    assert response.status_code == 200, response.text


def login(client: TestClient, username: str = "jack") -> str:
    response = client.post("/v1/login", json={"username": username, "password": PASSWORD})
    assert response.status_code == 200, response.text
    return response.json()["token"]


def make_admin(db: sqlite3.Connection, username: str = "jack") -> None:
    db.execute("UPDATE users SET role = 'admin' WHERE username = ?", (username,))


def headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}
