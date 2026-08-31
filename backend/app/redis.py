"""Redis client and FastAPI dependency."""

from collections.abc import AsyncGenerator

import redis.asyncio as aioredis

from app.config import settings

# Module-level pool; created once on first use.
_redis_pool: aioredis.Redis | None = None


def _get_pool() -> aioredis.Redis:
    global _redis_pool
    if _redis_pool is None:
        # `from_url` is untyped in the redis-py that `uv.lock` pins, and that
        # lock is now the only resolution mypy ever sees — CI installs it with
        # `uv sync --locked` just as local dev does.  So a single ignore code
        # is exact; `strict = true` turns any spare code into an error.  When a
        # lockfile bump crosses into a redis-py that types `from_url`, mypy
        # will flag this ignore as unused and it can simply be deleted.
        _redis_pool = aioredis.from_url(  # type: ignore[no-untyped-call]
            settings.redis_url,
            encoding="utf-8",
            decode_responses=True,
        )
    return _redis_pool


async def get_redis() -> AsyncGenerator[aioredis.Redis]:
    """FastAPI dependency that yields a Redis client."""
    yield _get_pool()


async def increment_in_window(redis: object, key: str, window_seconds: int) -> int:
    """Increment ``key`` and return its count, starting a TTL on the first hit.

    One round trip and no gap between the two commands.  ``INCR`` followed by a
    separate conditional ``EXPIRE`` looks equivalent and is not: a client that
    dies between them leaves a counter with no TTL, which rate-limits its subject
    for ever rather than for a window.  ``EXPIRE ... NX`` sets the deadline only
    when the key has none, so the window starts with the first increment and is
    not extended by later ones — the same sliding-free window the separate form
    intended, without the state it could get stuck in.

    Every counter-shaped limiter in the app goes through here so there is one
    place the semantics live.
    """
    pipeline = redis.pipeline()  # type: ignore[attr-defined]
    pipeline.incr(key)
    pipeline.expire(key, window_seconds, nx=True)
    count, _ = await pipeline.execute()
    return int(count)
