"""Auth routes — user registration, login, logout, token refresh, and profile."""

from datetime import UTC, datetime

from fastapi import APIRouter, Depends, HTTPException, status
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.dependencies import get_current_user
from app.auth.hashing import hash_password, verify_password
from app.auth.models import RefreshToken, User
from app.auth.providers.sws_nonce import create_nonce
from app.auth.providers.sws_strategy import SIWS_DOMAIN, verify_sws
from app.auth.schemas import (
    LoginRequest,
    LogoutRequest,
    RefreshRequest,
    SWSChallengeRequest,
    SWSChallengeResponse,
    SWSLoginRequest,
    Token,
    UserCreate,
    UserRead,
)
from app.auth.tokens import create_access_token, create_refresh_token, hash_refresh_token
from app.database import get_db
from app.redis import get_redis

router = APIRouter(tags=["auth"])


# ── Sessions ──────────────────────────────────────────────────────────────────


@router.post("/session", response_model=Token)
async def login(body: LoginRequest, db: AsyncSession = Depends(get_db)) -> Token:
    result = await db.execute(select(User).where(User.email == body.email))
    user = result.scalar_one_or_none()

    pw_ok = (
        user is not None
        and user.is_active
        and user.hashed_password
        and verify_password(body.password, user.hashed_password)
    )
    if not pw_ok:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )

    assert user is not None  # narrowed: pw_ok is True implies user is not None
    access_token = create_access_token({"sub": user.id})
    raw_refresh, refresh_record = create_refresh_token(user.id)
    db.add(refresh_record)
    await db.commit()
    return Token(access_token=access_token, refresh_token=raw_refresh, token_type="bearer")


@router.post("/session/refresh", response_model=Token)
async def refresh_session(body: RefreshRequest, db: AsyncSession = Depends(get_db)) -> Token:
    """Exchange a valid refresh token for a new access token + rotated refresh token."""
    token_hash = hash_refresh_token(body.refresh_token)
    result = await db.execute(select(RefreshToken).where(RefreshToken.token_hash == token_hash))
    record = result.scalar_one_or_none()

    now = datetime.now(UTC)
    invalid = (
        record is None
        or record.revoked_at is not None
        or record.expires_at.replace(tzinfo=UTC) <= now
    )
    if invalid:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired refresh token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    assert record is not None  # narrowed: invalid guard above covers None
    user = await db.get(User, record.user_id)
    if user is None or not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired refresh token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    # Rotate: revoke old token, issue new one.
    record.revoked_at = now
    access_token = create_access_token({"sub": user.id})
    raw_refresh, new_record = create_refresh_token(user.id)
    db.add(new_record)
    await db.commit()
    return Token(access_token=access_token, refresh_token=raw_refresh, token_type="bearer")


@router.delete("/session", status_code=status.HTTP_200_OK)
async def logout(
    body: LogoutRequest | None = None,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> dict[str, str]:
    """Revoke the refresh token server-side (best-effort) and end the session."""
    if body and body.refresh_token:
        token_hash = hash_refresh_token(body.refresh_token)
        result = await db.execute(
            select(RefreshToken).where(
                RefreshToken.token_hash == token_hash,
                RefreshToken.user_id == current_user.id,
            )
        )
        record = result.scalar_one_or_none()
        if record and record.revoked_at is None:
            record.revoked_at = datetime.now(UTC)
            await db.commit()
    return {"detail": "Session ended"}


# ── Users ─────────────────────────────────────────────────────────────────────


@router.post("/user", response_model=Token, status_code=status.HTTP_201_CREATED)
async def register_user(body: UserCreate, db: AsyncSession = Depends(get_db)) -> Token:
    result = await db.execute(select(User).where(User.email == body.email))
    if result.scalar_one_or_none() is not None:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered")

    user = User(email=body.email, hashed_password=hash_password(body.password))
    db.add(user)
    await db.flush()  # assign user.id before creating the refresh token

    access_token = create_access_token({"sub": user.id})
    raw_refresh, refresh_record = create_refresh_token(user.id)
    db.add(refresh_record)
    await db.commit()
    return Token(access_token=access_token, refresh_token=raw_refresh, token_type="bearer")


@router.get("/user", response_model=UserRead)
async def get_current_user_profile(current_user: User = Depends(get_current_user)) -> User:
    return current_user


# ── Sign-In With Solana (SWS) ─────────────────────────────────────────────────


@router.post("/auth/sws/challenge", response_model=SWSChallengeResponse)
async def sws_challenge(
    body: SWSChallengeRequest,
    redis: Redis = Depends(get_redis),
) -> SWSChallengeResponse:
    """Issue a single-use nonce bound to the given Solana public key.

    The client must use the returned nonce within :data:`NONCE_TTL` seconds
    (300 s) or request a fresh challenge.
    """
    nonce, issued_at = await create_nonce(redis, body.public_key)
    return SWSChallengeResponse(nonce=nonce, issued_at=issued_at, domain=SIWS_DOMAIN)


@router.post("/auth/sws", response_model=Token)
async def sws_login(
    body: SWSLoginRequest,
    db: AsyncSession = Depends(get_db),
    redis: Redis = Depends(get_redis),
) -> Token:
    """Complete a Sign-In With Solana flow.

    Verifies the ed25519 signature over the canonical SIWS message, then
    upserts a user record keyed by *public_key* and issues JWT tokens.
    """
    user = await verify_sws(db, redis, body.public_key, body.signature, body.nonce)
    access_token = create_access_token({"sub": user.id})
    raw_refresh, refresh_record = create_refresh_token(user.id)
    db.add(refresh_record)
    await db.commit()
    return Token(access_token=access_token, refresh_token=raw_refresh, token_type="bearer")
