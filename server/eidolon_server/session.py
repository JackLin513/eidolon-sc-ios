"""谁在请求：令牌换成账号，以及管理接口的角色校验（spec #122）。

管理接口和普通接口共用一套令牌；角色由服务端自己判断，界面上藏不藏只是体验。
"""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime, timedelta

from fastapi import Header, HTTPException, Request

from .auth import TOKEN_LIFETIME_DAYS, hash_token
from .db import connect, now


def database(request: Request) -> sqlite3.Connection:
    return connect(request.app.state.settings.database)


def current_user(
    request: Request, authorization: str | None = Header(default=None)
) -> sqlite3.Row:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="需要登录")
    token = authorization.split(" ", 1)[1].strip()
    db = database(request)
    try:
        row = db.execute(
            "SELECT t.id AS token_id, t.expires_at, u.* FROM tokens t"
            " JOIN users u ON u.id = t.user_id WHERE t.token_hash = ?",
            (hash_token(token),),
        ).fetchone()
        if row is None or row["expires_at"] <= now():
            raise HTTPException(status_code=401, detail="登录已过期，请重新登录")
        if row["disabled_at"] is not None:
            raise HTTPException(
                status_code=403,
                detail="这个账号已经停用了",
                headers={"X-Eidolon-Reason": "disabled"},
            )
        # 滑窗：用一次就往后延一次。
        db.execute(
            "UPDATE tokens SET last_used_at = ?, expires_at = ? WHERE id = ?",
            (
                now(),
                (datetime.now(UTC) + timedelta(days=TOKEN_LIFETIME_DAYS)).replace(
                    microsecond=0
                ).isoformat(),
                row["token_id"],
            ),
        )
        return row
    finally:
        db.close()


def require_admin(user: sqlite3.Row) -> sqlite3.Row:
    if user["role"] != "admin":
        raise HTTPException(
            status_code=403,
            detail="这个账号没有管理权限",
            headers={"X-Eidolon-Reason": "forbidden"},
        )
    return user
