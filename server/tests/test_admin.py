"""管理接口的测试（spec #122）：账号、邀请码、公告、重新扫描。"""

from __future__ import annotations

from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient
from fastapi import HTTPException

from conftest import PASSWORD, headers, login, make_admin, register
from eidolon_server.admin import _last_admin_guard
from eidolon_server.db import connect

ADMIN_PATHS = [
    ("GET", "/v1/admin/users"),
    ("POST", "/v1/admin/users/1/disable"),
    ("POST", "/v1/admin/users/1/enable"),
    ("POST", "/v1/admin/users/1/password"),
    ("DELETE", "/v1/admin/users/1"),
    ("GET", "/v1/admin/invites"),
    ("POST", "/v1/admin/invites"),
    ("DELETE", "/v1/admin/invites/1"),
    ("POST", "/v1/admin/announcements"),
    ("DELETE", "/v1/admin/announcements/1"),
    ("POST", "/v1/admin/packages/rescan"),
]


def sign_in(client: TestClient) -> str:
    register(client)
    token = login(client)
    return token


def admin_token(client: TestClient, db) -> str:
    token = sign_in(client)
    make_admin(db)
    return login(client)


def second_account(client: TestClient, username: str = "alice") -> str:
    connection = connect(client.app.state.settings.database)
    connection.execute(
        "INSERT INTO invites (code, created_at, expires_at) VALUES (?, ?, NULL)",
        (f"CODE{username.upper()}", datetime.now(UTC).replace(microsecond=0).isoformat()),
    )
    connection.close()
    register(client, invite=f"CODE{username.upper()}", username=username)
    return login(client, username=username)


@pytest.mark.parametrize("method,path", ADMIN_PATHS)
def test_a_normal_account_is_refused_everywhere(
    client: TestClient, db, method: str, path: str
) -> None:
    token = sign_in(client)
    response = client.request(method, path, headers=headers(token), json={"password": PASSWORD})
    assert response.status_code == 403, response.text
    assert response.headers["x-eidolon-reason"] == "forbidden"


def test_the_user_list_shows_who_is_where(client: TestClient, db) -> None:
    token = admin_token(client, db)
    second_account(client)
    everyone = client.get("/v1/admin/users", headers=headers(token)).json()["users"]
    assert [user["username"] for user in everyone] == ["jack", "alice"]
    assert [user["role"] for user in everyone] == ["admin", "user"]
    assert everyone[1]["disabled_at"] is None


def test_disabling_an_account_kills_its_token_at_once(client: TestClient, db) -> None:
    token = admin_token(client, db)
    alice = second_account(client)
    alice_id = _id(client, "alice")

    assert client.post(f"/v1/admin/users/{alice_id}/disable", headers=headers(token)).status_code == 200

    # 还没过期的旧令牌立刻作废，而不是等它自然过期。
    assert client.get("/v1/packages", headers=headers(alice)).status_code == 401
    refused = client.post("/v1/login", json={"username": "alice", "password": PASSWORD})
    assert refused.status_code == 403
    assert refused.headers["x-eidolon-reason"] == "disabled"

    client.post(f"/v1/admin/users/{alice_id}/enable", headers=headers(token))
    assert client.get("/v1/packages", headers=headers(login(client, "alice"))).status_code == 200


def test_an_admin_cannot_lock_themselves_out(client: TestClient, db) -> None:
    token = admin_token(client, db)
    jack = _id(client, "jack")
    for method, path in [
        ("POST", f"/v1/admin/users/{jack}/disable"),
        ("DELETE", f"/v1/admin/users/{jack}"),
    ]:
        response = client.request(method, path, headers=headers(token))
        assert response.status_code == 409, response.text
        assert "你自己" in response.json()["detail"]


def test_the_last_admin_is_never_removed(client: TestClient, db) -> None:
    admin_token(client, db)
    connection = connect(client.app.state.settings.database)
    row = connection.execute("SELECT * FROM users WHERE username = 'jack'").fetchone()
    try:
        # 自我保护会先拦住「对自己下手」；这条规则是那之外的第二道闸。
        with pytest.raises(HTTPException) as refused:
            _last_admin_guard(connection, row)
        assert refused.value.status_code == 409
    finally:
        connection.close()


def test_a_new_password_signs_the_old_sessions_out(client: TestClient, db) -> None:
    token = admin_token(client, db)
    alice = second_account(client)
    alice_id = _id(client, "alice")

    response = client.post(
        f"/v1/admin/users/{alice_id}/password",
        headers=headers(token),
        json={"password": "brand-new-one"},
    )
    assert response.status_code == 200
    assert client.get("/v1/packages", headers=headers(alice)).status_code == 401
    assert client.post(
        "/v1/login", json={"username": "alice", "password": "brand-new-one"}
    ).status_code == 200


def test_a_short_password_is_still_refused(client: TestClient, db) -> None:
    token = admin_token(client, db)
    alice_id = _id(client, "alice") if second_account(client) else 0
    response = client.post(
        f"/v1/admin/users/{alice_id}/password", headers=headers(token), json={"password": "short"}
    )
    assert response.status_code == 400


def test_deleting_an_account_takes_its_tokens_with_it(client: TestClient, db) -> None:
    token = admin_token(client, db)
    alice = second_account(client)
    alice_id = _id(client, "alice")

    assert client.delete(f"/v1/admin/users/{alice_id}", headers=headers(token)).status_code == 200
    assert client.get("/v1/packages", headers=headers(alice)).status_code == 401
    assert client.post("/v1/login", json={"username": "alice", "password": PASSWORD}).status_code == 401


def test_an_invite_the_admin_creates_opens_exactly_one_account(client: TestClient, db) -> None:
    token = admin_token(client, db)
    created = client.post(
        "/v1/admin/invites", headers=headers(token), json={"days": 3}
    ).json()
    assert created["state"] == "open"
    assert created["used_by"] is None

    register(client, invite=created["code"], username="alice")
    listed = client.get("/v1/admin/invites", headers=headers(token)).json()["invites"]
    assert [item["state"] for item in listed[:1]] == ["used"]
    assert listed[0]["used_by"] == "alice"


def test_a_revoked_invite_registers_nobody(client: TestClient, db) -> None:
    token = admin_token(client, db)
    created = client.post("/v1/admin/invites", headers=headers(token), json={}).json()
    assert client.delete(
        f"/v1/admin/invites/{created['id']}", headers=headers(token)
    ).status_code == 200
    refused = client.post(
        "/v1/register",
        json={"invite": created["code"], "username": "alice", "password": PASSWORD},
    )
    assert refused.status_code == 409


def test_an_expired_invite_reads_as_expired(client: TestClient, db) -> None:
    token = admin_token(client, db)
    connection = connect(client.app.state.settings.database)
    connection.execute(
        "INSERT INTO invites (code, created_at, expires_at) VALUES (?, ?, ?)",
        ("OLDONE", "2026-01-01T00:00:00+00:00", "2026-01-02T00:00:00+00:00"),
    )
    connection.close()
    listed = client.get("/v1/admin/invites", headers=headers(token)).json()["invites"]
    assert listed[0]["state"] == "expired"


def test_a_published_announcement_reaches_normal_accounts(client: TestClient, db) -> None:
    token = admin_token(client, db)
    alice = second_account(client)
    published = client.post(
        "/v1/admin/announcements",
        headers=headers(token),
        json={"title": "新包", "body": "立绘包更新了"},
    )
    assert published.status_code == 200

    read = client.get("/v1/announcements", headers=headers(alice)).json()["announcements"]
    assert [item["title"] for item in read] == ["新包"]

    assert client.delete(
        f"/v1/admin/announcements/{published.json()['id']}", headers=headers(token)
    ).status_code == 200
    assert client.get("/v1/announcements", headers=headers(alice)).json()["announcements"] == []


def test_rescanning_picks_up_a_new_bundle(client: TestClient, db) -> None:
    token = admin_token(client, db)
    packages = client.app.state.settings.packages
    packages.mkdir(parents=True, exist_ok=True)
    (packages / "content-2026-11-06.eidolonpkg").write_bytes(b"x" * 64)

    result = client.post("/v1/admin/packages/rescan", headers=headers(token)).json()
    assert result["changed"] == 1
    assert [item["filename"] for item in client.get("/v1/packages", headers=headers(token)).json()["packages"]] == [
        "content-2026-11-06.eidolonpkg"
    ]


def test_the_admin_actions_leave_a_trail(client: TestClient, db) -> None:
    token = admin_token(client, db)
    alice_id = _id(client, "alice") if second_account(client) else 0
    client.post(f"/v1/admin/users/{alice_id}/disable", headers=headers(token))
    client.post("/v1/admin/invites", headers=headers(token), json={})
    client.post(
        "/v1/admin/announcements", headers=headers(token), json={"title": "标题", "body": "正文"}
    )

    connection = connect(client.app.state.settings.database)
    try:
        rows = connection.execute("SELECT * FROM audit ORDER BY id").fetchall()
    finally:
        connection.close()
    assert [(row["actor"], row["action"]) for row in rows] == [
        ("jack", "disable"),
        ("jack", "invite"),
        ("jack", "announce"),
    ]
    assert rows[0]["target"] == "alice"


def _id(client: TestClient, username: str) -> int:
    connection = connect(client.app.state.settings.database)
    try:
        return connection.execute(
            "SELECT id FROM users WHERE username = ?", (username,)
        ).fetchone()["id"]
    finally:
        connection.close()
