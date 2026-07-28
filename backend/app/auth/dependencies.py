import uuid

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jwt.exceptions import InvalidTokenError
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.models import User
from app.config import settings
from app.database import get_db
from app.sync.member_auth import TOKEN_USE_MEMBER
from app.sync.models import Member

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/session")


def _credentials_exception() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )


async def get_current_user(
    token: str = Depends(oauth2_scheme),
    db: AsyncSession = Depends(get_db),
) -> User:
    credentials_exception = _credentials_exception()
    try:
        payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
        user_id: str | None = payload.get("sub")
        if user_id is None:
            raise credentials_exception
    except InvalidTokenError:
        raise credentials_exception from None

    # A member token proves possession of one Device's key, not ownership of the
    # account: it must never stand in for a full user session (review F10).
    if payload.get("token_use") == TOKEN_USE_MEMBER:
        raise credentials_exception

    user = await db.get(User, user_id)
    if user is None or not user.is_active:
        raise credentials_exception
    return user


async def resolve_member_token(token: str, db: AsyncSession) -> Member:
    """Resolve a sync-transport bearer token to the Device it authorises.

    Takes the token as a *string* rather than through ``Depends(oauth2_scheme)``
    because a browser cannot set an ``Authorization`` header on a WebSocket: the
    signal socket receives the token as its first frame and calls this directly.

    Every sync surface — the HTTP data routes and the signal socket alike —
    resolves identity here and nowhere else.  That is deliberate: a socket that
    accepted a plain user token while ``POST /w/{w}/ops`` demanded a member one
    would be the weak door, and news of activity in a Workspace is not something
    a stolen user session should be able to subscribe to either.
    """
    credentials_exception = _credentials_exception()
    try:
        payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
    except InvalidTokenError:
        raise credentials_exception from None

    if payload.get("token_use") != TOKEN_USE_MEMBER:
        raise credentials_exception
    raw_member_id = payload.get("member_id")
    if not isinstance(raw_member_id, str):
        raise credentials_exception
    try:
        member_id = uuid.UUID(raw_member_id)
    except ValueError:
        raise credentials_exception from None

    member = await db.get(Member, member_id)
    if member is None:
        raise credentials_exception
    owner = await db.get(User, member.user_id)
    if owner is None or not owner.is_active:
        raise credentials_exception
    return member


async def get_current_member(
    token: str = Depends(oauth2_scheme),
    db: AsyncSession = Depends(get_db),
) -> Member:
    """The Device behind a member-scoped token.

    The header-bearing wrapper over :func:`resolve_member_token`, so the sync
    routes and the signal socket resolve identity through exactly one function.
    Authenticating here rather than through ``get_current_user`` is what makes
    ``header.author_member_id == jwt.member_id`` one comparison and no crypto.
    """
    return await resolve_member_token(token, db)
