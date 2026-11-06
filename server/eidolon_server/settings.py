"""服务端的配置：都从环境变量来，测试里直接传一个对象。"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    database: Path
    packages: Path
    admin_username: str | None = None
    admin_password: str | None = None

    @classmethod
    def from_environment(cls) -> "Settings":
        return cls(
            database=Path(os.environ.get("EIDOLON_SERVER_DB", "data/eidolon.sqlite3")),
            packages=Path(os.environ.get("EIDOLON_SERVER_PACKAGES", "data/packages")),
            admin_username=os.environ.get("EIDOLON_SERVER_ADMIN_USER") or None,
            admin_password=os.environ.get("EIDOLON_SERVER_ADMIN_PASSWORD") or None,
        )


LOGIN_ATTEMPTS = 5
LOGIN_LOCK_MINUTES = 15
