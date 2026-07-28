"""The ``op_class=2`` control payload format and the MemberRegister certificate.

Control ops are the one part of the log the server *does* read.  That is
deliberate (ADR-0028, security review F2): content is opaque to the server for
ever, but membership has to be checkable by whoever is holding the bytes, so
control payloads are unencrypted and self-describing.

::

    {
      "type": "member_register",
      "prev_control_hash": "<hex64>",   // SHA-256 of the predecessor control
                                        // op's *payload bytes*; all-zero only
                                        // when no control op has been applied
      "cert": "<base64 certificate bytes>",
      "root_sig": "<base64 Ed25519(root_sk,
                    b'jeeves/member-register/v1' || cert_bytes)>"
    }

The chain link is a hash of the predecessor's **payload bytes** — the unframed
payload as ``envelope.parse_body`` returns it — not of the envelope and not of
any re-serialization.  Payload bytes stay readable and stable across suites,
control ops being unencrypted by design.  The price is that a chain link points
at bare bytes with no context, so **every control payload must be
self-identifying: the ``type`` field is mandatory in every control type, for
ever.**

The certificate is signed bytes, never re-serialized JSON (same stance as
``OpPayload.encode``): a verifier checks ``root_sig`` over the literal decoded
blob and only then parses it.  Its content is::

    {
      "workspace_id": "<uuid>",
      "member_id": "<uuid>",
      "member_kind": "device",
      "sign_pk": "<base64 32B Ed25519>",
      "sign_key_id": "<base64 8B>",
      "kex_pk": "<base64 32B X25519>",
      "kex_key_id": "<base64 8B>",
      "registered_at_hlc": [wall_ms, counter, "<hex32>"]
    }

**The domain string is the version.**  The cert JSON carries no version field:
any field addition or semantic change ships under a new signing domain
(``jeeves/member-register/v2``, …), so old certs stay verifiable under the old
domain and a downgrade is a signature failure rather than a parsing ambiguity.

``role``, ``valid_from_epoch`` and ``granter`` are deliberately absent: role and
provenance are Grant facts (#549), and every cert minted here is implicitly
epoch-0 because epoch machinery does not exist yet.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import re
import uuid
from dataclasses import dataclass
from typing import Any, Final

from nacl.exceptions import BadSignatureError
from nacl.signing import SigningKey, VerifyKey

from app.sync.envelope import (
    AUTHOR_KEY_ID_BYTES,
    SIGN_PUBLIC_KEY_BYTES,
    derive_key_id,
)
from app.sync.op_payload import CANONICAL_UUID_PATTERN, Hlc

#: Every signing use of the Root key is domain-separated (review F7).
SIGNING_DOMAIN_MEMBER_REGISTER_V1: Final = b"jeeves/member-register/v1"

#: The one control type this slice serves.  #549 opens up the rest.
CONTROL_TYPE_MEMBER_REGISTER: Final = "member_register"
SERVED_CONTROL_TYPES: Final[frozenset[str]] = frozenset({CONTROL_TYPE_MEMBER_REGISTER})

#: Members that are a Device.  A Service member (#future) is the same cert with
#: a different kind, which is why the field exists before a second value does.
MEMBER_KIND_DEVICE: Final = "device"

PREV_CONTROL_HASH_BYTES: Final = 32
ZERO_PREV_CONTROL_HASH: Final = bytes(PREV_CONTROL_HASH_BYTES)
#: Raw X25519 public key width.  Separate from the signing key per F8/F19.
KEX_PUBLIC_KEY_BYTES: Final = 32
ROOT_SIGNATURE_BYTES: Final = 64

_HEX64_PATTERN: Final = re.compile(r"^[0-9a-f]{64}$")


class ControlPayloadError(Exception):
    """Base class for every fail-closed control-payload rejection.

    ``reason`` is the machine code shared with the Dart codec, the golden
    vectors and the route's structured error details.
    """

    reason: str = "malformed_control_payload"


class MalformedControlPayloadError(ControlPayloadError):
    reason = "malformed_control_payload"


class UnsupportedControlTypeError(ControlPayloadError):
    reason = "unsupported_control_type"

    def __init__(self, observed_type: str) -> None:
        super().__init__(f"control type {observed_type!r} is not served")
        self.observed_type = observed_type


class BadRootSignatureError(ControlPayloadError):
    reason = "bad_root_signature"


def control_payload_hash(payload_bytes: bytes) -> bytes:
    """SHA-256 over a control op's payload bytes — the cross-author chain link."""
    return hashlib.sha256(payload_bytes).digest()


def _require_base64(raw: Any, what: str) -> bytes:
    if not isinstance(raw, str):
        raise MalformedControlPayloadError(f"{what} must be a base64 string")
    try:
        return base64.b64decode(raw, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise MalformedControlPayloadError(f"{what} is not valid base64") from exc


def _require_key(raw: Any, what: str, expected_bytes: int) -> bytes:
    decoded = _require_base64(raw, what)
    if len(decoded) != expected_bytes:
        raise MalformedControlPayloadError(f"{what} must be {expected_bytes} bytes")
    return decoded


def _require_canonical_uuid(raw: Any, what: str) -> uuid.UUID:
    if not isinstance(raw, str) or not CANONICAL_UUID_PATTERN.match(raw):
        raise MalformedControlPayloadError(f"{what} must be a canonical lowercase UUID")
    return uuid.UUID(raw)


@dataclass(frozen=True, slots=True)
class RegistrationCertificate:
    """Root's statement that a Member's keys are that Member's keys."""

    workspace_id: uuid.UUID
    member_id: uuid.UUID
    sign_pk: bytes
    kex_pk: bytes
    registered_at_hlc: Hlc
    member_kind: str = MEMBER_KIND_DEVICE

    @property
    def sign_key_id(self) -> bytes:
        return derive_key_id(self.sign_pk)

    @property
    def kex_key_id(self) -> bytes:
        """Same derivation as the signing key id, over the KEX key.

        Carried explicitly in the cert so #549/#554 can rotate either key
        independently (F8) without changing the cert shape.
        """
        return hashlib.sha256(self.kex_pk).digest()[:AUTHOR_KEY_ID_BYTES]

    def to_json_dict(self) -> dict[str, Any]:
        return {
            "workspace_id": str(self.workspace_id),
            "member_id": str(self.member_id),
            "member_kind": self.member_kind,
            "sign_pk": base64.b64encode(self.sign_pk).decode("ascii"),
            "sign_key_id": base64.b64encode(self.sign_key_id).decode("ascii"),
            "kex_pk": base64.b64encode(self.kex_pk).decode("ascii"),
            "kex_key_id": base64.b64encode(self.kex_key_id).decode("ascii"),
            "registered_at_hlc": self.registered_at_hlc.to_json(),
        }

    def encode(self) -> bytes:
        """UTF-8 JSON.  These are the bytes Root signs and a verifier hashes —
        never a re-serialization of the parsed form."""
        return json.dumps(self.to_json_dict(), separators=(",", ":")).encode("utf-8")

    @classmethod
    def decode(cls, cert_bytes: bytes) -> RegistrationCertificate:
        try:
            raw = json.loads(cert_bytes.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise MalformedControlPayloadError("cert is not UTF-8 JSON") from exc
        if not isinstance(raw, dict):
            raise MalformedControlPayloadError("cert must be a JSON object")

        member_kind = raw.get("member_kind")
        if not isinstance(member_kind, str) or not member_kind:
            raise MalformedControlPayloadError("cert member_kind must be a non-empty string")

        sign_pk = _require_key(raw.get("sign_pk"), "cert sign_pk", SIGN_PUBLIC_KEY_BYTES)
        kex_pk = _require_key(raw.get("kex_pk"), "cert kex_pk", KEX_PUBLIC_KEY_BYTES)
        certificate = cls(
            workspace_id=_require_canonical_uuid(raw.get("workspace_id"), "cert workspace_id"),
            member_id=_require_canonical_uuid(raw.get("member_id"), "cert member_id"),
            sign_pk=sign_pk,
            kex_pk=kex_pk,
            registered_at_hlc=_decode_hlc(raw.get("registered_at_hlc")),
            member_kind=member_kind,
        )
        # The ids are derivations, so a claim that disagrees with the derivation
        # is a forgery attempt, not a variant spelling.
        if _require_key(raw.get("sign_key_id"), "cert sign_key_id", AUTHOR_KEY_ID_BYTES) != (
            certificate.sign_key_id
        ):
            raise MalformedControlPayloadError("cert sign_key_id is not derived from sign_pk")
        if _require_key(raw.get("kex_key_id"), "cert kex_key_id", AUTHOR_KEY_ID_BYTES) != (
            certificate.kex_key_id
        ):
            raise MalformedControlPayloadError("cert kex_key_id is not derived from kex_pk")
        return certificate


def _decode_hlc(raw: Any) -> Hlc:
    try:
        return Hlc.from_json(raw)
    except Exception as exc:  # noqa: BLE001 — remap to the control vocabulary
        raise MalformedControlPayloadError(f"cert registered_at_hlc is malformed: {exc}") from exc


@dataclass(frozen=True, slots=True)
class ControlPayload:
    """A parsed control op body.

    ``cert_bytes``/``root_sig`` are populated only for ``member_register``; a
    payload of any other type parses far enough to name its type and its chain
    link, and is then refused by whoever required a served type.
    """

    control_type: str
    prev_control_hash: bytes
    cert_bytes: bytes = b""
    root_sig: bytes = b""

    def to_json_dict(self) -> dict[str, Any]:
        return {
            "type": self.control_type,
            "prev_control_hash": self.prev_control_hash.hex(),
            "cert": base64.b64encode(self.cert_bytes).decode("ascii"),
            "root_sig": base64.b64encode(self.root_sig).decode("ascii"),
        }

    def encode(self) -> bytes:
        return json.dumps(self.to_json_dict(), separators=(",", ":")).encode("utf-8")

    @classmethod
    def decode(cls, payload: bytes) -> ControlPayload:
        try:
            raw = json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise MalformedControlPayloadError("control payload is not UTF-8 JSON") from exc
        if not isinstance(raw, dict):
            raise MalformedControlPayloadError("control payload must be a JSON object")

        control_type = raw.get("type")
        if not isinstance(control_type, str) or not control_type:
            raise MalformedControlPayloadError("control payload type must be a non-empty string")

        prev_control_hash = raw.get("prev_control_hash")
        if not isinstance(prev_control_hash, str) or not _HEX64_PATTERN.match(prev_control_hash):
            raise MalformedControlPayloadError(
                "prev_control_hash must be 64 lowercase hex characters"
            )

        if control_type != CONTROL_TYPE_MEMBER_REGISTER:
            # Nothing beyond the self-identifying fields is defined for a type
            # this build does not serve; refusing it is the caller's job.
            return cls(
                control_type=control_type,
                prev_control_hash=bytes.fromhex(prev_control_hash),
            )

        root_sig = _require_base64(raw.get("root_sig"), "root_sig")
        if len(root_sig) != ROOT_SIGNATURE_BYTES:
            raise MalformedControlPayloadError(f"root_sig must be {ROOT_SIGNATURE_BYTES} bytes")
        cert_bytes = _require_base64(raw.get("cert"), "cert")
        if not cert_bytes:
            raise MalformedControlPayloadError("cert must not be empty")
        return cls(
            control_type=control_type,
            prev_control_hash=bytes.fromhex(prev_control_hash),
            cert_bytes=cert_bytes,
            root_sig=root_sig,
        )

    def certificate(self) -> RegistrationCertificate:
        """Parse the certificate blob.

        Only meaningful *after* ``verify_registration_certificate`` has checked
        Root's signature over the literal bytes — parsing first would be reading
        an unauthenticated document.
        """
        return RegistrationCertificate.decode(self.cert_bytes)

    def require_served_type(self) -> None:
        if self.control_type not in SERVED_CONTROL_TYPES:
            raise UnsupportedControlTypeError(self.control_type)


def registration_signing_input(cert_bytes: bytes) -> bytes:
    return SIGNING_DOMAIN_MEMBER_REGISTER_V1 + cert_bytes


def sign_registration_certificate(cert_bytes: bytes, root_signing_key: SigningKey) -> bytes:
    return root_signing_key.sign(registration_signing_input(cert_bytes)).signature


def verify_registration_certificate(cert_bytes: bytes, root_sig: bytes, root_pk: bytes) -> None:
    """Raise ``BadRootSignatureError`` unless Root signed exactly these bytes."""
    try:
        VerifyKey(root_pk).verify(registration_signing_input(cert_bytes), root_sig)
    except (BadSignatureError, ValueError) as exc:
        raise BadRootSignatureError("Root signature over the certificate does not verify") from exc
