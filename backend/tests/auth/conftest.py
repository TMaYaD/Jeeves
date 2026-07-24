"""Shared fixtures for the SWS auth tests.

Reuses the session-scoped engine and per-test `db` fixture from the top-level
`tests/conftest.py`; adds the fake Redis and signing key the SWS flow needs, plus
a `client` that overrides both the DB and Redis dependencies.
"""

from collections.abc import AsyncIterator

import fakeredis.aioredis
import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from nacl.signing import SigningKey
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.main import app
from app.redis import get_redis


@pytest_asyncio.fixture
async def redis() -> Redis:
    """In-memory Redis substitute — no running Redis required."""
    return fakeredis.aioredis.FakeRedis(decode_responses=True)


@pytest.fixture
def signing_key() -> SigningKey:
    """Real ed25519 keypair generated fresh for each test."""
    return SigningKey.generate()


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
