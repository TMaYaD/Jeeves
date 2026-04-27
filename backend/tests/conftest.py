"""Shared pytest fixtures for the test suite.

Uses an in-memory SQLite database (via aiosqlite) so tests require no
running Postgres instance.  The `get_db` dependency is overridden on the
FastAPI app before each test session.
"""

import os
from collections.abc import AsyncIterator

import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

# Provide a dummy secret key for tests (before app code reads settings at import time).
os.environ.setdefault("SECRET_KEY", "test-secret-key")

from app.database import Base, get_db  # noqa: E402
from app.main import app  # noqa: E402

TEST_DATABASE_URL = "sqlite+aiosqlite:///:memory:"


@pytest_asyncio.fixture
async def engine() -> AsyncIterator[AsyncEngine]:
    _engine = create_async_engine(TEST_DATABASE_URL, echo=False)
    async with _engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield _engine
    await _engine.dispose()


@pytest_asyncio.fixture
async def db(engine: AsyncEngine) -> AsyncIterator[AsyncSession]:
    async_session = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)
    async with async_session() as session:
        yield session
        await session.rollback()


@pytest_asyncio.fixture
async def client(db: AsyncSession) -> AsyncIterator[AsyncClient]:
    async def override_get_db() -> AsyncIterator[AsyncSession]:
        yield db

    app.dependency_overrides[get_db] = override_get_db
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c
    app.dependency_overrides.clear()


async def register(client: AsyncClient, email: str, password: str = "secret") -> str:
    """Register a user and return the access token."""
    reg = await client.post("/user", json={"email": email, "password": password})
    token: str = reg.json()["access_token"]
    return token


async def register_full(
    client: AsyncClient, email: str, password: str = "secret"
) -> tuple[str, str]:
    """Register a user and return (access_token, refresh_token)."""
    reg = await client.post("/user", json={"email": email, "password": password})
    assert reg.status_code == 201, f"register failed: {reg.status_code} {reg.text}"
    data = reg.json()
    return data["access_token"], data["refresh_token"]


def auth_header(token: str) -> dict[str, str]:
    """Return an Authorization header dict for the given token."""
    return {"Authorization": f"Bearer {token}"}
