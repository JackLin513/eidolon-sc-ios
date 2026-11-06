"""服务器上的维护命令（spec #120）：管理界面排在 #122，这一版用命令。

    python -m eidolon_server invite [--days 7]        # 生成一个邀请码
    python -m eidolon_server invites                  # 看所有邀请码
    python -m eidolon_server grant <用户名>            # 把某个账号升成管理员（#122 用得上）
    python -m eidolon_server password <用户名>         # 重设密码，密码从标准输入读
    python -m eidolon_server announcement <标题>       # 从标准输入读正文，发一条公告
    python -m eidolon_server scan <目录>               # 登记导出好的 .eidolonpkg
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import sqlite3
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

from .auth import hash_password, new_invite_code
from .db import connect, now
from .settings import Settings


def main() -> int:
    settings = Settings.from_environment()
    parser = argparse.ArgumentParser(prog="eidolon_server")
    sub = parser.add_subparsers(dest="command", required=True)

    invite = sub.add_parser("invite", help="生成一个邀请码")
    invite.add_argument("--days", type=int, default=7)

    sub.add_parser("invites", help="看所有邀请码")

    admin = sub.add_parser("admin", help="建一个管理员，或者把一个账号升成管理员")
    admin.add_argument("username")

    grant = sub.add_parser("grant", help="把一个账号升成管理员（不改密码）")
    grant.add_argument("username")

    password = sub.add_parser("password", help="重设密码")
    password.add_argument("username")

    announcement = sub.add_parser("announcement", help="发一条公告，正文从标准输入读")
    announcement.add_argument("title")

    scan = sub.add_parser("scan", help="登记目录里的内容包")
    scan.add_argument("directory")

    arguments = parser.parse_args()
    db = connect(settings.database)
    try:
        return _dispatch(arguments, db, settings)
    finally:
        db.close()


def _dispatch(arguments, db: sqlite3.Connection, settings: Settings) -> int:
    if arguments.command == "invite":
        code = new_invite_code()
        expires = (datetime.now(UTC) + timedelta(days=arguments.days)).replace(microsecond=0)
        db.execute(
            "INSERT INTO invites (code, created_at, expires_at) VALUES (?, ?, ?)",
            (code, now(), expires.isoformat()),
        )
        print(code)
        print(f"有效期到 {expires.date()}", file=sys.stderr)
        return 0

    if arguments.command == "invites":
        for row in db.execute("SELECT * FROM invites ORDER BY id DESC"):
            used = row["used_by"] and f"已用于账号 {row['used_by']}"
            print(f"{row['code']}\t{row['expires_at'] or '长期'}\t{used or '没用过'}")
        return 0

    if arguments.command == "admin":
        secret = getpass.getpass("管理员密码：")
        from .bootstrap import BootstrapError, ensure_admin

        try:
            result = ensure_admin(db, arguments.username, secret)
        except BootstrapError as error:
            print(error, file=sys.stderr)
            return 1
        print("已经建好" if result == "created" else "已经有人了，改成管理员或没变")
        return 0

    if arguments.command == "grant":
        changed = db.execute(
            "UPDATE users SET role = 'admin' WHERE username = ?", (arguments.username,)
        ).rowcount
        if not changed:
            print("没有这个账号", file=sys.stderr)
            return 1
        print(f"{arguments.username} 现在是管理员")
        return 0

    if arguments.command == "password":
        secret = getpass.getpass("新密码：")
        db.execute(
            "UPDATE users SET password_hash = ? WHERE username = ?",
            (hash_password(secret), arguments.username),
        )
        db.execute(
            "DELETE FROM tokens WHERE user_id = (SELECT id FROM users WHERE username = ?)",
            (arguments.username,),
        )
        print("改好了，旧令牌都作废了")
        return 0

    if arguments.command == "announcement":
        body = sys.stdin.read().strip()
        db.execute(
            "INSERT INTO announcements (title, body, published_at) VALUES (?, ?, ?)",
            (arguments.title, body, now()),
        )
        print("发出去了")
        return 0

    if arguments.command == "scan":
        from .packages import sync as sync_packages

        count = sync_packages(db, Path(arguments.directory), force=True)
        print(f"登记了 {count} 个包")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
