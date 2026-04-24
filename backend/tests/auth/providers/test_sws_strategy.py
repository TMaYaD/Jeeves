"""Unit tests for the SWS signature verification strategy."""

import base64
import os

import fakeredis.aioredis
import pytest
import pytest_asyncio
from fastapi import HTTPException
from nacl.signing import SigningKey
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

os.environ.setdefault("JEEVES_SECRET_KEY", "test-secret-key")

from app.auth.providers.sws_nonce import create_nonce
from app.auth.providers.sws_strategy import SIWS_TEMPLATE, verify_sws
from app.database import Base

TEST_DB_URL = "sqlite+aiosqlite:///:memory:"


@pytest_asyncio.fixture
async def engine():
    _engine = create_async_engine(TEST_DB_URL, echo=False)
    async with _engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield _engine
    await _engine.dispose()


@pytest_asyncio.fixture
async def db(engine):
    factory = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)
    async with factory() as session:
        yield session
        await session.rollback()


@pytest_asyncio.fixture
async def redis():
    return fakeredis.aioredis.FakeRedis(decode_responses=True)


@pytest.fixture
def signing_key():
    """Real ed25519 keypair generated fresh for each test."""
    return SigningKey.generate()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _b58encode(data: bytes) -> str:
    """Minimal base58 encode used to build a fake public key."""
    import base58 as _base58

    return _base58.b58encode(data).decode()


async def _make_challenge(redis, public_key_b58: str) -> tuple[str, str]:
    return await create_nonce(redis, public_key_b58)


def _sign_message(signing_key: SigningKey, public_key_b58: str, nonce: str, issued_at: str) -> str:
    message = SIWS_TEMPLATE.format(
        domain="jeeves.app",
        public_key=public_key_b58,
        nonce=nonce,
        issued_at=issued_at,
    ).encode()
    signed = signing_key.sign(message)
    # PyNaCl returns prepended signature; we want only the 64 signature bytes.
    return base64.b64encode(signed.signature).decode()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_valid_signature_returns_user(db, redis, signing_key):
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))
    nonce, issued_at = await _make_challenge(redis, public_key_b58)
    signature_b64 = _sign_message(signing_key, public_key_b58, nonce, issued_at)

    user = await verify_sws(db, redis, public_key_b58, signature_b64, nonce)

    assert user is not None
    assert user.solana_public_key == public_key_b58
    assert user.is_active is True


@pytest.mark.asyncio
async def test_valid_signature_upserts_existing_user(db, redis, signing_key):
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))

    # First sign-in creates the user.
    nonce1, issued_at1 = await _make_challenge(redis, public_key_b58)
    sig1 = _sign_message(signing_key, public_key_b58, nonce1, issued_at1)
    user1 = await verify_sws(db, redis, public_key_b58, sig1, nonce1)

    # Second sign-in should return the same user (upsert, not duplicate).
    nonce2, issued_at2 = await _make_challenge(redis, public_key_b58)
    sig2 = _sign_message(signing_key, public_key_b58, nonce2, issued_at2)
    user2 = await verify_sws(db, redis, public_key_b58, sig2, nonce2)

    assert user1.id == user2.id


@pytest.mark.asyncio
async def test_invalid_signature_raises_401(db, redis, signing_key):
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))
    nonce, _ = await _make_challenge(redis, public_key_b58)
    bad_sig = base64.b64encode(b"\x00" * 64).decode()

    with pytest.raises(HTTPException) as exc_info:
        await verify_sws(db, redis, public_key_b58, bad_sig, nonce)

    assert exc_info.value.status_code == 401


@pytest.mark.asyncio
async def test_missing_nonce_raises_401(db, redis, signing_key):
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))
    sig = base64.b64encode(b"\x00" * 64).decode()

    with pytest.raises(HTTPException) as exc_info:
        await verify_sws(db, redis, public_key_b58, sig, "nonexistent-nonce")

    assert exc_info.value.status_code == 401


@pytest.mark.asyncio
async def test_replay_attack_raises_401(db, redis, signing_key):
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))
    nonce, issued_at = await _make_challenge(redis, public_key_b58)
    sig = _sign_message(signing_key, public_key_b58, nonce, issued_at)

    # First use — should succeed.
    await verify_sws(db, redis, public_key_b58, sig, nonce)

    # Second use of the same nonce — must be rejected.
    with pytest.raises(HTTPException) as exc_info:
        await verify_sws(db, redis, public_key_b58, sig, nonce)

    assert exc_info.value.status_code == 401
