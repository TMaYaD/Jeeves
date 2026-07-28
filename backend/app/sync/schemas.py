"""Wire schemas for the op-log transport.

Envelopes travel base64-encoded inside JSON.  Nothing here describes domain
content — the server would not know what to call it.
"""

from __future__ import annotations

import uuid

from pydantic import BaseModel, Field


class MemberRegisterRequest(BaseModel):
    """Enrol a signing key.  ``key_id`` is optional and, if sent, must match the
    server's own derivation — the server stores what it derives, never a claim."""

    member_id: uuid.UUID
    #: Base64 of the raw 32-byte Ed25519 public key.
    sign_pk: str
    key_id: str | None = None


class MemberOut(BaseModel):
    member_id: uuid.UUID
    #: Base64 of the raw 32-byte Ed25519 public key.
    sign_pk: str
    #: Base64 of the server-derived 8-byte key id.
    key_id: str


class MemberListResponse(BaseModel):
    members: list[MemberOut]


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
