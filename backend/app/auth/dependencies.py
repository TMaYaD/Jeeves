import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jwt.exceptions import InvalidTokenError
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.models import User
from app.config import settings
from app.database import get_db

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/session")


async def _principal_from_token(token: str, db: AsyncSession) -> User:
    """Decode a bearer token and load the active User it names, or raise 401."""
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
        user_id: str | None = payload.get("sub")
        if user_id is None:
            raise credentials_exception
    except InvalidTokenError:
        raise credentials_exception from None

    user = await db.get(User, user_id)
    if user is None or not user.is_active:
        raise credentials_exception
    return user


async def get_current_user(
    token: str = Depends(oauth2_scheme),
    db: AsyncSession = Depends(get_db),
) -> User:
    return await _principal_from_token(token, db)


async def resolve_member_token(token: str, db: AsyncSession) -> User:
    """Resolve a sync-transport bearer token to the principal it authorises.

    Takes the token as a *string* rather than through ``Depends(oauth2_scheme)``
    because a browser cannot set an ``Authorization`` header on a WebSocket: the
    signal socket receives the token as its first frame and calls this directly.

    Today this delegates to the same helper as :func:`get_current_user` and
    accepts exactly the user tokens the sync routes already accept.  The seam is
    that #548 rewrites *this* function's body to member-scoped semantics and
    leaves :func:`get_current_user` alone — patching it to *reject* member
    tokens instead.
    """
    return await _principal_from_token(token, db)


async def get_current_member(
    token: str = Depends(oauth2_scheme),
    db: AsyncSession = Depends(get_db),
) -> User:
    """The HTTP dependency the sync routes authenticate with: the header-bearing
    wrapper over :func:`resolve_member_token`, so the socket and the routes
    resolve identity through exactly one function."""
    return await resolve_member_token(token, db)
