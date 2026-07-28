"""Fixtures for the sync suite.

Reuses the session-scoped engine and per-test ``db`` fixture from the top-level
``tests/conftest.py``, and adds the fake Redis that the member proof-of-possession
challenge and the escrow fetch rate limiter need.  Both are real code paths — the
substitute is the store, not the logic.
"""

from collections.abc import AsyncIterator

import fakeredis.aioredis
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.main import app
from app.redis import get_redis


@pytest_asyncio.fixture
async def redis() -> Redis:
    """In-memory Redis substitute — no running Redis required."""
    return fakeredis.aioredis.FakeRedis(decode_responses=True)


@pytest_asyncio.fixture
async def client(db: AsyncSession, redis: Redis) -> AsyncIterator[AsyncClient]:
    async def override_get_db() -> AsyncIterator[AsyncSession]:
        yield db

    async def override_get_redis() -> AsyncIterator[Redis]:
        yield redis

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_redis] = override_get_redis
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c
    app.dependency_overrides.clear()
