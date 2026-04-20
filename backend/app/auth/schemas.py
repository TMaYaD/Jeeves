"""Auth-related Pydantic schemas."""

from datetime import datetime

from pydantic import BaseModel, field_validator


class Token(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str


class RefreshRequest(BaseModel):
    refresh_token: str


class LogoutRequest(BaseModel):
    refresh_token: str | None = None


class LoginRequest(BaseModel):
    email: str
    password: str


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
