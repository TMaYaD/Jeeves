"""Wire schemas for the op-log transport.

Envelopes travel base64-encoded inside JSON.  Nothing here describes domain
content — the server would not know what to call it.
"""

from __future__ import annotations

import uuid

from pydantic import BaseModel, Field


class MemberRegisterRequest(BaseModel):
    """Enrol a Device's public keys.

    ``key_id`` is optional and, if sent, must match the server's own derivation
    — the server stores what it derives, never a claim.  ``kex_pk`` is optional
    only because rows predating #548 have none; an enrolling Device always sends
    it.  The row this creates confers **no authority**: it is an unchained shell
    until the Root-signed MemberRegister control op lands.
    """

    member_id: uuid.UUID
    #: Base64 of the raw 32-byte Ed25519 public key.
    sign_pk: str
    #: Base64 of the raw 32-byte X25519 public key.
    kex_pk: str | None = None
    key_id: str | None = None


class MemberOut(BaseModel):
    member_id: uuid.UUID
    #: Base64 of the raw 32-byte Ed25519 public key.
    sign_pk: str
    #: Base64 of the server-derived 8-byte key id.
    key_id: str
    #: Base64 of the raw 32-byte X25519 public key, when one is registered.
    kex_pk: str | None = None
    #: True once a Root-signed MemberRegister for this member was materialised.
    #: A bootstrap hint: no client's verification reads it.
    chained: bool = False


class MemberListResponse(BaseModel):
    members: list[MemberOut]


class MemberChallengeResponse(BaseModel):
    """A single-use proof-of-possession nonce, base64-encoded."""

    nonce: str


class MemberTokenRequest(BaseModel):
    nonce: str
    #: Base64 Ed25519 over ``"jeeves/auth-challenge/v1" || member_id || nonce``.
    signature: str


class RecoveryEscrowRequest(BaseModel):
    """Write the passphrase-wrapped Root.  Every field is opaque to the server
    except ``root_sig``, which it verifies against the slot's Root."""

    #: Bounded to the column's range by the route, which refuses anything outside
    #: it with the structured ``malformed_escrow_version`` detail every other
    #: rejection in this module carries — a ``Field`` constraint here would answer
    #: with Pydantic's own error shape instead.
    version: int
    blob_b64: str
    root_sig_b64: str
    root_pk_b64: str


class RecoveryEscrowResponse(BaseModel):
    version: int
    blob_b64: str
    root_sig_b64: str
    root_pk_b64: str


class PostOpsRequest(BaseModel):
    #: Base64 envelopes, applied in order in a single transaction.
    ops: list[str] = Field(default_factory=list)


class OpResult(BaseModel):
    op_id: uuid.UUID
    seq: int
    duplicate: bool


class PostOpsResponse(BaseModel):
    results: list[OpResult]


class PulledOp(BaseModel):
    seq: int
    #: Base64 envelope, byte-identical to what the author posted.
    envelope: str


class PullOpsResponse(BaseModel):
    ops: list[PulledOp]
    has_more: bool


class KeyWrapEntry(BaseModel):
    """One Member's wrapped copy of a Workspace epoch key.

    Every field is opaque to the server except the two ids it indexes by.  It never
    unwraps ``wrap_b64`` and could not: the plaintext is sealed to the Member's
    X25519 key.
    """

    member_id: uuid.UUID
    #: Base64 of the server-derived 8-byte id of the KEX key this was sealed to.
    kex_key_id: str
    #: Base64 of ``epk 32B || nonce 24B || XChaCha20-Poly1305(...)``.
    wrap_b64: str


class PutKeyWrapsRequest(BaseModel):
    """Upload the whole wrap set for one epoch.

    **Whole-set, never incremental**, because the ``rotate`` op's ``keywrap_digest``
    commits to the set: a partial upload could not be checked against it, and
    accepting one would hand the server the ability to curate which members can read
    the new epoch.

    ``epoch > 0`` requires the matching materialised ``rotate``, whose digest this
    set must hash to.  Epoch 0 has no rotate behind it — nothing rotated *to* it —
    so the digest arrives in ``keywrap_digest`` and is stored as the commitment.
    """

    epoch: int
    wraps: list[KeyWrapEntry] = Field(default_factory=list)
    #: Base64 of ``nonce 24B || XChaCha20-Poly1305(master_wrap_key, ...)``.
    escrow_wrap_b64: str
    #: Base64 SHA-256 over the whole set.  Required for epoch 0 and ignored above
    #: it, where the signed ``rotate`` op is the authority on what the digest is.
    keywrap_digest_b64: str | None = None


class KeyWrapOut(BaseModel):
    epoch: int
    member_id: uuid.UUID
    kex_key_id: str
    wrap_b64: str


class KeyWrapListResponse(BaseModel):
    """This Member's wraps across every epoch it has been given one for.

    All epochs, not just the current one: historical epoch keys are kept for ever
    because soft-delete retention means content authored at any past epoch may still
    have to be read.
    """

    wraps: list[KeyWrapOut]


class EpochKeyOut(BaseModel):
    epoch: int
    escrow_wrap_b64: str
    keywrap_digest_b64: str


class EpochKeyListResponse(BaseModel):
    """Every epoch's escrow wrap — **useless without the passphrase**.

    Served to any live-granted member because it discloses nothing on its own: the
    wraps open only under ``master_wrap_key``, which exists only inside the recovery
    escrow blob.  This is the route a fresh device reads to recover all history from
    the passphrase alone, with no second device online.
    """

    epochs: list[EpochKeyOut]
