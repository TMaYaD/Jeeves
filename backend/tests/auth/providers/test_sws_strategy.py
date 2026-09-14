"""Unit tests for the SWS signature verification strategy.

The `db`, `redis`, and `signing_key` fixtures live in tests/auth/conftest.py
(db comes from the top-level tests/conftest.py).
"""

import base64

import pytest
from fastapi import HTTPException
from nacl.signing import SigningKey
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.providers.sws_nonce import create_nonce
from app.auth.providers.sws_strategy import SIWS_TEMPLATE, verify_sws

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _b58encode(data: bytes) -> str:
    """Minimal base58 encode used to build a fake public key."""
    import base58 as _base58

    return _base58.b58encode(data).decode()


async def _make_challenge(redis: Redis, public_key_b58: str) -> tuple[str, str]:
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
async def test_valid_signature_returns_user(
    db: AsyncSession, redis: Redis, signing_key: SigningKey
) -> None:
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))
    nonce, issued_at = await _make_challenge(redis, public_key_b58)
    signature_b64 = _sign_message(signing_key, public_key_b58, nonce, issued_at)

    user = await verify_sws(db, redis, public_key_b58, signature_b64, nonce)

    assert user is not None
    assert user.solana_public_key == public_key_b58
    assert user.is_active is True


@pytest.mark.asyncio
async def test_valid_signature_upserts_existing_user(
    db: AsyncSession, redis: Redis, signing_key: SigningKey
) -> None:
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
async def test_invalid_signature_raises_401(
    db: AsyncSession, redis: Redis, signing_key: SigningKey
) -> None:
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))
    nonce, _ = await _make_challenge(redis, public_key_b58)
    bad_sig = base64.b64encode(b"\x00" * 64).decode()

    with pytest.raises(HTTPException) as exc_info:
        await verify_sws(db, redis, public_key_b58, bad_sig, nonce)

    assert exc_info.value.status_code == 401


@pytest.mark.asyncio
async def test_missing_nonce_raises_401(
    db: AsyncSession, redis: Redis, signing_key: SigningKey
) -> None:
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))
    sig = base64.b64encode(b"\x00" * 64).decode()

    with pytest.raises(HTTPException) as exc_info:
        await verify_sws(db, redis, public_key_b58, sig, "nonexistent-nonce")

    assert exc_info.value.status_code == 401


@pytest.mark.asyncio
async def test_replay_attack_raises_401(
    db: AsyncSession, redis: Redis, signing_key: SigningKey
) -> None:
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))
    nonce, issued_at = await _make_challenge(redis, public_key_b58)
    sig = _sign_message(signing_key, public_key_b58, nonce, issued_at)

    # First use — should succeed.
    await verify_sws(db, redis, public_key_b58, sig, nonce)

    # Second use of the same nonce — must be rejected.
    with pytest.raises(HTTPException) as exc_info:
        await verify_sws(db, redis, public_key_b58, sig, nonce)

    assert exc_info.value.status_code == 401


@pytest.mark.asyncio
async def test_malformed_base58_public_key_raises_401(db: AsyncSession, redis: Redis) -> None:
    """`base58.b58decode` raises ValueError on non-alphabet input — a bad credential."""
    malformed_public_key = "not-a-valid-base58-key!!"
    nonce, _ = await _make_challenge(redis, malformed_public_key)
    sig = base64.b64encode(b"\x00" * 64).decode()

    with pytest.raises(HTTPException) as exc_info:
        await verify_sws(db, redis, malformed_public_key, sig, nonce)

    assert exc_info.value.status_code == 401


@pytest.mark.asyncio
async def test_wrong_length_public_key_raises_401(db: AsyncSession, redis: Redis) -> None:
    """`VerifyKey` raises nacl's ValueError unless the key decodes to exactly 32 bytes."""
    short_public_key = _b58encode(b"\x01" * 16)
    nonce, _ = await _make_challenge(redis, short_public_key)
    sig = base64.b64encode(b"\x00" * 64).decode()

    with pytest.raises(HTTPException) as exc_info:
        await verify_sws(db, redis, short_public_key, sig, nonce)

    assert exc_info.value.status_code == 401


@pytest.mark.asyncio
async def test_malformed_base64_signature_raises_401(
    db: AsyncSession, redis: Redis, signing_key: SigningKey
) -> None:
    """`base64.b64decode` raises binascii.Error (a ValueError) on undecodable input."""
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))
    nonce, _ = await _make_challenge(redis, public_key_b58)

    with pytest.raises(HTTPException) as exc_info:
        await verify_sws(db, redis, public_key_b58, "!!!not-base64!!!", nonce)

    assert exc_info.value.status_code == 401


@pytest.mark.asyncio
async def test_unexpected_internal_error_is_not_converted_to_401(
    db: AsyncSession,
    redis: Redis,
    signing_key: SigningKey,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A bug inside the verification block must surface as a 500, not "Signature invalid".

    Reporting an internal fault as a bad credential sends the client off chasing
    its wallet, hides the fault from error tracking, and — with ``from None`` —
    throws away the traceback that would explain it.
    """
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))
    nonce, issued_at = await _make_challenge(redis, public_key_b58)
    signature_b64 = _sign_message(signing_key, public_key_b58, nonce, issued_at)

    def _boom(_key: bytes) -> object:
        raise RuntimeError("simulated internal failure")

    monkeypatch.setattr("app.auth.providers.sws_strategy.VerifyKey", _boom)

    with pytest.raises(RuntimeError, match="simulated internal failure"):
        await verify_sws(db, redis, public_key_b58, signature_b64, nonce)
