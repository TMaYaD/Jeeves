import hashlib
import secrets
from datetime import UTC, datetime, timedelta

import jwt

from app.auth.models import RefreshToken
from app.config import settings


def create_access_token(data: dict[str, object], expires_delta: timedelta | None = None) -> str:
    to_encode = data.copy()
    now = datetime.now(UTC)
    expire = now + (expires_delta or timedelta(minutes=settings.access_token_expire_minutes))
    to_encode["iat"] = now
    to_encode["exp"] = expire
    # PowerSync's JWKS validator requires a `kid` header so it can select the
    # matching key from the JWKS document.
    return jwt.encode(
        to_encode,
        settings.secret_key,
        algorithm=settings.algorithm,
        headers={"kid": settings.jwt_kid},
    )


def create_refresh_token(user_id: str) -> tuple[str, RefreshToken]:
    """Create a long-lived refresh token.

    Returns (raw_token, orm_record).  The raw token is sent to the client
    exactly once and never stored.  Only the SHA-256 hash is persisted so a
    database breach cannot expose live tokens.
    """
    raw = secrets.token_urlsafe(32)
    token_hash = hash_refresh_token(raw)
    record = RefreshToken(
        user_id=user_id,
        token_hash=token_hash,
        expires_at=datetime.now(UTC) + timedelta(days=settings.refresh_token_expire_days),
    )
    return raw, record


def hash_refresh_token(raw: str) -> str:
    return hashlib.sha256(raw.encode()).hexdigest()
