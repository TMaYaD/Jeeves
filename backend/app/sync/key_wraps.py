"""The KeyWrap formats: how a Workspace epoch key reaches a Member, and the escrow.

Two wrap flavours, both carrying the same 32-byte plaintext — a Workspace content
key ``K_{w,epoch}`` — and neither of them ever openable by the server (ADR-0034):

**KeyWrap**, one per ``(Member, epoch)``.  A sealed-box-equivalent to the Member's
registered X25519 ``kex_pk``.  This is the delivery of a Grant's entitlement: a
Grant carries no key material (F19), a KeyWrap carries no authority::

    info = b"jeeves/keywrap/v1" || epk 32B || workspace_id 16B
        || epoch u32 BE || member_id 16B || kex_key_id 8B          (93 bytes)

    wrap = epk 32B || nonce 24B || XChaCha20-Poly1305(
               key   = HKDF-SHA256(ikm = X25519(esk, kex_pk), salt = b"", info),
               nonce, aad = info, plaintext = K 32B)               (104 bytes)

**Escrow wrap**, one per ``(Workspace, epoch)``.  A plain symmetric wrap under the
``master_wrap_key`` the recovery escrow has carried since #553::

    info        = b"jeeves/epoch-key-escrow/v1" || workspace_id 16B
               || epoch u32 BE                                     (42 bytes)
    escrow_wrap = nonce 24B || XChaCha20-Poly1305(
                      master_wrap_key, nonce, aad = info, plaintext = K 32B)

The escrow wrap is what makes a fresh device's bootstrap work with **no live
second device**: the passphrase yields ``master_wrap_key``, which opens every
historical epoch key, which decrypts the whole history.  That is the same "no
second device online, ever" invariant enrolment already runs on.

Three properties the ``info``/AAD binding buys, and why each field is in there:

* ``epk`` — HPKE discipline: the encapsulated key belongs in the key schedule, so
  an attacker cannot re-point a captured wrap at a different ephemeral share.
* ``workspace_id`` and ``epoch`` — a wrap cannot be replayed into another
  Workspace or another epoch, so an honest-but-confused server cannot deliver
  yesterday's key as today's.
* ``member_id`` and ``kex_key_id`` — a wrap cannot be handed to a different Member,
  nor to a different key of the same Member.

Because ``info`` is both the HKDF info *and* the AEAD AAD, a mismatch on any of
them is an authentication failure rather than a silent decryption to garbage.

**The digest is what stops the server curating the wrap set.**  A ``rotate``
control op commits to ``keywrap_digest`` before any wrap is uploaded, and
``PUT /w/{w}/keywraps`` refuses a set that does not hash to it — so the server can
neither add a wrap (for a member the owner did not wrap to) nor omit one (locking
an honest member out).  The escrow wrap is inside the digest for the same reason::

    keywrap_digest = SHA-256(
        b"jeeves/keywrap-digest/v1" || epoch u32 BE || member_wrap_count u32 BE
        || for each (member_id, kex_key_id, wrap) sorted by (member_id, kex_key_id):
               member_id 16B || kex_key_id 8B || SHA-256(wrap) 32B
        || SHA-256(escrow_wrap) 32B)

Sorted, so the digest is a property of the *set* and not of an upload order the
server could shuffle.

**PyNaCl has no HKDF**, so :func:`hkdf_sha256` below is a hand-rolled RFC 5869
HKDF-SHA256 — twelve lines, fully deterministic, and cross-checked against the
Dart ``cryptography`` package's ``Hkdf`` by the golden vectors.  ADR-0034 records
that as a deliberate consequence of choosing a hand-rolled sealed box over
libsodium's ``crypto_box_seal``, which has no Dart implementation that runs on
web.
"""

from __future__ import annotations

import hashlib
import hmac
import uuid
from typing import Final

from nacl import bindings
from nacl.exceptions import CryptoError

from app.sync.envelope import AEAD_TAG_BYTES, WORKSPACE_KEY_BYTES, AeadFailureError

#: Every use of every key is domain-separated (review F7), the wraps included.
KEYWRAP_INFO_DOMAIN: Final = b"jeeves/keywrap/v1"
EPOCH_KEY_ESCROW_INFO_DOMAIN: Final = b"jeeves/epoch-key-escrow/v1"
KEYWRAP_DIGEST_DOMAIN: Final = b"jeeves/keywrap-digest/v1"

#: The ephemeral X25519 share a KeyWrap carries, so it needs no prior state.
#: A Member's registered ``kex_pk`` is checked against this too — both are X25519
#: public keys, and giving them separate constants would invite the two to drift
#: apart when nothing about the algorithm allows it.
EPHEMERAL_PUBLIC_KEY_BYTES: Final = 32
WRAP_NONCE_BYTES: Final = 24
MASTER_WRAP_KEY_BYTES: Final = 32
KEYWRAP_DIGEST_BYTES: Final = 32

#: Fixed widths, so a wrap of the wrong length is refused before any crypto runs.
KEYWRAP_BYTES: Final = (
    EPHEMERAL_PUBLIC_KEY_BYTES + WRAP_NONCE_BYTES + WORKSPACE_KEY_BYTES + AEAD_TAG_BYTES
)
EPOCH_KEY_ESCROW_WRAP_BYTES: Final = WRAP_NONCE_BYTES + WORKSPACE_KEY_BYTES + AEAD_TAG_BYTES

#: A ``key_epoch`` is a header ``u32``, so this is the ceiling everywhere.
MAX_KEY_EPOCH: Final = 0xFFFFFFFF


class KeyWrapError(Exception):
    """A wrap that is malformed or does not authenticate.

    ``reason`` is the structured code the routes answer with and the Dart side
    mirrors, on the same discipline as ``EnvelopeError``.
    """

    reason: str = "malformed_keywrap"


class MalformedKeyWrapError(KeyWrapError):
    reason = "malformed_keywrap"


def hkdf_sha256(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    """RFC 5869 HKDF-SHA256, extract-then-expand.

    Hand-rolled because PyNaCl ships no HKDF and this module must produce the same
    bytes as the Dart ``cryptography`` package's ``Hkdf(hmac: Hmac.sha256())``.
    An empty ``salt`` is RFC 5869's default of ``HashLen`` zero bytes, which is what
    the Dart side's empty ``nonce`` argument means too — the golden vectors are
    what proves those two readings agree.
    """
    prk = hmac.new(salt or bytes(hashlib.sha256().digest_size), ikm, hashlib.sha256).digest()
    okm = b""
    block = b""
    counter = 1
    while len(okm) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        okm += block
        counter += 1
    return okm[:length]


def _epoch_bytes(epoch: int) -> bytes:
    if not 0 <= epoch <= MAX_KEY_EPOCH:
        raise ValueError(f"key_epoch {epoch} does not fit the header's u32")
    return epoch.to_bytes(4, "big")


def keywrap_info(
    *,
    ephemeral_public_key: bytes,
    workspace_id: uuid.UUID,
    epoch: int,
    member_id: uuid.UUID,
    kex_key_id: bytes,
) -> bytes:
    """The HKDF ``info`` and the AEAD AAD — deliberately the same bytes."""
    if len(ephemeral_public_key) != EPHEMERAL_PUBLIC_KEY_BYTES:
        raise ValueError(f"epk must be {EPHEMERAL_PUBLIC_KEY_BYTES} bytes")
    if len(kex_key_id) != 8:
        raise ValueError("kex_key_id must be 8 bytes")
    return (
        KEYWRAP_INFO_DOMAIN
        + ephemeral_public_key
        + workspace_id.bytes
        + _epoch_bytes(epoch)
        + member_id.bytes
        + kex_key_id
    )


def epoch_key_escrow_info(*, workspace_id: uuid.UUID, epoch: int) -> bytes:
    return EPOCH_KEY_ESCROW_INFO_DOMAIN + workspace_id.bytes + _epoch_bytes(epoch)


def wrap_epoch_key_for_member(
    *,
    workspace_key: bytes,
    kex_pk: bytes,
    workspace_id: uuid.UUID,
    epoch: int,
    member_id: uuid.UUID,
    kex_key_id: bytes,
    ephemeral_secret_key: bytes,
    nonce: bytes,
) -> bytes:
    """Seal ``workspace_key`` to ``kex_pk``: ``epk || nonce || ciphertext || tag``.

    ``ephemeral_secret_key`` and ``nonce`` are arguments rather than drawn here, for
    the same reason :func:`app.sync.envelope.seal_body` takes its nonce from the
    header: a wrap is only ever minted by a *client*, and this module exists so the
    vector generator and the two codecs pin one construction.  Production draws both
    from a CSPRNG, one ephemeral keypair per wrap.
    """
    if len(workspace_key) != WORKSPACE_KEY_BYTES:
        raise ValueError(f"workspace key must be {WORKSPACE_KEY_BYTES} bytes")
    if len(kex_pk) != EPHEMERAL_PUBLIC_KEY_BYTES:
        raise ValueError(f"kex_pk must be {EPHEMERAL_PUBLIC_KEY_BYTES} bytes")
    if len(nonce) != WRAP_NONCE_BYTES:
        raise ValueError(f"nonce must be {WRAP_NONCE_BYTES} bytes")
    epk = bindings.crypto_scalarmult_base(ephemeral_secret_key)
    info = keywrap_info(
        ephemeral_public_key=epk,
        workspace_id=workspace_id,
        epoch=epoch,
        member_id=member_id,
        kex_key_id=kex_key_id,
    )
    key = hkdf_sha256(
        bindings.crypto_scalarmult(ephemeral_secret_key, kex_pk), b"", info, WORKSPACE_KEY_BYTES
    )
    sealed = bindings.crypto_aead_xchacha20poly1305_ietf_encrypt(workspace_key, info, nonce, key)
    return epk + nonce + sealed


def unwrap_epoch_key_for_member(
    *,
    wrap: bytes,
    kex_secret_key: bytes,
    workspace_id: uuid.UUID,
    epoch: int,
    member_id: uuid.UUID,
    kex_key_id: bytes,
) -> bytes:
    """Open a KeyWrap, or refuse it.

    The ``info`` is *reconstructed from the caller's own idea* of which Workspace,
    epoch, member and key this wrap is for — never read out of the wrap — so a wrap
    delivered into the wrong slot fails to authenticate instead of opening.  The
    only thing taken from the wrap itself is ``epk``, which is bound into that same
    ``info`` and therefore cannot be swapped either.
    """
    if len(wrap) != KEYWRAP_BYTES:
        raise MalformedKeyWrapError(f"a keywrap is {KEYWRAP_BYTES} bytes, got {len(wrap)}")
    epk = wrap[:EPHEMERAL_PUBLIC_KEY_BYTES]
    nonce = wrap[EPHEMERAL_PUBLIC_KEY_BYTES : EPHEMERAL_PUBLIC_KEY_BYTES + WRAP_NONCE_BYTES]
    sealed = wrap[EPHEMERAL_PUBLIC_KEY_BYTES + WRAP_NONCE_BYTES :]
    info = keywrap_info(
        ephemeral_public_key=epk,
        workspace_id=workspace_id,
        epoch=epoch,
        member_id=member_id,
        kex_key_id=kex_key_id,
    )
    key = hkdf_sha256(
        bindings.crypto_scalarmult(kex_secret_key, epk), b"", info, WORKSPACE_KEY_BYTES
    )
    try:
        return bindings.crypto_aead_xchacha20poly1305_ietf_decrypt(sealed, info, nonce, key)
    except CryptoError as exc:
        raise AeadFailureError("the keywrap did not authenticate for this member slot") from exc


def wrap_epoch_key_for_escrow(
    *,
    workspace_key: bytes,
    master_wrap_key: bytes,
    workspace_id: uuid.UUID,
    epoch: int,
    nonce: bytes,
) -> bytes:
    """Wrap ``workspace_key`` under the escrowed ``master_wrap_key``."""
    if len(workspace_key) != WORKSPACE_KEY_BYTES:
        raise ValueError(f"workspace key must be {WORKSPACE_KEY_BYTES} bytes")
    if len(master_wrap_key) != MASTER_WRAP_KEY_BYTES:
        raise ValueError(f"master wrap key must be {MASTER_WRAP_KEY_BYTES} bytes")
    if len(nonce) != WRAP_NONCE_BYTES:
        raise ValueError(f"nonce must be {WRAP_NONCE_BYTES} bytes")
    info = epoch_key_escrow_info(workspace_id=workspace_id, epoch=epoch)
    return nonce + bindings.crypto_aead_xchacha20poly1305_ietf_encrypt(
        workspace_key, info, nonce, master_wrap_key
    )


def unwrap_epoch_key_from_escrow(
    *,
    escrow_wrap: bytes,
    master_wrap_key: bytes,
    workspace_id: uuid.UUID,
    epoch: int,
) -> bytes:
    if len(escrow_wrap) != EPOCH_KEY_ESCROW_WRAP_BYTES:
        raise MalformedKeyWrapError(
            f"an escrow wrap is {EPOCH_KEY_ESCROW_WRAP_BYTES} bytes, got {len(escrow_wrap)}"
        )
    nonce = escrow_wrap[:WRAP_NONCE_BYTES]
    sealed = escrow_wrap[WRAP_NONCE_BYTES:]
    info = epoch_key_escrow_info(workspace_id=workspace_id, epoch=epoch)
    try:
        return bindings.crypto_aead_xchacha20poly1305_ietf_decrypt(
            sealed, info, nonce, master_wrap_key
        )
    except CryptoError as exc:
        raise AeadFailureError(
            "the epoch-key escrow wrap did not authenticate under the master wrap key"
        ) from exc


def keywrap_digest(
    *,
    epoch: int,
    member_wraps: list[tuple[uuid.UUID, bytes, bytes]],
    escrow_wrap: bytes,
) -> bytes:
    """The commitment a ``rotate`` op carries, over the whole wrap set.

    ``member_wraps`` is ``(member_id, kex_key_id, wrap)``.  Sorted here rather than
    by the caller, so the digest is a property of the set and not of an upload order
    the server could shuffle — and computed identically on the client that commits
    to it and the server that checks it.
    """
    if len(escrow_wrap) != EPOCH_KEY_ESCROW_WRAP_BYTES:
        raise MalformedKeyWrapError(
            f"an escrow wrap is {EPOCH_KEY_ESCROW_WRAP_BYTES} bytes, got {len(escrow_wrap)}"
        )
    digest = hashlib.sha256()
    digest.update(KEYWRAP_DIGEST_DOMAIN)
    digest.update(_epoch_bytes(epoch))
    digest.update(len(member_wraps).to_bytes(4, "big"))
    for member_id, kex_key_id, wrap in sorted(
        member_wraps, key=lambda entry: (entry[0].bytes, entry[1])
    ):
        if len(wrap) != KEYWRAP_BYTES:
            raise MalformedKeyWrapError(f"a keywrap is {KEYWRAP_BYTES} bytes, got {len(wrap)}")
        if len(kex_key_id) != 8:
            raise MalformedKeyWrapError("kex_key_id must be 8 bytes")
        digest.update(member_id.bytes)
        digest.update(kex_key_id)
        digest.update(hashlib.sha256(wrap).digest())
    digest.update(hashlib.sha256(escrow_wrap).digest())
    return digest.digest()
