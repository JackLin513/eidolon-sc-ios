"""管理接口（spec #122）：账号、邀请码、公告、重新扫描包目录。

每个接口都先过 `admin` 这一关；普通账号调它就是 403。三条自我保护的规则也在这里，
不放给界面：不能停用自己、不能删除自己、不能让最后一个管理员消失。
"""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from .auth import hash_password, new_invite_code
from .db import now
from .packages import sync
from .session import current_user, database, require_admin
from .settings import MIN_PASSWORD

router = APIRouter(prefix="/v1/admin")

DEFAULT_INVITE_DAYS = 7


class InviteRequest(BaseModel):
    days: int = Field(default=DEFAULT_INVITE_DAYS, ge=1, le=365)


class PasswordRequest(BaseModel):
    password: str


class AnnouncementRequest(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    body: str = Field(min_length=1)


def admin(user: sqlite3.Row = Depends(current_user)) -> sqlite3.Row:
    return require_admin(user)


def _audit(db: sqlite3.Connection, actor: sqlite3.Row, action: str, target: str) -> None:
    db.execute(
        "INSERT INTO audit (at, actor, action, target) VALUES (?, ?, ?, ?)",
        (now(), actor["username"], action, target),
    )


def _target(db: sqlite3.Connection, user_id: int) -> sqlite3.Row:
    row = db.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="没有这个账号")
    return row


def _admins_left(db: sqlite3.Connection) -> int:
    return db.execute(
        "SELECT COUNT(*) AS n FROM users WHERE role = 'admin' AND disabled_at IS NULL"
    ).fetchone()["n"]


def _last_admin_guard(db: sqlite3.Connection, target: sqlite3.Row) -> None:
    if target["role"] == "admin" and _admins_left(db) <= 1:
        raise HTTPException(status_code=409, detail="至少要留一个能用的管理员")


# ---- 账号 ----


@router.get("/users")
def users(request: Request, user: sqlite3.Row = Depends(admin)) -> dict:
    db = database(request)
    try:
        rows = db.execute(
            "SELECT id, username, role, created_at, last_login_at, disabled_at"
            " FROM users ORDER BY id"
        ).fetchall()
        return {"users": [dict(row) for row in rows]}
    finally:
        db.close()


@router.post("/users/{user_id}/disable")
def disable(user_id: int, request: Request, user: sqlite3.Row = Depends(admin)) -> dict:
    db = database(request)
    try:
        target = _target(db, user_id)
        if target["id"] == user["id"]:
            raise HTTPException(status_code=409, detail="不能停用你自己")
        _last_admin_guard(db, target)
        db.execute("UPDATE users SET disabled_at = ? WHERE id = ?", (now(), user_id))
        # 停用不只是挡下一次登录：已经发出的令牌一起作废。
        db.execute("DELETE FROM tokens WHERE user_id = ?", (user_id,))
        _audit(db, user, "disable", target["username"])
        return {"ok": True}
    finally:
        db.close()


@router.post("/users/{user_id}/enable")
def enable(user_id: int, request: Request, user: sqlite3.Row = Depends(admin)) -> dict:
    db = database(request)
    try:
        target = _target(db, user_id)
        db.execute("UPDATE users SET disabled_at = NULL WHERE id = ?", (user_id,))
        _audit(db, user, "enable", target["username"])
        return {"ok": True}
    finally:
        db.close()


@router.post("/users/{user_id}/password")
def set_password(
    user_id: int,
    body: PasswordRequest,
    request: Request,
    user: sqlite3.Row = Depends(admin),
) -> dict:
    if len(body.password) < MIN_PASSWORD:
        raise HTTPException(status_code=400, detail=f"密码至少 {MIN_PASSWORD} 位")
    db = database(request)
    try:
        target = _target(db, user_id)
        db.execute(
            "UPDATE users SET password_hash = ? WHERE id = ?",
            (hash_password(body.password), user_id),
        )
        # 密码换了，旧令牌不该再能用。
        db.execute("DELETE FROM tokens WHERE user_id = ?", (user_id,))
        _audit(db, user, "password", target["username"])
        return {"ok": True}
    finally:
        db.close()


@router.delete("/users/{user_id}")
def delete_user(user_id: int, request: Request, user: sqlite3.Row = Depends(admin)) -> dict:
    db = database(request)
    try:
        target = _target(db, user_id)
        if target["id"] == user["id"]:
            raise HTTPException(status_code=409, detail="不能删除你自己")
        _last_admin_guard(db, target)
        db.execute("DELETE FROM tokens WHERE user_id = ?", (user_id,))
        db.execute("UPDATE invites SET used_by = NULL WHERE used_by = ?", (user_id,))
        db.execute("DELETE FROM users WHERE id = ?", (user_id,))
        _audit(db, user, "delete", target["username"])
        return {"ok": True}
    finally:
        db.close()


# ---- 邀请码 ----


@router.get("/invites")
def invites(request: Request, user: sqlite3.Row = Depends(admin)) -> dict:
    db = database(request)
    try:
        rows = db.execute(
            "SELECT i.*, u.username AS used_by_name FROM invites i"
            " LEFT JOIN users u ON u.id = i.used_by ORDER BY i.id DESC"
        ).fetchall()
        return {"invites": [_invite(row) for row in rows]}
    finally:
        db.close()


@router.post("/invites")
def create_invite(
    request: Request,
    body: InviteRequest | None = None,
    user: sqlite3.Row = Depends(admin),
) -> dict:
    days = (body or InviteRequest()).days
    expires = (datetime.now(UTC) + timedelta(days=days)).replace(microsecond=0)
    code = new_invite_code()
    db = database(request)
    try:
        cursor = db.execute(
            "INSERT INTO invites (code, created_at, expires_at) VALUES (?, ?, ?)",
            (code, now(), expires.isoformat()),
        )
        _audit(db, user, "invite", code)
        row = db.execute(
            "SELECT i.*, u.username AS used_by_name FROM invites i"
            " LEFT JOIN users u ON u.id = i.used_by WHERE i.id = ?",
            (cursor.lastrowid,),
        ).fetchone()
        return _invite(row)
    finally:
        db.close()


@router.delete("/invites/{invite_id}")
def revoke_invite(
    invite_id: int, request: Request, user: sqlite3.Row = Depends(admin)
) -> dict:
    db = database(request)
    try:
        row = db.execute("SELECT * FROM invites WHERE id = ?", (invite_id,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="没有这个邀请码")
        if row["used_at"] is not None:
            raise HTTPException(status_code=409, detail="这个邀请码已经用掉了，作废没有意义")
        db.execute("DELETE FROM invites WHERE id = ?", (invite_id,))
        _audit(db, user, "revoke", row["code"])
        return {"ok": True}
    finally:
        db.close()


def _invite(row: sqlite3.Row) -> dict:
    """未用 / 已用 / 过期——界面照着这个说，不自己再算一遍。"""
    if row["used_at"] is not None:
        state = "used"
    elif row["expires_at"] is not None and row["expires_at"] <= now():
        state = "expired"
    else:
        state = "open"
    return {
        "id": row["id"],
        "code": row["code"],
        "created_at": row["created_at"],
        "expires_at": row["expires_at"],
        "used_at": row["used_at"],
        "used_by": row["used_by_name"],
        "state": state,
    }


# ---- 公告 ----


@router.post("/announcements")
def publish(
    body: AnnouncementRequest, request: Request, user: sqlite3.Row = Depends(admin)
) -> dict:
    db = database(request)
    try:
        cursor = db.execute(
            "INSERT INTO announcements (title, body, published_at) VALUES (?, ?, ?)",
            (body.title.strip(), body.body.strip(), now()),
        )
        _audit(db, user, "announce", body.title.strip())
        return {"id": cursor.lastrowid}
    finally:
        db.close()


@router.delete("/announcements/{announcement_id}")
def unpublish(
    announcement_id: int, request: Request, user: sqlite3.Row = Depends(admin)
) -> dict:
    db = database(request)
    try:
        row = db.execute(
            "SELECT * FROM announcements WHERE id = ?", (announcement_id,)
        ).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="没有这条公告")
        db.execute("DELETE FROM announcements WHERE id = ?", (announcement_id,))
        _audit(db, user, "unannounce", row["title"])
        return {"ok": True}
    finally:
        db.close()


# ---- 包目录 ----


@router.post("/packages/rescan")
def rescan(request: Request, user: sqlite3.Row = Depends(admin)) -> dict:
    db = database(request)
    try:
        changed = sync(db, request.app.state.settings.packages, force=True)
        _audit(db, user, "rescan", f"{changed} 个包")
        return {"ok": True, "changed": changed}
    finally:
        db.close()
