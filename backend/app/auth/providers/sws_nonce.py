"""Redis-backed nonce management for Sign-In With Solana challenges."""

import json
import secrets
from datetime import UTC, datetime

# TTL for each nonce in seconds.  After this window the client must request
# a new challenge.  Five minutes is generous for a mobile wallet interaction.
NONCE_TTL = 300


async def create_nonce(redis: object, public_key: str) -> tuple[str, str]:
    """Issue a new nonce for the given *public_key*.

    Stores ``{"public_key": ..., "issued_at": ...}`` in Redis under the key
    ``sws_nonce:{nonce}`` with a :data:`NONCE_TTL`-second expiry.

    Returns ``(nonce, issued_at)`` where *issued_at* is an ISO-8601 UTC
    datetime string — the same value that must appear verbatim in the SIWS
    message so the backend can reconstruct and verify it.
    """
    nonce = secrets.token_urlsafe(32)
    issued_at = datetime.now(UTC).isoformat()
    await redis.set(  # type: ignore[attr-defined]
        f"sws_nonce:{nonce}",
        json.dumps({"public_key": public_key, "issued_at": issued_at}),
        ex=NONCE_TTL,
    )
    return nonce, issued_at


async def consume_nonce(redis: object, nonce: str) -> dict | None:
    """Atomically retrieve and delete the nonce entry.

    Returns the stored ``{"public_key": ..., "issued_at": ...}`` dict on the
    first call, or ``None`` if the nonce is unknown, already consumed, or
    expired (Redis key no longer exists).

    Uses ``GETDEL`` for atomicity — a nonce can only be consumed once, which
    prevents replay attacks.
    """
    raw: str | None = await redis.getdel(f"sws_nonce:{nonce}")  # type: ignore[attr-defined]
    if raw is None:
        return None
    return json.loads(raw)
