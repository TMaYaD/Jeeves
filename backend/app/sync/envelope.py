"""v1 op envelope codec — the protocol identity of the Minimal Sync Server.

The layout below is normative (proposal § Envelope, security review F6) and is
pinned byte-for-byte by ``spec/sync/envelope_v1_vectors.json``, which the Dart
codec in ``app/lib/sync/envelope.dart`` asserts against as well.  Any change
here that is not mirrored there is a protocol fork.

::

    header (canonical, fixed order; fixed-width fields, big-endian integers)
                              offset  size
      suite            u8        0      1   0x00 = plaintext_v1
      op_class         u8        1      1   1=content 2=control 3=suggestion
                                            4=compaction 5=prune
      workspace_id     16B       2     16
      key_epoch        u32      18      4
      op_id            16B      22     16
      author_member_id 16B      38     16
      author_key_id    8B       54      8
      author_seq       u64      62      8
      prev_author_hash 32B      70     32
      observed_head    32B     102     32   reserved, zero in v1
      nonce            24B     134     24   zero under suite 0x00
                            total = 158 bytes

    body      = u32 payload_len || payload || zero padding (see `frame_body`)
    signature = Ed25519(sk_author, b"jeeves/op/v1" || header || body)
    envelope  = header || body || signature

The header is constant width, so no per-field length prefixes are needed: the
envelope framing supplies the only variable length, ``body_len = len(envelope)
- ENVELOPE_OVERHEAD_BYTES``.

Under suite 0x01 (``aead_v1``, reserved for #554) the body becomes ciphertext
with AAD = the serialized header bytes, exactly.  Nothing else about the layout
changes, which is why the AAD is defined as the literal header today.
"""

from __future__ import annotations

import hashlib
import struct
import uuid
from dataclasses import dataclass
from typing import Final

from nacl.exceptions import BadSignatureError
from nacl.signing import SigningKey, VerifyKey

# --- Suites -----------------------------------------------------------------

#: plaintext_v1 — no AEAD, Ed25519 signature only.  The suite this slice serves.
SUITE_PLAINTEXT_V1: Final = 0x00
#: aead_v1 — XChaCha20-Poly1305 + Ed25519.  Reserved for #554, never served here.
SUITE_AEAD_V1: Final = 0x01
#: Suites this build implements.  Anything else is fail-closed (review F21).
SERVED_SUITES: Final[frozenset[int]] = frozenset({SUITE_PLAINTEXT_V1})

# --- Op classes -------------------------------------------------------------

OP_CLASS_CONTENT: Final = 1
OP_CLASS_CONTROL: Final = 2
OP_CLASS_SUGGESTION: Final = 3
OP_CLASS_COMPACTION: Final = 4
OP_CLASS_PRUNE: Final = 5
#: Every op class the protocol names.  Values outside this set are *unknown*;
#: values inside it but outside `SERVED_OP_CLASSES` are *not yet implemented*.
#: Both are fail-closed and indistinguishable to a receiver by design.
KNOWN_OP_CLASSES: Final[frozenset[int]] = frozenset(
    {
        OP_CLASS_CONTENT,
        OP_CLASS_CONTROL,
        OP_CLASS_SUGGESTION,
        OP_CLASS_COMPACTION,
        OP_CLASS_PRUNE,
    }
)
#: Op classes this build serves.  Control arrived with #548 and carries exactly
#: one type, ``member_register`` (see ``app.sync.control_payload``); every other
#: control type is still fail-closed.  Suggestion is #557, compaction/prune #555.
SERVED_OP_CLASSES: Final[frozenset[int]] = frozenset({OP_CLASS_CONTENT, OP_CLASS_CONTROL})

# --- Sizes ------------------------------------------------------------------

HEADER_LENGTH_BYTES: Final = 158
SIGNATURE_LENGTH_BYTES: Final = 64
ENVELOPE_OVERHEAD_BYTES: Final = HEADER_LENGTH_BYTES + SIGNATURE_LENGTH_BYTES  # 222

WORKSPACE_ID_BYTES: Final = 16
OP_ID_BYTES: Final = 16
AUTHOR_MEMBER_ID_BYTES: Final = 16
AUTHOR_KEY_ID_BYTES: Final = 8
PREV_AUTHOR_HASH_BYTES: Final = 32
OBSERVED_HEAD_BYTES: Final = 32
NONCE_BYTES: Final = 24
SIGN_PUBLIC_KEY_BYTES: Final = 32

#: Byte offset and width of every header field, in canonical order.  Exported so
#: the golden-vector generator and both test suites pin the same numbers.
HEADER_FIELD_LAYOUT: Final[tuple[tuple[str, int, int], ...]] = (
    ("suite", 0, 1),
    ("op_class", 1, 1),
    ("workspace_id", 2, WORKSPACE_ID_BYTES),
    ("key_epoch", 18, 4),
    ("op_id", 22, OP_ID_BYTES),
    ("author_member_id", 38, AUTHOR_MEMBER_ID_BYTES),
    ("author_key_id", 54, AUTHOR_KEY_ID_BYTES),
    ("author_seq", 62, 8),
    ("prev_author_hash", 70, PREV_AUTHOR_HASH_BYTES),
    ("observed_head", 102, OBSERVED_HEAD_BYTES),
    ("nonce", 134, NONCE_BYTES),
)

_HEADER_STRUCT: Final = struct.Struct(">BB16sI16s16s8sQ32s32s24s")

#: Every signing use of a member key is domain-separated (review F7).
SIGNING_DOMAIN_OP_V1: Final = b"jeeves/op/v1"

#: All-zero placeholders for the fields v1 reserves but does not use.
ZERO_OBSERVED_HEAD: Final = bytes(OBSERVED_HEAD_BYTES)
ZERO_NONCE: Final = bytes(NONCE_BYTES)
ZERO_PREV_AUTHOR_HASH: Final = bytes(PREV_AUTHOR_HASH_BYTES)

# --- Body framing (review F17) ----------------------------------------------

PAYLOAD_LENGTH_PREFIX_BYTES: Final = 4
#: Padded body sizes below the oversize threshold.
BODY_SIZE_CLASSES_BYTES: Final[tuple[int, ...]] = (256, 1024, 4096, 16384)
#: Above the largest size class a body rounds up to the next multiple of this,
#: with no hard cap — #550's notes fields can be large.
BODY_OVERSIZE_MULTIPLE_BYTES: Final = 16384

#: The shortest envelope that can possibly be well-formed: header ‖ the smallest
#: body size class ‖ signature.  Every legal body is padded up to a size class,
#: so ``ENVELOPE_OVERHEAD_BYTES + 1`` is not the floor — 256 is the smallest body
#: there is.  Derived rather than written out so the number cannot drift from the
#: padding rule it follows from.
MINIMUM_ENVELOPE_BYTES: Final = (
    HEADER_LENGTH_BYTES + BODY_SIZE_CLASSES_BYTES[0] + SIGNATURE_LENGTH_BYTES
)


# --- Failure surface --------------------------------------------------------


class EnvelopeError(Exception):
    """Base class for every fail-closed envelope rejection.

    ``reason`` is a stable machine code shared with the Dart codec and with the
    golden vectors, so both suites assert the *same* rejection, not merely
    "something threw".
    """

    reason: str = "malformed_envelope"


class TruncatedEnvelopeError(EnvelopeError):
    reason = "truncated_envelope"


class EnvelopeTooShortError(EnvelopeError):
    """Shorter than ``MINIMUM_ENVELOPE_BYTES``, so no legal body fits.

    Distinct from ``truncated_envelope``, which is about not reaching the fixed
    158-byte header.  This one is the framing floor, and it is the only body-
    shaped rule the *server* can apply while staying content-blind: it follows
    from the padding size classes alone and needs no byte of the body read.
    """

    reason = "envelope_too_short"


class UnsupportedSuiteError(EnvelopeError):
    reason = "unsupported_suite"


class UnsupportedOpClassError(EnvelopeError):
    reason = "unsupported_op_class"


class InvalidBodyLengthError(EnvelopeError):
    reason = "invalid_body_length"


class PayloadOverrunsBodyError(EnvelopeError):
    reason = "payload_overruns_body"


class NonZeroPaddingError(EnvelopeError):
    reason = "non_zero_padding"


class BadSignatureEnvelopeError(EnvelopeError):
    reason = "bad_signature"


class WorkspaceMismatchError(EnvelopeError):
    reason = "workspace_mismatch"


# --- Header -----------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class OpHeader:
    """The 158 fixed bytes every op carries in the clear."""

    suite: int
    op_class: int
    workspace_id: uuid.UUID
    key_epoch: int
    op_id: uuid.UUID
    author_member_id: uuid.UUID
    author_key_id: bytes
    author_seq: int
    prev_author_hash: bytes = ZERO_PREV_AUTHOR_HASH
    observed_head: bytes = ZERO_OBSERVED_HEAD
    nonce: bytes = ZERO_NONCE

    def serialize(self) -> bytes:
        if len(self.author_key_id) != AUTHOR_KEY_ID_BYTES:
            raise ValueError(f"author_key_id must be {AUTHOR_KEY_ID_BYTES} bytes")
        if len(self.prev_author_hash) != PREV_AUTHOR_HASH_BYTES:
            raise ValueError(f"prev_author_hash must be {PREV_AUTHOR_HASH_BYTES} bytes")
        if len(self.observed_head) != OBSERVED_HEAD_BYTES:
            raise ValueError(f"observed_head must be {OBSERVED_HEAD_BYTES} bytes")
        if len(self.nonce) != NONCE_BYTES:
            raise ValueError(f"nonce must be {NONCE_BYTES} bytes")
        return _HEADER_STRUCT.pack(
            self.suite,
            self.op_class,
            self.workspace_id.bytes,
            self.key_epoch,
            self.op_id.bytes,
            self.author_member_id.bytes,
            self.author_key_id,
            self.author_seq,
            self.prev_author_hash,
            self.observed_head,
            self.nonce,
        )

    @classmethod
    def parse(cls, raw: bytes) -> OpHeader:
        if len(raw) < HEADER_LENGTH_BYTES:
            raise TruncatedEnvelopeError(
                f"header is {len(raw)} bytes, expected {HEADER_LENGTH_BYTES}"
            )
        (
            suite,
            op_class,
            workspace_id,
            key_epoch,
            op_id,
            author_member_id,
            author_key_id,
            author_seq,
            prev_author_hash,
            observed_head,
            nonce,
        ) = _HEADER_STRUCT.unpack(raw[:HEADER_LENGTH_BYTES])
        return cls(
            suite=suite,
            op_class=op_class,
            workspace_id=uuid.UUID(bytes=workspace_id),
            key_epoch=key_epoch,
            op_id=uuid.UUID(bytes=op_id),
            author_member_id=uuid.UUID(bytes=author_member_id),
            author_key_id=author_key_id,
            author_seq=author_seq,
            prev_author_hash=prev_author_hash,
            observed_head=observed_head,
            nonce=nonce,
        )


def derive_key_id(sign_public_key: bytes) -> bytes:
    """First 8 bytes of SHA-256 over the raw 32-byte Ed25519 public key.

    The server derives this itself and never stores a client's claim — a
    ``key_id`` is an index into a member's keys, and letting the client choose
    it would let one key masquerade as another's slot.
    """
    if len(sign_public_key) != SIGN_PUBLIC_KEY_BYTES:
        raise ValueError(f"sign_public_key must be {SIGN_PUBLIC_KEY_BYTES} bytes")
    return hashlib.sha256(sign_public_key).digest()[:AUTHOR_KEY_ID_BYTES]


# --- Body framing -----------------------------------------------------------


def padded_body_length(framed_length_bytes: int) -> int:
    """Smallest legal body length that holds ``framed_length_bytes``."""
    for size_class in BODY_SIZE_CLASSES_BYTES:
        if framed_length_bytes <= size_class:
            return size_class
    multiples = -(-framed_length_bytes // BODY_OVERSIZE_MULTIPLE_BYTES)
    return multiples * BODY_OVERSIZE_MULTIPLE_BYTES


def is_legal_body_length(body_length_bytes: int) -> bool:
    """True iff ``body_length_bytes`` is a size class or an exact 16 KiB multiple."""
    if body_length_bytes in BODY_SIZE_CLASSES_BYTES:
        return True
    return (
        body_length_bytes > BODY_SIZE_CLASSES_BYTES[-1]
        and body_length_bytes % BODY_OVERSIZE_MULTIPLE_BYTES == 0
    )


def frame_body(payload: bytes) -> bytes:
    """``u32 payload_len || payload || 0x00 padding`` to the next legal length."""
    framed_length = PAYLOAD_LENGTH_PREFIX_BYTES + len(payload)
    body_length = padded_body_length(framed_length)
    return struct.pack(">I", len(payload)) + payload + bytes(body_length - framed_length)


def parse_body(body: bytes) -> bytes:
    """Unframe a body, enforcing the three mandatory padding rules.

    All three are fail-closed: violation quarantines the op as malformed on the
    same surface as an unknown suite.  Zero-padding verification is what closes
    the covert-channel and tamper gap that AEAD will close for us under suite
    0x01; the server never runs this (it is content-blind), so it is the pulling
    client's duty.
    """
    if not is_legal_body_length(len(body)):
        raise InvalidBodyLengthError(
            f"body is {len(body)} bytes: neither a size class nor a "
            f"{BODY_OVERSIZE_MULTIPLE_BYTES}-byte multiple"
        )
    payload_length = struct.unpack(">I", body[:PAYLOAD_LENGTH_PREFIX_BYTES])[0]
    padding_start = PAYLOAD_LENGTH_PREFIX_BYTES + payload_length
    if padding_start > len(body):
        raise PayloadOverrunsBodyError(
            f"payload_len {payload_length} overruns a {len(body)}-byte body"
        )
    if any(body[padding_start:]):
        raise NonZeroPaddingError("padding contains a non-zero byte")
    return bytes(body[PAYLOAD_LENGTH_PREFIX_BYTES:padding_start])


# --- Envelope ---------------------------------------------------------------


def signing_input(header_bytes: bytes, body: bytes) -> bytes:
    return SIGNING_DOMAIN_OP_V1 + header_bytes + body


def build_envelope(header: OpHeader, body: bytes, signing_key: SigningKey) -> bytes:
    header_bytes = header.serialize()
    signature = signing_key.sign(signing_input(header_bytes, body)).signature
    return header_bytes + body + signature


def split_envelope(envelope: bytes) -> tuple[bytes, bytes, bytes]:
    """Return ``(header_bytes, body, signature)`` or raise ``TruncatedEnvelopeError``."""
    if len(envelope) <= ENVELOPE_OVERHEAD_BYTES:
        raise TruncatedEnvelopeError(
            f"envelope is {len(envelope)} bytes, needs more than {ENVELOPE_OVERHEAD_BYTES}"
        )
    return (
        envelope[:HEADER_LENGTH_BYTES],
        envelope[HEADER_LENGTH_BYTES:-SIGNATURE_LENGTH_BYTES],
        envelope[-SIGNATURE_LENGTH_BYTES:],
    )


def verify_envelope(envelope: bytes, sign_public_key: bytes) -> None:
    """Raise ``BadSignatureEnvelopeError`` unless the Ed25519 signature checks out."""
    header_bytes, body, signature = split_envelope(envelope)
    try:
        VerifyKey(sign_public_key).verify(signing_input(header_bytes, body), signature)
    except BadSignatureError as exc:
        raise BadSignatureEnvelopeError("Ed25519 signature does not verify") from exc


def envelope_hash(envelope: bytes) -> bytes:
    """SHA-256 over the full envelope bytes — the link in the per-author chain."""
    return hashlib.sha256(envelope).digest()


def check_served(header: OpHeader) -> None:
    """Fail closed on any suite or op class this build does not serve."""
    if header.suite not in SERVED_SUITES:
        raise UnsupportedSuiteError(f"suite 0x{header.suite:02x} is not served")
    if header.op_class not in SERVED_OP_CLASSES:
        raise UnsupportedOpClassError(f"op_class {header.op_class} is not served")
