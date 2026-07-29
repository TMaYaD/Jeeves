"""v1 op envelope codec — the protocol identity of the Minimal Sync Server.

The layout below is normative (proposal § Envelope, security review F6) and is
pinned byte-for-byte by ``spec/sync/envelope_v1_vectors.json``, which the Dart
codec in ``app/lib/sync/envelope.dart`` asserts against as well.  Any change
here that is not mirrored there is a protocol fork.

::

    header (canonical, fixed order; fixed-width fields, big-endian integers)
                              offset  size
      suite            u8        0      1   0x00 = plaintext_v1, 0x01 = aead_v1
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

    plaintext body = u32 payload_len || payload || zero padding (`frame_body`)
    aead_v1 body   = XChaCha20-Poly1305(K_{w,epoch}, header.nonce,
                         aad = the 158 serialized header bytes exactly,
                         plaintext = the *same* framed body)
    signature      = Ed25519(sk_author, b"jeeves/op/v1" || header || body)
    envelope       = header || body || signature

The header is constant width, so no per-field length prefixes are needed: the
envelope framing supplies the only variable length, ``body_len = len(envelope)
- ENVELOPE_OVERHEAD_BYTES``.

**``aead_v1`` is a body wrapper and nothing else** — no offset moves, no field is
added, and the framed plaintext under 0x01 is byte for byte what 0x00 would have
carried in the clear.  The AAD is the literal header, so the suite, the
``key_epoch`` and the nonce are bound with no second binding to keep in step.
Exactly one rule is suite-conditional: a 0x01 body is 16 bytes longer than the
size class it pads to (the Poly1305 tag), so wire-legality is
:func:`is_legal_body_length_for_suite`.

**The server never decrypts and never parses a 0x01 body.**  Its
content-blindness is cryptographic from here on: what it holds for an encrypted
op is the header index and opaque bytes.  ``seal_body``/``open_body`` exist in
this module so the golden-vector generator and the two codecs pin one
construction — no request path calls them.

**Control ops are ``plaintext_v1`` for ever** (review F2): the server materialises
memberships, Grants and rotations out of their payloads and holds no key, so an
encrypted control op is not a stricter op but one nobody can act on.  Both codecs
refuse it as ``encrypted_control_op``.
"""

from __future__ import annotations

import hashlib
import struct
import uuid
from dataclasses import dataclass
from typing import Final

from nacl import bindings
from nacl.exceptions import BadSignatureError, CryptoError
from nacl.signing import SigningKey, VerifyKey

# --- Suites -----------------------------------------------------------------

#: plaintext_v1 — no AEAD, Ed25519 signature only.
SUITE_PLAINTEXT_V1: Final = 0x00
#: aead_v1 — XChaCha20-Poly1305 over the framed body, plus the Ed25519 signature.
SUITE_AEAD_V1: Final = 0x01
#: Suites this build implements.  Anything else is fail-closed (review F21).
SERVED_SUITES: Final[frozenset[int]] = frozenset({SUITE_PLAINTEXT_V1, SUITE_AEAD_V1})

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

#: The Poly1305 tag every AEAD ciphertext in this protocol carries, appended.
#: One constant for the envelope body, the KeyWrap and the escrow blob — three
#: copies of 16 is how one of them ends up disagreeing.
AEAD_TAG_BYTES: Final = 16
#: A Workspace content key ``K_{w,epoch}`` — random 256 bits, never derived.
WORKSPACE_KEY_BYTES: Final = 32

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
#:
#: **Measured and left alone under #554.**  A full-day convergence corpus authors
#: 61 content ops: 32 pad to 256 and 29 to 1024, and 25 of those 29 have a framed
#: length in 257–512 — so 256→1024 *is* the common jump.  A 512 class was still
#: refused: padding classes are a confidentiality mechanism, not a bandwidth one,
#: and splitting the bucket would hand an observer one more bit per op about how
#: large its payload is to buy back ~13 KiB a day.  The coarse bucket is the
#: padding doing its job.
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


def minimum_envelope_bytes_for_suite(suite: int) -> int:
    """:data:`MINIMUM_ENVELOPE_BYTES`, made suite-aware by the one thing that differs.

    The server's content-blind floor.  Under 0x01 the smallest legal body is the
    smallest size class *plus the tag*, so a floor left at the plaintext number
    would admit a 16-byte-short encrypted envelope into the log for every puller to
    quarantine.  It reads the suite out of the header it already parses and still
    never looks at a body byte.
    """
    return MINIMUM_ENVELOPE_BYTES + (AEAD_TAG_BYTES if suite == SUITE_AEAD_V1 else 0)


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


class EncryptedControlOpError(EnvelopeError):
    """An ``op_class = control`` op wearing suite ``aead_v1``.

    A codec-level document invariant, refused wherever the bytes are held.  Not a
    served/unserved question and so not expressible as a set: both halves are
    served and the *pair* is forbidden for ever, because the server materialises
    control payloads and holds no key.  A client that tolerated one would be
    trusting a server that could no longer check anything.
    """

    reason = "encrypted_control_op"


class AeadFailureError(EnvelopeError):
    """The AEAD did not authenticate under the key supplied.

    A tampered ciphertext and a tampered header are the same verdict — the header
    is the AAD, and the codec cannot tell which of them moved.  Classifying them
    apart would be a guess.  On a client this is an integrity *alarm* as well as a
    quarantine (never a skipped row); the server never reaches it, because it never
    decrypts.
    """

    reason = "aead_failure"


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


def is_legal_body_length_for_suite(suite: int, body_length_bytes: int) -> bool:
    """:func:`is_legal_body_length`, made suite-aware — **the one such rule**.

    A 0x01 body is the padded plaintext plus the Poly1305 tag, so its legal lengths
    are the plaintext ones shifted by 16.  Expressed as a shift rather than as a
    second table, so a change to the size classes moves both suites at once.
    """
    if suite != SUITE_AEAD_V1:
        return is_legal_body_length(body_length_bytes)
    return body_length_bytes > AEAD_TAG_BYTES and is_legal_body_length(
        body_length_bytes - AEAD_TAG_BYTES
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
    """Fail closed on any unserved suite or op class, and on the one forbidden pair."""
    if header.suite not in SERVED_SUITES:
        raise UnsupportedSuiteError(f"suite 0x{header.suite:02x} is not served")
    if header.op_class not in SERVED_OP_CLASSES:
        raise UnsupportedOpClassError(f"op_class {header.op_class} is not served")
    if header.suite == SUITE_AEAD_V1 and header.op_class == OP_CLASS_CONTROL:
        raise EncryptedControlOpError(
            "control ops are plaintext_v1 for ever: the server materialises their "
            "payloads and holds no key"
        )


# --- aead_v1: sealing and opening a body ------------------------------------


def nonce_of_header(header_bytes: bytes) -> bytes:
    """The 24 nonce bytes carried at offset 134 of a serialized header.

    Read out of the literal header rather than passed alongside it: the nonce *is* a
    header field, so a caller able to supply a different one would be sealing under
    bytes the AAD does not cover.
    """
    offset = dict((name, offset) for name, offset, _ in HEADER_FIELD_LAYOUT)["nonce"]
    return header_bytes[offset : offset + NONCE_BYTES]


def seal_body(header_bytes: bytes, framed_body: bytes, workspace_key: bytes) -> bytes:
    """Seal a framed body under ``aead_v1``: ``ciphertext || tag``.

    ``header_bytes`` is both the AAD and the source of the nonce, so there is
    exactly one place either can come from.  The plaintext is the *already framed*
    body — pad-then-encrypt — which is what puts :func:`parse_body`'s padding rules
    inside the AEAD instead of beside it.

    Nothing here mints a nonce.  Production draws 24 bytes from a CSPRNG at
    authoring and writes them into the header before it is serialized; the golden
    vectors pin explicit nonce bytes.  A seeded-nonce scheme would be catastrophic
    under a stream cipher, so the seam is "the caller already chose, and it is in
    the header" rather than an injectable entropy source.
    """
    if len(header_bytes) != HEADER_LENGTH_BYTES:
        raise ValueError(f"header must be {HEADER_LENGTH_BYTES} bytes")
    if len(workspace_key) != WORKSPACE_KEY_BYTES:
        raise ValueError(f"workspace key must be {WORKSPACE_KEY_BYTES} bytes")
    return bindings.crypto_aead_xchacha20poly1305_ietf_encrypt(
        framed_body, header_bytes, nonce_of_header(header_bytes), workspace_key
    )


def open_body(header_bytes: bytes, body: bytes, workspace_key: bytes) -> bytes:
    """Open an ``aead_v1`` body back to its framed plaintext.

    Raises :class:`InvalidBodyLengthError` for a body that is not a size class plus
    a tag, and :class:`AeadFailureError` for anything the AEAD refuses.
    """
    if len(header_bytes) != HEADER_LENGTH_BYTES:
        raise ValueError(f"header must be {HEADER_LENGTH_BYTES} bytes")
    if len(workspace_key) != WORKSPACE_KEY_BYTES:
        raise ValueError(f"workspace key must be {WORKSPACE_KEY_BYTES} bytes")
    if not is_legal_body_length_for_suite(SUITE_AEAD_V1, len(body)):
        raise InvalidBodyLengthError(
            f"an aead_v1 body of {len(body)} bytes is not a size class plus a "
            f"{AEAD_TAG_BYTES}-byte tag"
        )
    try:
        return bindings.crypto_aead_xchacha20poly1305_ietf_decrypt(
            body, header_bytes, nonce_of_header(header_bytes), workspace_key
        )
    except CryptoError as exc:
        raise AeadFailureError(
            "the aead_v1 body did not authenticate under the epoch key supplied"
        ) from exc
