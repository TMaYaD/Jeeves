"""Unit tests for the Redis-backed SWS nonce helpers."""

import fakeredis.aioredis
import pytest

from app.auth.providers.sws_nonce import NONCE_TTL, consume_nonce, create_nonce


@pytest.fixture
async def redis():
    """In-memory Redis substitute — no running Redis required."""
    return fakeredis.aioredis.FakeRedis(decode_responses=True)


@pytest.mark.asyncio
async def test_create_nonce_stores_key_with_ttl(redis):
    nonce, issued_at = await create_nonce(redis, "pubkey123")

    assert nonce
    assert issued_at

    raw = await redis.get(f"sws_nonce:{nonce}")
    assert raw is not None

    ttl = await redis.ttl(f"sws_nonce:{nonce}")
    # TTL must be within [1, NONCE_TTL] seconds.
    assert 1 <= ttl <= NONCE_TTL


@pytest.mark.asyncio
async def test_consume_nonce_returns_data_and_deletes_key(redis):
    nonce, _ = await create_nonce(redis, "pubkey_abc")

    data = await consume_nonce(redis, nonce)

    assert data is not None
    assert data["public_key"] == "pubkey_abc"
    assert "issued_at" in data

    # Key must be gone after consumption.
    assert await redis.get(f"sws_nonce:{nonce}") is None


@pytest.mark.asyncio
async def test_consume_nonce_second_call_returns_none(redis):
    nonce, _ = await create_nonce(redis, "pubkey_xyz")

    first = await consume_nonce(redis, nonce)
    second = await consume_nonce(redis, nonce)

    assert first is not None
    assert second is None  # replay must be rejected


@pytest.mark.asyncio
async def test_consume_nonce_nonexistent_returns_none(redis):
    result = await consume_nonce(redis, "does-not-exist")
    assert result is None
