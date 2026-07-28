"""Recovery escrow: the signature preimage, and the blob shape the server never reads.

The escrow is how a new Device obtains Root with nothing but the passphrase
(ADR-0028, proposal § Identity and keys).  The server stores four opaque
fields — ``version``, ``blob``, ``root_sig``, ``root_pk`` — and its only
cryptographic duty is refusing a ``PUT`` whose ``root_sig`` does not verify
against the ``root_pk`` already in the slot (review F16: a stolen *user*
credential must not be able to overwrite the escrow).

The signed preimage binds the slot::

    root_sig = Ed25519(root_sk,
        b"jeeves/escrow/v1" || workspace_id (16 raw UUID bytes)
                            || version (u64 big-endian)
                            || blob)

``workspace_id`` sits inside the signed bytes so a blob signed for one Workspace
can never be replayed into another Workspace's slot, even by an honest-but-
confused server.

The blob itself is client-defined and the server never parses it.  Its v1 layout
is pinned here only because the golden vectors pin it, and because the KDF floor
is protocol identity rather than a client preference::

    blob = magic "JVE1"          4B
        || m_cost_kib   u32      4B
        || t_cost       u32      4B
        || parallelism  u8       1B
        || salt                 16B
        || nonce                24B     (XChaCha20)
        || XChaCha20-Poly1305(
               key = Argon2id(passphrase, salt, params),
               nonce,
               aad = the 53 header bytes above,
               plaintext = root_sk 32B || master_wrap_key 32B)

The KDF parameters live *inside* the blob so a future native implementation can
raise them without a protocol change, and the client enforces the floor below on
**read and write** — a below-floor blob is refused before any KDF work runs,
which is what closes F12's weakened-params-at-write attack.

``master_wrap_key`` is minted and escrowed now even though nothing wraps under
it until #554: the constant blob shape is the structural tidy-up, and it makes a
passphrase change a pure re-wrap for ever.
"""

from __future__ import annotations

import struct
import uuid
from typing import Final

from nacl.exceptions import BadSignatureError
from nacl.signing import SigningKey, VerifyKey

#: Every signing use of the Root key is domain-separated (review F7).
SIGNING_DOMAIN_ESCROW_V1: Final = b"jeeves/escrow/v1"

ESCROW_BLOB_MAGIC: Final = b"JVE1"
ESCROW_SALT_BYTES: Final = 16
ESCROW_NONCE_BYTES: Final = 24
#: ``root_sk 32B || master_wrap_key 32B`` — a constant plaintext width, for ever.
ESCROW_SECRET_BYTES: Final = 64
ESCROW_BLOB_HEADER_BYTES: Final = (
    len(ESCROW_BLOB_MAGIC) + 4 + 4 + 1 + ESCROW_SALT_BYTES + ESCROW_NONCE_BYTES
)
POLY1305_TAG_BYTES: Final = 16
ESCROW_BLOB_BYTES: Final = ESCROW_BLOB_HEADER_BYTES + ESCROW_SECRET_BYTES + POLY1305_TAG_BYTES

#: The client-enforced Argon2id floor (review F12).  Vector-pinned, so a client
#: that quietly weakened it would fail a test rather than a user.
ARGON2ID_FLOOR_MEMORY_KIB: Final = 65536
ARGON2ID_FLOOR_TIME_COST: Final = 3
ARGON2ID_FLOOR_PARALLELISM: Final = 1

ROOT_PUBLIC_KEY_BYTES: Final = 32
ROOT_SIGNATURE_BYTES: Final = 64

#: A slot's first write.  Anything else on create is a version regression: the
#: caller is either replaying or trying to plant an unreachably high version.
FIRST_ESCROW_VERSION: Final = 1
#: The value reported as ``stored_version`` when no record exists — "create must
#: be v1" reads unambiguously off it, so create and regression share one code.
NO_ESCROW_STORED_VERSION: Final = 0

# not configurable: escrow fetches are a rare, deliberate act (enrolment and
# passphrase change).  A daily ceiling per user turns a scripted exfiltration
# attempt into an alarm rather than a quiet download.
RECOVERY_FETCH_DAILY_LIMIT: Final = 20
RECOVERY_FETCH_WINDOW_SECONDS: Final = 86_400


class EscrowSignatureError(Exception):
    """The claimed Root did not sign this ``(workspace, version, blob)``."""

    reason: str = "bad_escrow_signature"


def escrow_signing_input(workspace_id: uuid.UUID, version: int, blob: bytes) -> bytes:
    return SIGNING_DOMAIN_ESCROW_V1 + workspace_id.bytes + struct.pack(">Q", version) + blob


def sign_escrow(
    workspace_id: uuid.UUID, version: int, blob: bytes, root_signing_key: SigningKey
) -> bytes:
    return root_signing_key.sign(escrow_signing_input(workspace_id, version, blob)).signature


def verify_escrow_signature(
    workspace_id: uuid.UUID, version: int, blob: bytes, signature: bytes, root_pk: bytes
) -> None:
    """Raise ``EscrowSignatureError`` unless ``root_pk`` signed exactly this record."""
    try:
        VerifyKey(root_pk).verify(escrow_signing_input(workspace_id, version, blob), signature)
    except (BadSignatureError, ValueError) as exc:
        raise EscrowSignatureError("Root signature over the escrow record does not verify") from exc


def recovery_fetch_counter_key(user_id: str) -> str:
    return f"recovery_escrow_fetch:{user_id}"


async def count_recovery_fetch(redis: object, user_id: str) -> int:
    """Increment and return this user's fetch count inside the current window.

    Same Redis-counter shape as ``sws_nonce``: the first increment starts the
    window, and the key expires with it rather than being swept.
    """
    key = recovery_fetch_counter_key(user_id)
    count: int = await redis.incr(key)  # type: ignore[attr-defined]
    if count == 1:
        await redis.expire(key, RECOVERY_FETCH_WINDOW_SECONDS)  # type: ignore[attr-defined]
    return count


async def recovery_fetch_retry_after_seconds(redis: object, user_id: str) -> int:
    """Seconds until the current window rolls over, for the 429's detail."""
    ttl: int = await redis.ttl(recovery_fetch_counter_key(user_id))  # type: ignore[attr-defined]
    return ttl if ttl > 0 else RECOVERY_FETCH_WINDOW_SECONDS
