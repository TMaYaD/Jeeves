"""Simulated Roots and devices that mint real, correctly signed artifacts.

The server is content-blind for content ops, so the bodies here are deliberately
uninteresting — what the route tests exercise is the header, the chain and the
dedupe key.  Control ops are the exception: the server *does* read those, so
``SpecRoot`` mints genuine Root-signed certificates rather than stand-ins.
"""

from __future__ import annotations

import base64
import secrets
import uuid
from dataclasses import dataclass, field

import jwt
from nacl.public import PrivateKey
from nacl.signing import SigningKey

from app.config import settings
from app.sync.control_payload import (
    CONTROL_TYPE_MEMBER_REGISTER,
    ZERO_PREV_CONTROL_HASH,
    ControlPayload,
    RegistrationCertificate,
    sign_registration_certificate,
)
from app.sync.envelope import (
    OP_CLASS_CONTENT,
    OP_CLASS_CONTROL,
    SUITE_PLAINTEXT_V1,
    OpHeader,
    build_envelope,
    derive_key_id,
    envelope_hash,
    frame_body,
)
from app.sync.escrow import (
    ARGON2ID_FLOOR_MEMORY_KIB,
    ARGON2ID_FLOOR_PARALLELISM,
    ARGON2ID_FLOOR_TIME_COST,
    ESCROW_BLOB_MAGIC,
    ESCROW_NONCE_BYTES,
    ESCROW_SALT_BYTES,
    ESCROW_SECRET_BYTES,
    POLY1305_TAG_BYTES,
    sign_escrow,
)
from app.sync.member_auth import member_challenge_signing_input
from app.sync.op_payload import Hlc

BASE_WALL_MS = 1_800_000_000_000


def user_id_from_token(token: str) -> str:
    payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
    user_id: str = payload["sub"]
    return user_id


@dataclass
class SpecDevice:
    """One author: a signing keypair, a KEX keypair, and its chain state."""

    member_id: uuid.UUID = field(default_factory=uuid.uuid4)
    signing_key: SigningKey = field(default_factory=SigningKey.generate)
    kex_key: PrivateKey = field(default_factory=PrivateKey.generate)
    next_author_seq: int = 1
    last_envelope_hash: bytes = bytes(32)

    @property
    def sign_pk(self) -> bytes:
        return bytes(self.signing_key.verify_key)

    @property
    def kex_pk(self) -> bytes:
        return bytes(self.kex_key.public_key)

    @property
    def key_id(self) -> bytes:
        return derive_key_id(self.sign_pk)

    def registration_body(self) -> dict[str, str]:
        return {
            "member_id": str(self.member_id),
            "sign_pk": base64.b64encode(self.sign_pk).decode("ascii"),
            "kex_pk": base64.b64encode(self.kex_pk).decode("ascii"),
        }

    def challenge_signature(self, nonce_b64: str) -> str:
        nonce = base64.b64decode(nonce_b64)
        signed = self.signing_key.sign(member_challenge_signing_input(self.member_id, nonce))
        return base64.b64encode(signed.signature).decode("ascii")

    def next_envelope(
        self,
        workspace_id: uuid.UUID,
        *,
        op_id: uuid.UUID | None = None,
        suite: int = SUITE_PLAINTEXT_V1,
        op_class: int = OP_CLASS_CONTENT,
        key_epoch: int = 0,
        payload: bytes = b'{"collection":"test"}',
        author_seq: int | None = None,
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
            author_seq=self.next_author_seq if author_seq is None else author_seq,
            prev_author_hash=self.last_envelope_hash,
        )
        envelope = build_envelope(header, frame_body(payload), self.signing_key)
        if advance:
            self.next_author_seq += 1
            self.last_envelope_hash = envelope_hash(envelope)
        return envelope


@dataclass
class SpecRoot:
    """The Workspace's Root keypair — never a member, only a signer of certs."""

    signing_key: SigningKey = field(default_factory=SigningKey.generate)

    @property
    def root_pk(self) -> bytes:
        return bytes(self.signing_key.verify_key)

    def certificate(
        self,
        device: SpecDevice,
        workspace_id: uuid.UUID,
        *,
        member_id: uuid.UUID | None = None,
        sign_pk: bytes | None = None,
        wall_ms: int = BASE_WALL_MS,
    ) -> RegistrationCertificate:
        return RegistrationCertificate(
            workspace_id=workspace_id,
            member_id=member_id or device.member_id,
            sign_pk=sign_pk if sign_pk is not None else device.sign_pk,
            kex_pk=device.kex_pk,
            registered_at_hlc=Hlc.for_member(member_id or device.member_id, wall_ms),
        )

    def control_payload(
        self,
        certificate: RegistrationCertificate,
        *,
        prev_control_hash: bytes = ZERO_PREV_CONTROL_HASH,
        corrupt_signature: bool = False,
    ) -> ControlPayload:
        cert_bytes = certificate.encode()
        root_sig = bytearray(sign_registration_certificate(cert_bytes, self.signing_key))
        if corrupt_signature:
            root_sig[-1] ^= 0x01
        return ControlPayload(
            control_type=CONTROL_TYPE_MEMBER_REGISTER,
            prev_control_hash=prev_control_hash,
            cert_bytes=cert_bytes,
            root_sig=bytes(root_sig),
        )

    def member_register_envelope(
        self,
        device: SpecDevice,
        workspace_id: uuid.UUID,
        *,
        prev_control_hash: bytes = ZERO_PREV_CONTROL_HASH,
        certificate: RegistrationCertificate | None = None,
        corrupt_signature: bool = False,
        author_seq: int | None = None,
        advance: bool = True,
    ) -> bytes:
        payload = self.control_payload(
            certificate or self.certificate(device, workspace_id),
            prev_control_hash=prev_control_hash,
            corrupt_signature=corrupt_signature,
        )
        return device.next_envelope(
            workspace_id,
            op_class=OP_CLASS_CONTROL,
            payload=payload.encode(),
            author_seq=author_seq,
            advance=advance,
        )

    def escrow_body(
        self,
        workspace_id: uuid.UUID,
        *,
        version: int = 1,
        blob: bytes | None = None,
        corrupt_signature: bool = False,
    ) -> dict[str, object]:
        wrapped = blob if blob is not None else escrow_blob()
        signature = bytearray(sign_escrow(workspace_id, version, wrapped, self.signing_key))
        if corrupt_signature:
            signature[-1] ^= 0x01
        return {
            "version": version,
            "blob_b64": base64.b64encode(wrapped).decode("ascii"),
            "root_sig_b64": base64.b64encode(bytes(signature)).decode("ascii"),
            "root_pk_b64": base64.b64encode(self.root_pk).decode("ascii"),
        }


def escrow_blob() -> bytes:
    """A v1-shaped blob with random ciphertext.

    The server never parses this — only the client does — so the bytes only have
    to be the right *shape* for a route test.  Unwrapping is exercised end to end
    on the Dart side, where the KDF and AEAD actually live.
    """
    return (
        ESCROW_BLOB_MAGIC
        + ARGON2ID_FLOOR_MEMORY_KIB.to_bytes(4, "big")
        + ARGON2ID_FLOOR_TIME_COST.to_bytes(4, "big")
        + bytes([ARGON2ID_FLOOR_PARALLELISM])
        + secrets.token_bytes(ESCROW_SALT_BYTES)
        + secrets.token_bytes(ESCROW_NONCE_BYTES)
        + secrets.token_bytes(ESCROW_SECRET_BYTES + POLY1305_TAG_BYTES)
    )


def encode(envelope: bytes) -> str:
    return base64.b64encode(envelope).decode("ascii")


def encode_all(*envelopes: bytes) -> dict[str, list[str]]:
    return {"ops": [encode(envelope) for envelope in envelopes]}
