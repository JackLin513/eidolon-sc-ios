"""HTTP 接口（spec #120）。除了注册、登录和健康检查，全都要令牌。"""

from __future__ import annotations

import re
import sqlite3
from datetime import UTC, datetime, timedelta
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from .admin import router as admin_router
from .auth import (
    TOKEN_LIFETIME_DAYS,
    hash_password,
    hash_token,
    new_token,
    verify_password,
)
from .bootstrap import BootstrapError, ensure_admin
from .db import connect, now
from .packages import sync as sync_packages
from .session import current_user, database
from .settings import LOGIN_ATTEMPTS, LOGIN_LOCK_MINUTES, Settings

USERNAME = re.compile(r"^[A-Za-z0-9_.-]{3,32}$")


class Credentials(BaseModel):
    username: str
    password: str


class Registration(Credentials):
    invite: str = Field(min_length=4)


def create_app(settings: Settings) -> FastAPI:
    app = FastAPI(title="Eidolon server", docs_url=None, redoc_url=None)
    app.state.settings = settings

    # 包目录里有新文件就登记上：往文件夹里一放，重启一次就能在手机上下载，
    # 不用再上去敲 scan（那条命令还在，用来强制重算）。
    try:
        connection = connect(settings.database)
        try:
            sync_packages(connection, settings.packages)
        finally:
            connection.close()
    except OSError:
        # 目录还没建好不该挡住服务起来。
        pass

    # 第一次起来就把管理员建好；已经在的账号只升角色，不动密码。
    if settings.admin_username and settings.admin_password:
        db = connect(settings.database)
        try:
            ensure_admin(db, settings.admin_username, settings.admin_password)
        except BootstrapError as error:
            raise RuntimeError(f"管理员账号没建成：{error}") from error
        finally:
            db.close()

    # ---- 注册与登录 ----

    @app.post("/v1/register")
    def register(body: Registration, request: Request) -> dict:
        _check_username(body.username)
        _check_password(body.password)
        db = database(request)
        # 一个邀请码只能用一次：查和改在同一个写事务里，两个请求同时来也只会有一个成功。
        db.execute("BEGIN IMMEDIATE")
        try:
            invite = db.execute(
                "SELECT * FROM invites WHERE code = ?", (body.invite.strip().upper(),)
            ).fetchone()
            if invite is None:
                raise HTTPException(status_code=409, detail="邀请码不对")
            if invite["used_by"] is not None:
                raise HTTPException(status_code=409, detail="邀请码已经被用过了")
            if invite["expires_at"] is not None and invite["expires_at"] <= now():
                raise HTTPException(status_code=409, detail="邀请码已经过期")
            try:
                cursor = db.execute(
                    "INSERT INTO users (username, password_hash, created_at) VALUES (?, ?, ?)",
                    (body.username.strip(), hash_password(body.password), now()),
                )
            except sqlite3.IntegrityError:
                raise HTTPException(status_code=409, detail="这个用户名已经有人用了")
            claim = db.execute(
                "UPDATE invites SET used_by = ?, used_at = ? WHERE id = ? AND used_by IS NULL",
                (cursor.lastrowid, now(), invite["id"]),
            )
            if claim.rowcount != 1:
                raise HTTPException(status_code=409, detail="邀请码已经被用过了")
            db.execute("COMMIT")
            return {"username": body.username.strip()}
        except HTTPException:
            db.execute("ROLLBACK")
            raise
        except Exception:
            db.execute("ROLLBACK")
            raise
        finally:
            db.close()

    @app.post("/v1/login")
    def login(body: Credentials, request: Request) -> dict:
        keys = (
            f"user:{body.username.strip().lower()}",
            f"ip:{request.client.host if request.client else '-'}",
        )
        db = database(request)
        try:
            for key in keys:
                _guard_lockout(db, key)
            user = db.execute(
                "SELECT * FROM users WHERE username = ?", (body.username.strip(),)
            ).fetchone()
            if user is None or not verify_password(body.password, user["password_hash"]):
                for key in keys:
                    _record_failure(db, key)
                raise HTTPException(status_code=401, detail="用户名或密码不对")
            if user["disabled_at"] is not None:
                raise HTTPException(
                    status_code=403,
                    detail="这个账号已经停用了",
                    headers={"X-Eidolon-Reason": "disabled"},
                )
            for key in keys:
                db.execute("DELETE FROM login_failures WHERE key = ?", (key,))
            token = new_token()
            expires = (datetime.now(UTC) + timedelta(days=TOKEN_LIFETIME_DAYS)).replace(
                microsecond=0
            )
            db.execute(
                "INSERT INTO tokens (token_hash, user_id, created_at, expires_at)"
                " VALUES (?, ?, ?, ?)",
                (hash_token(token), user["id"], now(), expires.isoformat()),
            )
            db.execute("UPDATE users SET last_login_at = ? WHERE id = ?", (now(), user["id"]))
            return {
                "token": token,
                "username": user["username"],
                "role": user["role"],
                "expires_at": expires.isoformat(),
            }
        finally:
            db.close()

    @app.post("/v1/logout")
    def logout(request: Request, user: sqlite3.Row = Depends(current_user)) -> dict:
        db = database(request)
        try:
            db.execute("DELETE FROM tokens WHERE id = ?", (user["token_id"],))
        finally:
            db.close()
        return {"ok": True}

    # ---- 包 ----

    @app.get("/v1/packages")
    def packages(request: Request, user: sqlite3.Row = Depends(current_user)) -> dict:
        db = database(request)
        try:
            rows = db.execute(
                "SELECT id, kind, version, filename, size, sha256, created_at,"
                " CASE WHEN id = (SELECT p2.id FROM packages p2 WHERE p2.kind = packages.kind"
                "               ORDER BY p2.created_at DESC, p2.id DESC LIMIT 1)"
                "      THEN 1 ELSE 0 END AS current"
                " FROM packages ORDER BY kind, created_at DESC"
            ).fetchall()
            return {"packages": [dict(row) for row in rows]}
        finally:
            db.close()

    @app.get("/v1/packages/{package_id}/download")
    def download(
        package_id: int,
        request: Request,
        user: sqlite3.Row = Depends(current_user),
    ) -> StreamingResponse:
        db = database(request)
        try:
            row = db.execute("SELECT * FROM packages WHERE id = ?", (package_id,)).fetchone()
        finally:
            db.close()
        if row is None:
            raise HTTPException(status_code=404, detail="没有这个包")
        path = settings.packages / row["filename"]
        if not path.exists():
            raise HTTPException(status_code=404, detail="包文件不在服务器上")

        size = path.stat().st_size
        start, end = _parse_range(request.headers.get("range"), size)
        status = 206 if start > 0 or end < size - 1 else 200
        headers = {
            "Content-Length": str(end - start + 1),
            "Accept-Ranges": "bytes",
            "Content-Disposition": f'attachment; filename="{row["filename"]}"',
        }
        if status == 206:
            headers["Content-Range"] = f"bytes {start}-{end}/{size}"
        return StreamingResponse(
            _read(path, start, end), status_code=status, headers=headers,
            media_type="application/octet-stream",
        )

    # ---- 公告 ----

    @app.get("/v1/announcements")
    def announcements(
        request: Request, since: int = 0, user: sqlite3.Row = Depends(current_user)
    ) -> dict:
        db = database(request)
        try:
            rows = db.execute(
                "SELECT id, title, body, published_at FROM announcements"
                " WHERE id > ? ORDER BY id",
                (since,),
            ).fetchall()
            newest = db.execute("SELECT COALESCE(MAX(id), 0) AS id FROM announcements").fetchone()
            return {"announcements": [dict(row) for row in rows], "latest": newest["id"]}
        finally:
            db.close()

    @app.get("/v1/health")
    def health() -> dict:
        return {"ok": True}

    app.include_router(admin_router)
    return app


def _check_username(username: str) -> None:
    if not USERNAME.match(username.strip()):
        raise HTTPException(status_code=400, detail="用户名要 3–32 位，只能是字母、数字、_ . -")


def _check_password(password: str) -> None:
    if len(password) < 8:
        raise HTTPException(status_code=400, detail="密码至少 8 位")


def _guard_lockout(db: sqlite3.Connection, key: str) -> None:
    row = db.execute("SELECT * FROM login_failures WHERE key = ?", (key,)).fetchone()
    if row and row["locked_until"] and row["locked_until"] > now():
        raise HTTPException(status_code=429, detail="试错的次数太多了，过一会儿再试")


def _record_failure(db: sqlite3.Connection, key: str) -> None:
    row = db.execute("SELECT * FROM login_failures WHERE key = ?", (key,)).fetchone()
    count = (row["count"] if row else 0) + 1
    locked = None
    if count >= LOGIN_ATTEMPTS:
        locked = (datetime.now(UTC) + timedelta(minutes=LOGIN_LOCK_MINUTES)).replace(
            microsecond=0
        ).isoformat()
        count = 0
    db.execute(
        "INSERT INTO login_failures (key, count, locked_until) VALUES (?, ?, ?)"
        " ON CONFLICT(key) DO UPDATE SET count = excluded.count,"
        " locked_until = excluded.locked_until",
        (key, count, locked),
    )


def _parse_range(header: str | None, size: int) -> tuple[int, int]:
    if not header or not header.startswith("bytes="):
        return 0, size - 1
    spec = header[len("bytes="):].split(",")[0].strip()
    first, _, last = spec.partition("-")
    try:
        if first == "":
            length = int(last)
            return max(size - length, 0), size - 1
        start = int(first)
        end = int(last) if last else size - 1
    except ValueError:
        raise HTTPException(status_code=416, detail="Range 写错了")
    if start >= size or start > end:
        raise HTTPException(status_code=416, detail="Range 超出文件")
    return start, min(end, size - 1)


def _read(path: Path, start: int, end: int):
    with path.open("rb") as handle:
        handle.seek(start)
        remaining = end - start + 1
        while remaining > 0:
            chunk = handle.read(min(256 * 1024, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
            yield chunk
