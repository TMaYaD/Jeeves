"""User registration and profile endpoints."""

from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, field_validator
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.sessions import Token
from app.auth.dependencies import get_current_user
from app.auth.hashing import hash_password
from app.auth.tokens import create_access_token
from app.database import get_db
from app.models.user import User

router = APIRouter(tags=["users"])


class UserCreate(BaseModel):
    email: str
    password: str

    @field_validator("email")
    @classmethod
    def email_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("Email must not be empty")
        return v.strip()


class UserRead(BaseModel):
    id: str
    email: str
    is_active: bool
    created_at: datetime

    model_config = {"from_attributes": True}


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
