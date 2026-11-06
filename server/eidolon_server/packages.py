"""包目录的登记（spec #120）：磁盘上有哪些 `.eidolonpkg`，服务器认得的就该有哪些。

文件名带种类和版本：`content-2026-11-06.eidolonpkg`。服务启动时扫一次，把新放进来、
或者大小变了的登记上；`eidolon_server scan` 是强制重算（只换了内容、大小没变时用）。
"""

from __future__ import annotations

import hashlib
import sqlite3
from pathlib import Path

from .db import now


def kind_and_version(path: Path) -> tuple[str, str]:
    """`eidolon-content-2026-11-06` → (content, 2026-11-06)；没有日期时版本记作 1。"""
    parts = path.stem.split("-")
    if parts and parts[0] == "eidolon":
        parts = parts[1:]
    if not parts:
        return "content", "1"
    return parts[0], "-".join(parts[1:]) or "1"


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def register(db: sqlite3.Connection, path: Path, force: bool = False) -> bool:
    """返回是否真的写了库。`force` 时不管记没记过都重算一遍。"""
    size = path.stat().st_size
    if not force:
        row = db.execute(
            "SELECT size FROM packages WHERE filename = ?", (path.name,)
        ).fetchone()
        if row is not None and row["size"] == size:
            return False
    kind, version = kind_and_version(path)
    db.execute(
        "INSERT INTO packages (kind, version, filename, size, sha256, created_at, current)"
        " VALUES (?, ?, ?, ?, ?, ?, 1)"
        " ON CONFLICT(filename) DO UPDATE SET size = excluded.size,"
        " sha256 = excluded.sha256, version = excluded.version, kind = excluded.kind",
        (kind, version, path.name, size, digest(path), now()),
    )
    return True


def sync(db: sqlite3.Connection, directory: Path, force: bool = False) -> int:
    """登记目录里的包，并把已经不在磁盘上的那条删掉——否则手机上会看到一个点开就 404 的包。"""
    if not directory.is_dir():
        return 0
    files = sorted(directory.glob("*.eidolonpkg"))
    names = {path.name for path in files}
    for row in db.execute("SELECT filename FROM packages").fetchall():
        if row["filename"] not in names:
            db.execute("DELETE FROM packages WHERE filename = ?", (row["filename"],))
    return sum(1 for path in files if register(db, path, force))
