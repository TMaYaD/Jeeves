"""Auth routes — user registration, login, logout, and profile."""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.dependencies import get_current_user
from app.auth.hashing import hash_password, verify_password
from app.auth.models import User
from app.auth.schemas import LoginRequest, Token, UserCreate, UserRead
from app.auth.tokens import create_access_token
from app.database import get_db

router = APIRouter(tags=["auth"])


# ── Sessions ──────────────────────────────────────────────────────────────────


@router.post("/session", response_model=Token)
async def login(body: LoginRequest, db: AsyncSession = Depends(get_db)) -> Token:
    result = await db.execute(select(User).where(User.email == body.email))
    user = result.scalar_one_or_none()

    if user is None or not verify_password(body.password, user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )

    access_token = create_access_token({"sub": user.id})
    return Token(access_token=access_token, token_type="bearer")


@router.delete("/session", status_code=status.HTTP_200_OK)
async def logout(current_user: User = Depends(get_current_user)) -> dict[str, str]:
    # Token invalidation is handled client-side; server acknowledges the request.
    return {"detail": "Session ended"}


# ── Users ─────────────────────────────────────────────────────────────────────


@router.post("/user", response_model=Token, status_code=status.HTTP_201_CREATED)
async def register_user(body: UserCreate, db: AsyncSession = Depends(get_db)) -> Token:
    result = await db.execute(select(User).where(User.email == body.email))
    if result.scalar_one_or_none() is not None:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered")

    user = User(email=body.email, hashed_password=hash_password(body.password))
    db.add(user)
    await db.commit()
    await db.refresh(user)

    access_token = create_access_token({"sub": user.id})
    return Token(access_token=access_token, token_type="bearer")


@router.get("/user", response_model=UserRead)
async def get_current_user_profile(current_user: User = Depends(get_current_user)) -> User:
    return current_user
