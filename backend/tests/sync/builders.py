"""A simulated device that mints real, correctly chained envelopes for tests.

The server is content-blind, so the bodies here are deliberately uninteresting
— what the route tests exercise is the header, the chain and the dedupe key.
"""

from __future__ import annotations

import base64
import uuid
from dataclasses import dataclass, field

import jwt
from nacl.signing import SigningKey

from app.config import settings
from app.sync.envelope import (
    OP_CLASS_CONTENT,
    SUITE_PLAINTEXT_V1,
    OpHeader,
    build_envelope,
    derive_key_id,
    envelope_hash,
    frame_body,
)


def user_id_from_token(token: str) -> str:
    payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
    user_id: str = payload["sub"]
    return user_id


@dataclass
class SpecDevice:
    """One author: a keypair, a member id, and its per-workspace chain state."""

    member_id: uuid.UUID = field(default_factory=uuid.uuid4)
    signing_key: SigningKey = field(default_factory=SigningKey.generate)
    next_author_seq: int = 1
    last_envelope_hash: bytes = bytes(32)

    @property
    def sign_pk(self) -> bytes:
        return bytes(self.signing_key.verify_key)

    @property
    def key_id(self) -> bytes:
        return derive_key_id(self.sign_pk)

    def registration_body(self) -> dict[str, str]:
        return {
            "member_id": str(self.member_id),
            "sign_pk": base64.b64encode(self.sign_pk).decode("ascii"),
        }

    def next_envelope(
        self,
        workspace_id: uuid.UUID,
        *,
        op_id: uuid.UUID | None = None,
        suite: int = SUITE_PLAINTEXT_V1,
        op_class: int = OP_CLASS_CONTENT,
        key_epoch: int = 0,
        payload: bytes = b'{"collection":"test"}',
        advance: bool = True,
    ) -> bytes:
        header = OpHeader(
            suite=suite,
            op_class=op_class,
            workspace_id=workspace_id,
            key_epoch=key_epoch,
            op_id=op_id or uuid.uuid4(),
            author_member_id=self.member_id,
            author_key_id=self.key_id,
            author_seq=self.next_author_seq,
            prev_author_hash=self.last_envelope_hash,
        )
        envelope = build_envelope(header, frame_body(payload), self.signing_key)
        if advance:
            self.next_author_seq += 1
            self.last_envelope_hash = envelope_hash(envelope)
        return envelope


def encode(envelope: bytes) -> str:
    return base64.b64encode(envelope).decode("ascii")


def encode_all(*envelopes: bytes) -> dict[str, list[str]]:
    return {"ops": [encode(envelope) for envelope in envelopes]}
