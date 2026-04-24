"""Redis client and FastAPI dependency."""

from collections.abc import AsyncGenerator

import redis.asyncio as aioredis

from app.config import settings

# Module-level pool; created once on first use.
_redis_pool: aioredis.Redis | None = None


def _get_pool() -> aioredis.Redis:
    global _redis_pool
    if _redis_pool is None:
        _redis_pool = aioredis.from_url(
            settings.redis_url,
            encoding="utf-8",
            decode_responses=True,
        )
    return _redis_pool


async def get_redis() -> AsyncGenerator[aioredis.Redis, None]:
    """FastAPI dependency that yields a Redis client."""
    yield _get_pool()
