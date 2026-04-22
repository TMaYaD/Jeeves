"""Sign-In With Solana verification strategy."""

import base64
import uuid

import base58
from fastapi import HTTPException, status
from nacl.exceptions import BadSignatureError
from nacl.signing import VerifyKey
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.models import User

from .sws_nonce import consume_nonce

# ---------------------------------------------------------------------------
# SIWS message template
# ---------------------------------------------------------------------------

# Must be reconstructed byte-for-byte identically in the Flutter client
# (see ``sws_auth_provider.dart``'s ``_buildSiwsMessage``).
SIWS_TEMPLATE = (
    "{domain} wants you to sign in with your Solana account:\n"
    "{public_key}\n"
    "\n"
    "Sign in to Jeeves\n"
    "\n"
    "URI: https://jeeves.app\n"
    "Version: 1\n"
    "Chain ID: solana:mainnet\n"
    "Nonce: {nonce}\n"
    "Issued At: {issued_at}"
)


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------


async def verify_sws(
    db: AsyncSession,
    redis: object,
    public_key_b58: str,
    signature_b64: str,
    nonce: str,
) -> User:
    """Verify a Sign-In With Solana request and return (or create) the user.

    Raises :class:`~fastapi.HTTPException` 401 on any verification failure so
    callers never receive an unauthenticated user object.

    Steps:
    1. Consume (GETDEL) the nonce from Redis — fails if missing/expired/replayed.
    2. Reconstruct the canonical SIWS message.
    3. Verify the ed25519 signature with PyNaCl.
    4. Upsert a :class:`~app.auth.models.User` by *public_key_b58*.
    """
    # Step 1: nonce must exist, be unused, and be bound to this public key.
    data = await consume_nonce(redis, nonce)
    if data is None or data.get("public_key") != public_key_b58:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Nonce invalid, expired, or bound to a different public key",
        )

    # Step 2: reconstruct the message the client signed.
    message = SIWS_TEMPLATE.format(
        domain="jeeves.app",
        public_key=public_key_b58,
        nonce=nonce,
        issued_at=data["issued_at"],
    ).encode()

    # Step 3: verify ed25519 signature.
    try:
        vk = VerifyKey(base58.b58decode(public_key_b58))
        sig = base64.b64decode(signature_b64)
        vk.verify(message, sig)
    except (BadSignatureError, Exception):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Signature invalid",
        ) from None

    # Step 4: upsert user by Solana public key.
    result = await db.execute(select(User).where(User.solana_public_key == public_key_b58))
    user = result.scalar_one_or_none()
    if user is None:
        user = User(
            id=str(uuid.uuid4()),
            solana_public_key=public_key_b58,
            is_active=True,
        )
        db.add(user)
        try:
            await db.commit()
        except IntegrityError:
            # Concurrent first login for the same wallet — race loser re-fetches.
            await db.rollback()
            result = await db.execute(select(User).where(User.solana_public_key == public_key_b58))
            user = result.scalar_one()
        await db.refresh(user)
    return user
