"""The ``op_class=2`` control payload format and its four certificates.

Control ops are the one part of the log the server *does* read.  That is
deliberate (ADR-0028, security review F2): content is opaque to the server for
ever, but membership and authority have to be checkable by whoever is holding
the bytes, so control payloads are unencrypted and self-describing.

Four served types, all sharing the same two mandatory fields::

    {"type": "member_register",  "prev_control_hash": "<hex64>",
     "cert": "<base64>", "root_sig": "<base64>"}

    {"type": "workspace_genesis", "prev_control_hash": "<hex64>",
     "cert": "<base64>", "root_sig": "<base64>"}

    {"type": "grant",  "prev_control_hash": "<hex64>",
     "cert": "<base64>", "granter_sig": "<base64>", "granter": "root"|"<uuid>"}

    {"type": "revoke", "prev_control_hash": "<hex64>",
     "cert": "<base64>", "revoker_sig": "<base64>", "revoker": "root"|"<uuid>"}

The chain link is a hash of the predecessor's **payload bytes** — the unframed
payload as ``envelope.parse_body`` returns it — not of the envelope and not of
any re-serialization.  Payload bytes stay readable and stable across suites,
control ops being unencrypted by design.  The price is that a chain link points
at bare bytes with no context, so **every control payload must be
self-identifying: the ``type`` field is mandatory in every control type, for
ever.**

An **all-zero ``prev_control_hash`` is genesis-only** (ADR-0031).  A
``member_register`` — or a grant, or a revoke — carrying a zero link is refused
even by a receiver whose control state is empty, so a fresh device served a
truncated history always detects it.  The corollary: any pre-genesis dev-era log
(one that opens with a zero-link ``member_register``) is permanently unadoptable.
That was acceptable because no store the server had ever seen predated the #553
cutover — every op-log store shipped empty and the ones that could hold
pre-genesis rows were disposable dev and harness stores.  Since #591 the op log
**is** the production sync path: a device's store is authored into on enrolment
and is no longer disposable, so a pre-genesis log is now a store to be recreated
rather than a rounding error.

Every certificate is **signed bytes, never re-serialized JSON** (same stance as
``OpPayload.encode``): a verifier checks the signature over the literal decoded
blob and only then parses it.

**The domain string is the version.**  No cert JSON carries a version field: any
field addition or semantic change ships under a new signing domain
(``jeeves/grant/v2``, …), so old certs stay verifiable under the old domain and a
downgrade is a signature failure rather than a parsing ambiguity.

**Authority ceilings.**  A Grant whose ``role`` is ``owner`` may only be minted
with ``granter == "root"``, and a Grant whose role is ``owner`` may only be
revoked with ``revoker == "root"``.  The pairing is deliberately symmetric — see
ADR-0031 for why an owner-mints-owner rule would favour an attacker.
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
    OP_CLASS_CONTROL,
    OP_CLASS_PRUNE,
    SIGN_PUBLIC_KEY_BYTES,
    derive_key_id,
)
from app.sync.escrow import ROOT_PUBLIC_KEY_BYTES, ROOT_SIGNATURE_BYTES
from app.sync.op_payload import CANONICAL_UUID_PATTERN, Hlc

#: Every signing use of the Root key is domain-separated (review F7).
SIGNING_DOMAIN_MEMBER_REGISTER_V1: Final = b"jeeves/member-register/v1"
SIGNING_DOMAIN_WORKSPACE_GENESIS_V1: Final = b"jeeves/workspace-genesis/v1"
SIGNING_DOMAIN_GRANT_V1: Final = b"jeeves/grant/v1"
SIGNING_DOMAIN_REVOKE_V1: Final = b"jeeves/revoke/v1"

CONTROL_TYPE_MEMBER_REGISTER: Final = "member_register"
CONTROL_TYPE_WORKSPACE_GENESIS: Final = "workspace_genesis"
CONTROL_TYPE_GRANT: Final = "grant"
CONTROL_TYPE_REVOKE: Final = "revoke"

#: The control types this build serves.  ``rotate``/``member_key_rotate`` are
#: #554's and stay fail-closed.
SERVED_CONTROL_TYPES: Final[frozenset[str]] = frozenset(
    {
        CONTROL_TYPE_MEMBER_REGISTER,
        CONTROL_TYPE_WORKSPACE_GENESIS,
        CONTROL_TYPE_GRANT,
        CONTROL_TYPE_REVOKE,
    }
)

#: Members that are a Device.  A Service member (#557) is the same cert with a
#: different kind; the ``user_preferences`` Workspace refuses Grants to anything
#: that is not a Device, which is what makes "no Service ever" structural.
MEMBER_KIND_DEVICE: Final = "device"
MEMBER_KIND_SERVICE: Final = "service"

# --- Roles ------------------------------------------------------------------

ROLE_OWNER: Final = "owner"
ROLE_PARTICIPANT: Final = "participant"
ROLE_COMPACTOR: Final = "compactor"
ROLE_SUGGESTER: Final = "suggester"
#: Every role a Grant may carry.  An unknown role fails closed on both sides.
KNOWN_ROLES: Final[tuple[str, ...]] = (
    ROLE_OWNER,
    ROLE_PARTICIPANT,
    ROLE_COMPACTOR,
    ROLE_SUGGESTER,
)

#: The ``granter``/``revoker`` value meaning "the pinned Root itself".  A member
#: id is the only other legal value, and ``"root"`` is not a UUID, so the two
#: cases can never be confused.
GRANTER_ROOT: Final = "root"

#: Which ``(role, op_class)`` pairs a role admits.  Rows for op classes this
#: build does not *serve* are defined here anyway, so #555 and #557 turn a class
#: on by widening ``SERVED_OP_CLASSES`` rather than by inventing a policy.
ROLE_OP_CLASS_MATRIX: Final[dict[int, frozenset[str]]] = {
    1: frozenset({ROLE_OWNER, ROLE_PARTICIPANT}),  # content
    2: frozenset({ROLE_OWNER}),  # control, when not root-signed
    3: frozenset(KNOWN_ROLES),  # suggestion — defined, unserved until #557
    4: frozenset({ROLE_OWNER, ROLE_COMPACTOR}),  # compaction — unserved until #555
    5: frozenset({ROLE_OWNER, ROLE_COMPACTOR}),  # prune — unserved until #555
}

#: Op classes a compaction pass must carry forward verbatim rather than fold.
#:
#: Control ops are the authority record: compacting one away would delete the
#: evidence a Grant ever existed, and a prune op is itself the attestation that
#: history was removed.  #555 enforces this; the predicate lives here so both
#: codecs and the vectors pin the same rule before prune exists.
COMPACTION_EXEMPT_OP_CLASSES: Final[frozenset[int]] = frozenset({OP_CLASS_CONTROL, OP_CLASS_PRUNE})


def is_compaction_exempt(op_class: int) -> bool:
    """Whether ``op_class`` is never folded into a compaction op (#555)."""
    return op_class in COMPACTION_EXEMPT_OP_CLASSES


PREV_CONTROL_HASH_BYTES: Final = 32
ZERO_PREV_CONTROL_HASH: Final = bytes(PREV_CONTROL_HASH_BYTES)
#: Raw X25519 public key width.  Separate from the signing key per F8/F19.
KEX_PUBLIC_KEY_BYTES: Final = 32
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


class BadGrantSignatureError(ControlPayloadError):
    reason = "bad_grant_signature"


class BadRevokeSignatureError(ControlPayloadError):
    reason = "bad_revoke_signature"


class UnknownRoleError(ControlPayloadError):
    reason = "unknown_role"


class ControlChainBreakError(ControlPayloadError):
    reason = "control_chain_break"


class OwnerGrantRequiresRootError(ControlPayloadError):
    reason = "owner_grant_requires_root"


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


def _require_authority(raw: Any, what: str) -> str:
    """``"root"`` or a canonical member uuid — the two authorities there are."""
    if raw == GRANTER_ROOT:
        return GRANTER_ROOT
    if not isinstance(raw, str) or not CANONICAL_UUID_PATTERN.match(raw):
        raise MalformedControlPayloadError(
            f'{what} must be "{GRANTER_ROOT}" or a canonical lowercase member UUID'
        )
    return raw


def _decode_hlc(raw: Any, what: str) -> Hlc:
    try:
        return Hlc.from_json(raw)
    except Exception as exc:  # noqa: BLE001 — remap to the control vocabulary
        raise MalformedControlPayloadError(f"{what} is malformed: {exc}") from exc


def _kex_key_id(kex_pk: bytes) -> bytes:
    """The same derivation as the signing key id, over the KEX key."""
    return hashlib.sha256(kex_pk).digest()[:AUTHOR_KEY_ID_BYTES]


# --- MemberRegister ---------------------------------------------------------


@dataclass(frozen=True, slots=True)
class MemberKeys:
    """One Member's certified public keys — the block a registration carries.

    Shared verbatim by ``member_register`` (at the top level of its cert) and by
    ``workspace_genesis`` (under ``founder``), because genesis *is* the founding
    Device's registration: the envelope's author key has to be learnable from the
    payload itself, and there is no earlier op to learn it from (ADR-0031).
    """

    member_id: uuid.UUID
    sign_pk: bytes
    kex_pk: bytes
    member_kind: str = MEMBER_KIND_DEVICE

    @property
    def sign_key_id(self) -> bytes:
        return derive_key_id(self.sign_pk)

    @property
    def kex_key_id(self) -> bytes:
        """Carried explicitly so #554 can rotate either key independently (F8)."""
        return _kex_key_id(self.kex_pk)

    def to_json_dict(self) -> dict[str, Any]:
        return {
            "member_id": str(self.member_id),
            "member_kind": self.member_kind,
            "sign_pk": base64.b64encode(self.sign_pk).decode("ascii"),
            "sign_key_id": base64.b64encode(self.sign_key_id).decode("ascii"),
            "kex_pk": base64.b64encode(self.kex_pk).decode("ascii"),
            "kex_key_id": base64.b64encode(self.kex_key_id).decode("ascii"),
        }

    @classmethod
    def from_json_dict(cls, raw: Any, what: str) -> MemberKeys:
        if not isinstance(raw, dict):
            raise MalformedControlPayloadError(f"{what} must be a JSON object")
        member_kind = raw.get("member_kind")
        if not isinstance(member_kind, str) or not member_kind:
            raise MalformedControlPayloadError(f"{what} member_kind must be a non-empty string")
        keys = cls(
            member_id=_require_canonical_uuid(raw.get("member_id"), f"{what} member_id"),
            sign_pk=_require_key(raw.get("sign_pk"), f"{what} sign_pk", SIGN_PUBLIC_KEY_BYTES),
            kex_pk=_require_key(raw.get("kex_pk"), f"{what} kex_pk", KEX_PUBLIC_KEY_BYTES),
            member_kind=member_kind,
        )
        # The ids are derivations, so a claim that disagrees with the derivation
        # is a forgery attempt, not a variant spelling.
        if (
            _require_key(raw.get("sign_key_id"), f"{what} sign_key_id", AUTHOR_KEY_ID_BYTES)
            != keys.sign_key_id
        ):
            raise MalformedControlPayloadError(f"{what} sign_key_id is not derived from sign_pk")
        if (
            _require_key(raw.get("kex_key_id"), f"{what} kex_key_id", AUTHOR_KEY_ID_BYTES)
            != keys.kex_key_id
        ):
            raise MalformedControlPayloadError(f"{what} kex_key_id is not derived from kex_pk")
        return keys


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
    def keys(self) -> MemberKeys:
        return MemberKeys(
            member_id=self.member_id,
            sign_pk=self.sign_pk,
            kex_pk=self.kex_pk,
            member_kind=self.member_kind,
        )

    @property
    def sign_key_id(self) -> bytes:
        return derive_key_id(self.sign_pk)

    @property
    def kex_key_id(self) -> bytes:
        return _kex_key_id(self.kex_pk)

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
        raw = _decode_cert_json(cert_bytes)
        keys = MemberKeys.from_json_dict(raw, "cert")
        return cls(
            workspace_id=_require_canonical_uuid(raw.get("workspace_id"), "cert workspace_id"),
            member_id=keys.member_id,
            sign_pk=keys.sign_pk,
            kex_pk=keys.kex_pk,
            registered_at_hlc=_decode_hlc(raw.get("registered_at_hlc"), "cert registered_at_hlc"),
            member_kind=keys.member_kind,
        )


def _decode_cert_json(cert_bytes: bytes) -> dict[str, Any]:
    try:
        raw = json.loads(cert_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MalformedControlPayloadError("cert is not UTF-8 JSON") from exc
    if not isinstance(raw, dict):
        raise MalformedControlPayloadError("cert must be a JSON object")
    return raw


# --- Workspace genesis ------------------------------------------------------


@dataclass(frozen=True, slots=True)
class GenesisCertificate:
    """Root's statement that a Workspace exists, and who founded it.

    ``root_pk`` inside the signed bytes gives every later verifier a log-internal
    cross-check against the Root it pinned, and makes the genesis
    self-describing for a future shared-Workspace reader.  ``founder`` *is* a
    registration: the founding Device authors no separate ``member_register``
    (ADR-0031).  Per F14(d) the founder is merely the first owner — revoking it
    later invalidates nothing.
    """

    workspace_id: uuid.UUID
    root_pk: bytes
    founder: MemberKeys
    created_at_hlc: Hlc

    def to_json_dict(self) -> dict[str, Any]:
        return {
            "workspace_id": str(self.workspace_id),
            "root_pk": base64.b64encode(self.root_pk).decode("ascii"),
            "founder": self.founder.to_json_dict(),
            "created_at_hlc": self.created_at_hlc.to_json(),
        }

    def encode(self) -> bytes:
        return json.dumps(self.to_json_dict(), separators=(",", ":")).encode("utf-8")

    @classmethod
    def decode(cls, cert_bytes: bytes) -> GenesisCertificate:
        raw = _decode_cert_json(cert_bytes)
        return cls(
            workspace_id=_require_canonical_uuid(raw.get("workspace_id"), "cert workspace_id"),
            root_pk=_require_key(raw.get("root_pk"), "cert root_pk", ROOT_PUBLIC_KEY_BYTES),
            founder=MemberKeys.from_json_dict(raw.get("founder"), "cert founder"),
            created_at_hlc=_decode_hlc(raw.get("created_at_hlc"), "cert created_at_hlc"),
        )

    def as_registration(self) -> RegistrationCertificate:
        """The founder's registration, as the directory learns it.

        Genesis is the founding Device's ``member_register``; this is the same
        fact in the shape every other member's arrives in.
        """
        return RegistrationCertificate(
            workspace_id=self.workspace_id,
            member_id=self.founder.member_id,
            sign_pk=self.founder.sign_pk,
            kex_pk=self.founder.kex_pk,
            registered_at_hlc=self.created_at_hlc,
            member_kind=self.founder.member_kind,
        )


# --- Grant and Revoke -------------------------------------------------------


@dataclass(frozen=True, slots=True)
class GrantCertificate:
    """One authority fact: this Member holds this role in this Workspace.

    Grant-granular by construction: a Member may hold several, and a Revoke names
    one ``grant_id`` rather than a member (F19 keeps member-revocation and
    grant-revocation distinct).  No key material — the Grant/KeyWrap split is
    physical, which is what lets #554 land rotation without touching this shape.
    """

    workspace_id: uuid.UUID
    grant_id: uuid.UUID
    member_id: uuid.UUID
    role: str
    granter: str
    granted_at_hlc: Hlc

    def to_json_dict(self) -> dict[str, Any]:
        return {
            "workspace_id": str(self.workspace_id),
            "grant_id": str(self.grant_id),
            "member_id": str(self.member_id),
            "role": self.role,
            "granter": self.granter,
            "granted_at_hlc": self.granted_at_hlc.to_json(),
        }

    def encode(self) -> bytes:
        return json.dumps(self.to_json_dict(), separators=(",", ":")).encode("utf-8")

    @classmethod
    def decode(cls, cert_bytes: bytes) -> GrantCertificate:
        raw = _decode_cert_json(cert_bytes)
        role = raw.get("role")
        if not isinstance(role, str) or role not in KNOWN_ROLES:
            raise UnknownRoleError(f"grant role {role!r} is not one of {list(KNOWN_ROLES)}")
        granter = _require_authority(raw.get("granter"), "cert granter")
        if role == ROLE_OWNER and granter != GRANTER_ROOT:
            # The mint half of the owner ceiling, and a **pure document
            # invariant**: a certificate claiming ``role: owner`` under any
            # granter but Root is not a Grant a verifier could ever honour, so it
            # is refused at decode rather than deeper in whoever happens to be
            # holding it.  ADR-0031 records why the ceiling is symmetric with
            # revocation.  (The *revoke* half needs the target Grant's role,
            # which is receiver state and not in these bytes, so it lives in the
            # route and in the client's authorization stage.)
            raise OwnerGrantRequiresRootError(
                f"an owner Grant may only be minted with granter {GRANTER_ROOT!r}, not {granter!r}"
            )
        return cls(
            workspace_id=_require_canonical_uuid(raw.get("workspace_id"), "cert workspace_id"),
            grant_id=_require_canonical_uuid(raw.get("grant_id"), "cert grant_id"),
            member_id=_require_canonical_uuid(raw.get("member_id"), "cert member_id"),
            role=role,
            granter=granter,
            granted_at_hlc=_decode_hlc(raw.get("granted_at_hlc"), "cert granted_at_hlc"),
        )


@dataclass(frozen=True, slots=True)
class RevokeCertificate:
    """The unmaking of one Grant, named by ``grant_id``."""

    workspace_id: uuid.UUID
    revoke_id: uuid.UUID
    grant_id: uuid.UUID
    revoker: str
    revoked_at_hlc: Hlc

    def to_json_dict(self) -> dict[str, Any]:
        return {
            "workspace_id": str(self.workspace_id),
            "revoke_id": str(self.revoke_id),
            "grant_id": str(self.grant_id),
            "revoker": self.revoker,
            "revoked_at_hlc": self.revoked_at_hlc.to_json(),
        }

    def encode(self) -> bytes:
        return json.dumps(self.to_json_dict(), separators=(",", ":")).encode("utf-8")

    @classmethod
    def decode(cls, cert_bytes: bytes) -> RevokeCertificate:
        raw = _decode_cert_json(cert_bytes)
        return cls(
            workspace_id=_require_canonical_uuid(raw.get("workspace_id"), "cert workspace_id"),
            revoke_id=_require_canonical_uuid(raw.get("revoke_id"), "cert revoke_id"),
            grant_id=_require_canonical_uuid(raw.get("grant_id"), "cert grant_id"),
            revoker=_require_authority(raw.get("revoker"), "cert revoker"),
            revoked_at_hlc=_decode_hlc(raw.get("revoked_at_hlc"), "cert revoked_at_hlc"),
        )


# --- The payload envelope ---------------------------------------------------


@dataclass(frozen=True, slots=True)
class ControlPayload:
    """A parsed control op body.

    One class for four types, because the two mandatory fields — ``type`` and
    ``prev_control_hash`` — are the whole of what a receiver may read before it
    knows which type it is holding.  ``signature`` carries whichever of
    ``root_sig``/``granter_sig``/``revoker_sig`` the type names, and ``authority``
    carries ``granter``/``revoker`` (``""`` for the two Root-only types, whose
    authority is Root by definition).
    """

    control_type: str
    prev_control_hash: bytes
    cert_bytes: bytes = b""
    signature: bytes = b""
    authority: str = ""

    @property
    def root_sig(self) -> bytes:
        """The Root signature, for the two types whose signer is always Root."""
        return self.signature

    @property
    def is_root_signed(self) -> bool:
        """Whether this payload's authority is the pinned Root itself.

        The server's control-op admission rule reads this: a Root-signed control
        payload lands regardless of the author's Grants, which is how the
        register-plus-grant batch of an ungranted device gets in at all.
        """
        return self.control_type in _ROOT_ONLY_CONTROL_TYPES or self.authority == GRANTER_ROOT

    def to_json_dict(self) -> dict[str, Any]:
        base: dict[str, Any] = {
            "type": self.control_type,
            "prev_control_hash": self.prev_control_hash.hex(),
            "cert": base64.b64encode(self.cert_bytes).decode("ascii"),
        }
        signature_field, authority_field = _SIGNATURE_FIELDS.get(
            self.control_type, ("root_sig", None)
        )
        base[signature_field] = base64.b64encode(self.signature).decode("ascii")
        if authority_field is not None:
            base[authority_field] = self.authority
        return base

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

        if control_type not in SERVED_CONTROL_TYPES:
            # Nothing beyond the self-identifying fields is defined for a type
            # this build does not serve; refusing it is the caller's job.
            return cls(
                control_type=control_type,
                prev_control_hash=bytes.fromhex(prev_control_hash),
            )

        signature_field, authority_field = _SIGNATURE_FIELDS[control_type]
        signature = _require_base64(raw.get(signature_field), signature_field)
        if len(signature) != ROOT_SIGNATURE_BYTES:
            raise MalformedControlPayloadError(
                f"{signature_field} must be {ROOT_SIGNATURE_BYTES} bytes"
            )
        cert_bytes = _require_base64(raw.get("cert"), "cert")
        if not cert_bytes:
            raise MalformedControlPayloadError("cert must not be empty")
        authority = (
            GRANTER_ROOT
            if authority_field is None
            else _require_authority(raw.get(authority_field), authority_field)
        )
        return cls(
            control_type=control_type,
            prev_control_hash=bytes.fromhex(prev_control_hash),
            cert_bytes=cert_bytes,
            signature=signature,
            authority=authority,
        )

    def certificate(self) -> RegistrationCertificate:
        """Parse a ``member_register`` certificate blob.

        Only meaningful *after* ``verify_registration_certificate`` has checked
        Root's signature over the literal bytes — parsing first would be reading
        an unauthenticated document.  The same applies to every sibling below.
        """
        return RegistrationCertificate.decode(self.cert_bytes)

    def genesis_certificate(self) -> GenesisCertificate:
        return GenesisCertificate.decode(self.cert_bytes)

    def grant_certificate(self) -> GrantCertificate:
        return GrantCertificate.decode(self.cert_bytes)

    def revoke_certificate(self) -> RevokeCertificate:
        return RevokeCertificate.decode(self.cert_bytes)

    def require_served_type(self) -> None:
        if self.control_type not in SERVED_CONTROL_TYPES:
            raise UnsupportedControlTypeError(self.control_type)

    def require_chain_link_shape(self) -> None:
        """The genesis-only zero-link rule, both ways, as a payload-level check.

        Stateless and therefore checkable by the server, which keeps no control
        chain of its own.  Only a ``workspace_genesis`` may carry a zero link — so
        every other type carrying one is a truncated-history claim — and a genesis
        may carry *nothing else*, because it is by definition the Workspace's
        first control op.
        """
        is_genesis = self.control_type == CONTROL_TYPE_WORKSPACE_GENESIS
        is_zero = self.prev_control_hash == ZERO_PREV_CONTROL_HASH
        if is_zero and not is_genesis:
            raise ControlChainBreakError(
                f"an all-zero prev_control_hash is genesis-only; {self.control_type} "
                "must name the control op before it"
            )
        if is_genesis and not is_zero:
            raise ControlChainBreakError(
                "a workspace_genesis is the Workspace's first control op, so it "
                "must carry the all-zero prev_control_hash"
            )


#: ``control_type -> (signature field, authority field or None)``.
_SIGNATURE_FIELDS: Final[dict[str, tuple[str, str | None]]] = {
    CONTROL_TYPE_MEMBER_REGISTER: ("root_sig", None),
    CONTROL_TYPE_WORKSPACE_GENESIS: ("root_sig", None),
    CONTROL_TYPE_GRANT: ("granter_sig", "granter"),
    CONTROL_TYPE_REVOKE: ("revoker_sig", "revoker"),
}

#: The types whose signer is Root and nobody else.
_ROOT_ONLY_CONTROL_TYPES: Final[frozenset[str]] = frozenset(
    {CONTROL_TYPE_MEMBER_REGISTER, CONTROL_TYPE_WORKSPACE_GENESIS}
)


# --- Signing and verification ----------------------------------------------


def registration_signing_input(cert_bytes: bytes) -> bytes:
    return SIGNING_DOMAIN_MEMBER_REGISTER_V1 + cert_bytes


def genesis_signing_input(cert_bytes: bytes) -> bytes:
    return SIGNING_DOMAIN_WORKSPACE_GENESIS_V1 + cert_bytes


def grant_signing_input(cert_bytes: bytes) -> bytes:
    return SIGNING_DOMAIN_GRANT_V1 + cert_bytes


def revoke_signing_input(cert_bytes: bytes) -> bytes:
    return SIGNING_DOMAIN_REVOKE_V1 + cert_bytes


def sign_registration_certificate(cert_bytes: bytes, root_signing_key: SigningKey) -> bytes:
    return root_signing_key.sign(registration_signing_input(cert_bytes)).signature


def sign_genesis_certificate(cert_bytes: bytes, root_signing_key: SigningKey) -> bytes:
    return root_signing_key.sign(genesis_signing_input(cert_bytes)).signature


def sign_grant_certificate(cert_bytes: bytes, signing_key: SigningKey) -> bytes:
    """Signed by Root, or by an owning Member's own signing key."""
    return signing_key.sign(grant_signing_input(cert_bytes)).signature


def sign_revoke_certificate(cert_bytes: bytes, signing_key: SigningKey) -> bytes:
    return signing_key.sign(revoke_signing_input(cert_bytes)).signature


def _verify(signing_input: bytes, signature: bytes, public_key: bytes) -> bool:
    try:
        VerifyKey(public_key).verify(signing_input, signature)
    except (BadSignatureError, ValueError):
        return False
    return True


def verify_registration_certificate(cert_bytes: bytes, root_sig: bytes, root_pk: bytes) -> None:
    """Raise ``BadRootSignatureError`` unless Root signed exactly these bytes."""
    if not _verify(registration_signing_input(cert_bytes), root_sig, root_pk):
        raise BadRootSignatureError("Root signature over the certificate does not verify")


def verify_genesis_certificate(cert_bytes: bytes, root_sig: bytes, root_pk: bytes) -> None:
    if not _verify(genesis_signing_input(cert_bytes), root_sig, root_pk):
        raise BadRootSignatureError("Root signature over the genesis certificate does not verify")


def verify_grant_certificate(cert_bytes: bytes, granter_sig: bytes, granter_pk: bytes) -> None:
    if not _verify(grant_signing_input(cert_bytes), granter_sig, granter_pk):
        raise BadGrantSignatureError("the granter's signature over the Grant does not verify")


def verify_revoke_certificate(cert_bytes: bytes, revoker_sig: bytes, revoker_pk: bytes) -> None:
    if not _verify(revoke_signing_input(cert_bytes), revoker_sig, revoker_pk):
        raise BadRevokeSignatureError("the revoker's signature over the Revoke does not verify")
