"""SQLite 的表结构与连接。一个人用，一个库就够，不需要迁移框架。"""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id            INTEGER PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE COLLATE NOCASE,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL DEFAULT 'user',
    created_at    TEXT NOT NULL,
    last_login_at TEXT,
    disabled_at   TEXT
);

CREATE TABLE IF NOT EXISTS invites (
    id         INTEGER PRIMARY KEY,
    code       TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    expires_at TEXT,
    used_by    INTEGER REFERENCES users(id),
    used_at    TEXT
);

CREATE TABLE IF NOT EXISTS tokens (
    id           INTEGER PRIMARY KEY,
    token_hash   TEXT NOT NULL UNIQUE,
    user_id      INTEGER NOT NULL REFERENCES users(id),
    created_at   TEXT NOT NULL,
    expires_at   TEXT NOT NULL,
    last_used_at TEXT
);

CREATE TABLE IF NOT EXISTS packages (
    id         INTEGER PRIMARY KEY,
    kind       TEXT NOT NULL,
    version    TEXT NOT NULL,
    filename   TEXT NOT NULL UNIQUE,
    size       INTEGER NOT NULL,
    sha256     TEXT NOT NULL,
    created_at TEXT NOT NULL,
    current    INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS announcements (
    id           INTEGER PRIMARY KEY,
    title        TEXT NOT NULL,
    body         TEXT NOT NULL,
    published_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS audit (
    id     INTEGER PRIMARY KEY,
    at     TEXT NOT NULL,
    actor  TEXT NOT NULL,
    action TEXT NOT NULL,
    target TEXT
);

CREATE TABLE IF NOT EXISTS login_failures (
    key          TEXT PRIMARY KEY,
    count        INTEGER NOT NULL,
    locked_until TEXT
);
"""


def now() -> str:
    """库里所有时间都是 UTC 的 ISO 8601，比较时按字符串比也对。"""
    return datetime.now(UTC).replace(microsecond=0).isoformat()


def connect(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path, isolation_level=None)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA foreign_keys=ON")
    connection.executescript(SCHEMA)
    return connection
