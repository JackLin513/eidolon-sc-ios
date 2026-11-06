"""服务端的接口测试（spec #120）：注册、登录、下载、公告。"""

from __future__ import annotations

import hashlib
from datetime import UTC, datetime

from fastapi.testclient import TestClient

from conftest import PASSWORD, login, register
from eidolon_server.auth import hash_password
from eidolon_server.db import connect
from eidolon_server.main import create_app


def test_health_needs_no_token(client: TestClient) -> None:
    assert client.get("/v1/health").json() == {"ok": True}


def test_an_invite_opens_an_account_once(client: TestClient) -> None:
    register(client)
    token = login(client)
    assert token

    again = client.post(
        "/v1/register", json={"invite": "GOODCODE", "username": "other", "password": PASSWORD}
    )
    assert again.status_code == 409
    assert "用过" in again.json()["detail"]


def test_an_expired_invite_registers_nobody(client: TestClient) -> None:
    response = client.post(
        "/v1/register", json={"invite": "OLDCODE", "username": "jack", "password": PASSWORD}
    )
    assert response.status_code == 409
    assert "过期" in response.json()["detail"]


def test_a_short_password_is_refused(client: TestClient) -> None:
    response = client.post(
        "/v1/register", json={"invite": "GOODCODE", "username": "jack", "password": "short"}
    )
    assert response.status_code == 400


def test_wrong_passwords_lock_the_account_for_a_while(client: TestClient) -> None:
    register(client)
    for _ in range(5):
        assert client.post(
            "/v1/login", json={"username": "jack", "password": "wrong-one"}
        ).status_code == 401
    locked = client.post("/v1/login", json={"username": "jack", "password": PASSWORD})
    assert locked.status_code == 429


def test_the_package_list_needs_a_token(client: TestClient) -> None:
    assert client.get("/v1/packages").status_code == 401


def test_a_download_answers_a_range_with_just_those_bytes(client: TestClient, settings) -> None:
    register(client)
    token = login(client)
    settings.packages.mkdir(parents=True, exist_ok=True)
    payload = bytes(range(256)) * 8
    (settings.packages / "stand-2026-11-06.eidolonpkg").write_bytes(payload)

    connection = connect(settings.database)
    connection.execute(
        "INSERT INTO packages (kind, version, filename, size, sha256, created_at, current)"
        " VALUES (?, ?, ?, ?, ?, ?, 1)",
        (
            "stand",
            "2026-11-06",
            "stand-2026-11-06.eidolonpkg",
            len(payload),
            hashlib.sha256(payload).hexdigest(),
            datetime.now(UTC).replace(microsecond=0).isoformat(),
        ),
    )
    package_id = connection.execute("SELECT id FROM packages").fetchone()["id"]
    connection.close()

    headers = {"Authorization": f"Bearer {token}"}
    whole = client.get(f"/v1/packages/{package_id}/download", headers=headers)
    assert whole.status_code == 200
    assert whole.content == payload

    partial = client.get(
        f"/v1/packages/{package_id}/download", headers={**headers, "Range": "bytes=100-"}
    )
    assert partial.status_code == 206
    assert partial.headers["content-range"] == f"bytes 100-{len(payload) - 1}/{len(payload)}"
    assert partial.content == payload[100:]

    beyond = client.get(
        f"/v1/packages/{package_id}/download",
        headers={**headers, "Range": f"bytes={len(payload)}-"},
    )
    assert beyond.status_code == 416


def test_announcements_come_after_the_cursor(client: TestClient, settings) -> None:
    register(client)
    token = login(client)
    connection = connect(settings.database)
    for title in ("第一条", "第二条"):
        connection.execute(
            "INSERT INTO announcements (title, body, published_at) VALUES (?, ?, ?)",
            (title, "正文", datetime.now(UTC).replace(microsecond=0).isoformat()),
        )
    connection.close()

    headers = {"Authorization": f"Bearer {token}"}
    everything = client.get("/v1/announcements", headers=headers).json()
    assert [item["title"] for item in everything["announcements"]] == ["第一条", "第二条"]
    assert everything["latest"] == 2

    newer = client.get("/v1/announcements?since=1", headers=headers).json()
    assert [item["title"] for item in newer["announcements"]] == ["第二条"]


def test_a_disabled_account_cannot_log_in(client: TestClient, settings) -> None:
    register(client)
    connection = connect(settings.database)
    connection.execute("UPDATE users SET disabled_at = ? WHERE username = ?", ("2026-01-01T00:00:00+00:00", "jack"))
    connection.close()
    response = client.post("/v1/login", json={"username": "jack", "password": PASSWORD})
    assert response.status_code == 403


def test_the_role_comes_back_with_the_login(client: TestClient, settings) -> None:
    register(client)
    connection = connect(settings.database)
    connection.execute("UPDATE users SET role = 'admin' WHERE username = 'jack'")
    connection.close()
    response = client.post("/v1/login", json={"username": "jack", "password": PASSWORD})
    assert response.json()["role"] == "admin"


def test_the_admin_can_be_created_from_the_environment(settings) -> None:
    from dataclasses import replace

    create_app(replace(settings, admin_username="jack", admin_password=PASSWORD))
    client = TestClient(create_app(settings))
    response = client.post("/v1/login", json={"username": "jack", "password": PASSWORD})
    assert response.status_code == 200
    assert response.json()["role"] == "admin"


def test_a_second_start_does_not_reset_the_admin_password(settings) -> None:
    from dataclasses import replace

    create_app(replace(settings, admin_username="jack", admin_password=PASSWORD))
    changed = "another-one"
    connection = connect(settings.database)
    connection.execute(
        "UPDATE users SET password_hash = ? WHERE username = ?",
        (hash_password(changed), "jack"),
    )
    connection.close()

    create_app(replace(settings, admin_username="jack", admin_password=PASSWORD))
    client = TestClient(create_app(settings))
    assert client.post("/v1/login", json={"username": "jack", "password": changed}).status_code == 200
    assert client.post("/v1/login", json={"username": "jack", "password": PASSWORD}).status_code == 401


def test_an_existing_account_is_promoted_not_recreated(settings) -> None:
    from dataclasses import replace

    client = TestClient(create_app(settings))
    connection = connect(settings.database)
    connection.execute(
        "INSERT INTO invites (code, created_at, expires_at) VALUES ('ONLYONE', ?, NULL)",
        (datetime.now(UTC).replace(microsecond=0).isoformat(),),
    )
    connection.close()
    client.post("/v1/register", json={"invite": "ONLYONE", "username": "jack", "password": PASSWORD})

    create_app(replace(settings, admin_username="jack", admin_password=PASSWORD))
    login = TestClient(create_app(settings)).post(
        "/v1/login", json={"username": "jack", "password": PASSWORD}
    )
    assert login.json()["role"] == "admin"


def test_a_bundle_in_the_folder_is_registered_on_start(settings) -> None:
    settings.packages.mkdir(parents=True, exist_ok=True)
    (settings.packages / "content-2026-11-06.eidolonpkg").write_bytes(b"x" * 128)

    create_app(settings)
    connection = connect(settings.database)
    row = connection.execute("SELECT * FROM packages").fetchone()
    connection.close()
    assert row["kind"] == "content"
    assert row["version"] == "2026-11-06"
    assert row["size"] == 128
    assert row["current"] == 1


def test_a_bundle_that_is_already_registered_is_left_alone(settings) -> None:
    from eidolon_server.packages import register, sync

    settings.packages.mkdir(parents=True, exist_ok=True)
    path = settings.packages / "stand-2026-11-06.eidolonpkg"
    path.write_bytes(b"y" * 64)
    connection = connect(settings.database)
    assert register(connection, path) is True
    assert register(connection, path) is False       # 大小没变，不重算
    path.write_bytes(b"y" * 96)
    assert register(connection, path) is True        # 换了大小的包要重算
    assert sync(connection, settings.packages) == 0
    connection.close()


def test_a_bundle_that_was_deleted_is_forgotten(settings) -> None:
    from eidolon_server.packages import sync

    settings.packages.mkdir(parents=True, exist_ok=True)
    path = settings.packages / "bar-2026-10-30.eidolonpkg"
    path.write_bytes(b"z" * 32)
    connection = connect(settings.database)
    sync(connection, settings.packages)
    assert connection.execute("SELECT COUNT(*) AS n FROM packages").fetchone()["n"] == 1

    path.unlink()
    sync(connection, settings.packages)
    assert connection.execute("SELECT COUNT(*) AS n FROM packages").fetchone()["n"] == 0
    connection.close()
