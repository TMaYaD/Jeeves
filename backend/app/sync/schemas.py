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
