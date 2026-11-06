"""密码与令牌：密码用 argon2id，令牌是不透明随机串，库里只存它的 SHA-256。"""

from __future__ import annotations

import hashlib
import secrets

from argon2 import PasswordHasher
from argon2.exceptions import VerificationError, VerifyMismatchError

_hasher = PasswordHasher()

TOKEN_LIFETIME_DAYS = 180


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password: str, stored: str) -> bool:
    try:
        return _hasher.verify(stored, password)
    except (VerifyMismatchError, VerificationError, ValueError):
        return False


def new_token() -> str:
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def new_invite_code() -> str:
    """人念得出口的邀请码：没有 0/O、1/I 这种会看错的字。"""
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(10))
