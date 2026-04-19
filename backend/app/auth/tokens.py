from datetime import UTC, datetime, timedelta

import jwt

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
