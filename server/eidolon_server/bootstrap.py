"""把管理员账号建出来（spec #120；管理界面在 #122）。

服务器第一次起来时用环境变量 `EIDOLON_SERVER_ADMIN_USER` / `_PASSWORD` 建一个管理员，
省得先跑一条命令再登录。已经在的账号只升角色，不覆盖密码。
"""

from __future__ import annotations

import sqlite3

from .auth import hash_password
from .db import now

MIN_PASSWORD = 8


class BootstrapError(Exception):
    pass


def ensure_admin(db: sqlite3.Connection, username: str, password: str) -> str:
    """返回 `created` / `promoted` / `kept`（已经是管理员，什么都没改）。"""
    username = username.strip()
    if not username:
        raise BootstrapError("管理员用户名不能是空的")
    if len(password) < MIN_PASSWORD:
        raise BootstrapError(f"管理员密码至少 {MIN_PASSWORD} 位")

    row = db.execute("SELECT id, role FROM users WHERE username = ?", (username,)).fetchone()
    if row is None:
        db.execute(
            "INSERT INTO users (username, password_hash, role, created_at)"
            " VALUES (?, ?, 'admin', ?)",
            (username, hash_password(password), now()),
        )
        return "created"
    if row["role"] == "admin":
        return "kept"
    db.execute("UPDATE users SET role = 'admin' WHERE id = ?", (row["id"],))
    return "promoted"
