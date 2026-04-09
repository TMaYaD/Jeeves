"""Session endpoints — login and logout."""

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.dependencies import get_current_user
from app.auth.hashing import verify_password
from app.auth.tokens import create_access_token
from app.database import get_db
from app.models.user import User

router = APIRouter(tags=["sessions"])


class LoginRequest(BaseModel):
    email: str
    password: str


class Token(BaseModel):
    access_token: str
    token_type: str


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
