"""Member-scoped transport auth: proof of possession over the device signing key.

A User credential proves *who owns the account*.  It must not, on its own, be
able to speak as any of that account's Devices — otherwise a stolen session
token could post ops under an existing member's identity and fork its chain
(review F10).  So a Device proves possession of its own signing key and gets a
token scoped to itself::

    nonce      = 32 random bytes, single-use, held in Redis for
                 MEMBER_CHALLENGE_TTL_SECONDS
    signature  = Ed25519(sk_member_sign,
                     b"jeeves/auth-challenge/v1" || member_id (16 raw bytes)
                                                 || nonce)

The member id sits inside the signed bytes so a captured signature cannot be
replayed into another member's challenge slot.

The issued access token carries ``token_use: "member"`` and both ``member_id``
and ``user_id``.  ``user_id`` is present for a Device and shaped nullable so a
Service member (#future) is the same token with it absent — exactly F10's
``sub = member:<id>``.
"""

from __future__ import annotations

import base64
import json
import secrets
import uuid
from datetime import UTC, datetime
from typing import Any, Final, cast

from nacl.exceptions import BadSignatureError
from nacl.signing import VerifyKey

#: Every signing use of a member key is domain-separated (review F7).
SIGNING_DOMAIN_AUTH_CHALLENGE_V1: Final = b"jeeves/auth-challenge/v1"

#: not configurable: a proof-of-possession round-trip is two local requests.
#: Two minutes is generous for that and short enough that a leaked nonce is
#: worthless before it can be used.
MEMBER_CHALLENGE_TTL_SECONDS: Final = 120
MEMBER_CHALLENGE_NONCE_BYTES: Final = 32

#: The ``token_use`` claim that separates a member token from a user session.
TOKEN_USE_MEMBER: Final = "member"


class MemberChallengeError(Exception):
    """The proof of possession did not check out."""


def member_challenge_signing_input(member_id: uuid.UUID, nonce: bytes) -> bytes:
    return SIGNING_DOMAIN_AUTH_CHALLENGE_V1 + member_id.bytes + nonce


def verify_member_challenge(
    member_id: uuid.UUID, nonce: bytes, signature: bytes, sign_pk: bytes
) -> None:
    try:
        VerifyKey(sign_pk).verify(member_challenge_signing_input(member_id, nonce), signature)
    except (BadSignatureError, ValueError) as exc:
        raise MemberChallengeError("challenge signature does not verify") from exc


def _challenge_key(nonce_b64: str) -> str:
    return f"member_challenge:{nonce_b64}"


async def create_member_challenge(redis: object, member_id: uuid.UUID) -> str:
    """Issue a single-use nonce bound to ``member_id``.  Returns it base64-encoded."""
    nonce = secrets.token_bytes(MEMBER_CHALLENGE_NONCE_BYTES)
    nonce_b64 = base64.b64encode(nonce).decode("ascii")
    await redis.set(  # type: ignore[attr-defined]
        _challenge_key(nonce_b64),
        json.dumps({"member_id": str(member_id), "issued_at": datetime.now(UTC).isoformat()}),
        ex=MEMBER_CHALLENGE_TTL_SECONDS,
    )
    return nonce_b64


async def consume_member_challenge(redis: object, nonce_b64: str) -> dict[str, Any] | None:
    """Atomically retrieve and delete the challenge — ``GETDEL``, so single-use."""
    raw: str | None = await redis.getdel(_challenge_key(nonce_b64))  # type: ignore[attr-defined]
    if raw is None:
        return None
    return cast(dict[str, Any], json.loads(raw))
