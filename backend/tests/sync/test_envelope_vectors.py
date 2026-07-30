"""The Python codec against the frozen golden vectors.

``app/test/sync/envelope_vectors_test.dart`` runs the same assertions against
the same file.  Two independent implementations agreeing byte-for-byte with a
committed artifact is what keeps the Dart harness's in-process server double
honest about the wire format the real server speaks.
"""

from __future__ import annotations

import json
import uuid
from typing import Any

import pytest
from nacl.signing import SigningKey

from app.sync import control_payload as control
from app.sync import envelope as env
from app.sync import escrow as esc
from app.sync import key_wraps as kw
from app.sync import member_auth
from app.sync.control_payload import ControlPayload, ControlPayloadError, RegistrationCertificate
from app.sync.envelope import EnvelopeError, OpHeader
from app.sync.ids import (
    JEEVES_WORKSPACE_NAMESPACE,
    USER_PREFERENCES_WORKSPACE_NAMESPACE,
    default_workspace_id,
    preference_entity_id,
    user_preferences_workspace_id,
)
from app.sync.op_payload import MalformedPayloadError, OpPayload
from tests.sync.vectors import envelope_vectors

#: The two control types that carry their author's own registration, and are
#: therefore that author's op 1.  Genesis generalises #548's register rule.
_REGISTERING_TYPES = frozenset(
    {control.CONTROL_TYPE_WORKSPACE_GENESIS, control.CONTROL_TYPE_MEMBER_REGISTER}
)

_DOCUMENT = envelope_vectors()
_PROTOCOL = _DOCUMENT["protocol"]
_IDENTITIES = _DOCUMENT["identities"]
_KEYS_BY_LABEL = {entry["label"]: entry for entry in _IDENTITIES["keys"]}
_ROOT_PUBLIC_KEY = bytes.fromhex(_IDENTITIES["root"]["root_pk_hex"])


class _CertMemberMismatchError(ControlPayloadError):
    """A Root-signed certificate that is *about* somebody other than the author.

    Test-local: production Python runs this binding check in the ops route, whose
    error codes are string literals on the 422 detail.  The runner needs a typed
    error so the ``reason`` the negative vectors pin is the one it raises.
    """

    reason = "cert_member_mismatch"


class _CertKeyMismatchError(ControlPayloadError):
    """The header names a key the certificate does not carry."""

    reason = "cert_key_mismatch"


def _header_from_json(raw: dict[str, Any]) -> OpHeader:
    return OpHeader(
        suite=raw["suite"],
        op_class=raw["op_class"],
        workspace_id=uuid.UUID(raw["workspace_id"]),
        key_epoch=raw["key_epoch"],
        op_id=uuid.UUID(raw["op_id"]),
        author_member_id=uuid.UUID(raw["author_member_id"]),
        author_key_id=bytes.fromhex(raw["author_key_id_hex"]),
        author_seq=raw["author_seq"],
        prev_author_hash=bytes.fromhex(raw["prev_author_hash_hex"]),
        observed_head=bytes.fromhex(raw["observed_head_hex"]),
        nonce=bytes.fromhex(raw["nonce_hex"]),
    )


def _receive(envelope: bytes, expected_workspace_id: uuid.UUID, sign_pk: bytes) -> OpPayload:
    """The receiving client's fail-closed pipeline, in its normative order.

    The real server never runs this — it is content-blind and stops after the
    header.  The Dart client runs the identical sequence in
    ``sync_client.dart``; both are pinned to the same ``reason`` codes by the
    negative vectors, which is what stops the two from drifting apart.
    """
    header_bytes, body, _signature = env.split_envelope(envelope)
    header = OpHeader.parse(header_bytes)
    env.check_served(header)
    if header.workspace_id != expected_workspace_id:
        raise env.WorkspaceMismatchError("header workspace is not the pulled workspace")
    env.verify_envelope(envelope, sign_pk)
    return OpPayload.decode(env.parse_body(body))


def _member_sign_pk(member_id: str) -> bytes:
    """The directory lookup, standing in for a chain-gated one.

    A real receiver learns a member's key from that member's own Root-signed
    registration; here the spec identities are the directory, which is enough to
    pin *which* key each control type is verified against.
    """
    for entry in _IDENTITIES["keys"]:
        if entry["member_id"] == member_id:
            return bytes.fromhex(entry["sign_pk_hex"])
    raise ControlPayloadError(f"no spec key for member {member_id}")


def _check_registration_binds_the_envelope(
    certificate: RegistrationCertificate, envelope: bytes, header: OpHeader
) -> None:
    """The load-bearing step: the certificate's *own* key must have signed this.

    A genuine certificate is public the moment it is in the log.  Without this
    check anyone holding a copy could wrap it around self-signed envelopes and
    manufacture forks in the victim's chain.
    """
    if certificate.member_id != header.author_member_id:
        raise _CertMemberMismatchError("certificate names another member")
    env.verify_envelope(envelope, certificate.sign_pk)
    if env.derive_key_id(certificate.sign_pk) != header.author_key_id:
        raise _CertKeyMismatchError("certificate key id is not the one the header names")


def _receive_control(envelope: bytes, root_pk: bytes) -> Any:
    """The control half of the receive pipeline, dispatched per type.

    Returns the parsed certificate: a ``RegistrationCertificate`` for a
    ``member_register`` *and* for a ``workspace_genesis`` (genesis embeds the
    founder's registration), a ``GrantCertificate``, or a ``RevokeCertificate``.

    Everything needing receiver **state** is deliberately absent, because a vector
    cannot carry it: the position rule (``author_seq == 1``), the chain rule
    against what has been applied, an unmaterialised grantee, a Service grant into
    the preferences Workspace, and the *revoke* half of the owner ceiling — that
    last one because the frozen revoke certificate names a ``grant_id``, so the
    target's role is state rather than bytes.  Those are pinned by the route and
    harness tests.
    """
    header_bytes, body, _signature = env.split_envelope(envelope)
    header = OpHeader.parse(header_bytes)
    env.check_served(header)
    assert header.op_class == env.OP_CLASS_CONTROL

    payload = ControlPayload.decode(env.parse_body(body))
    payload.require_served_type()
    payload.require_chain_link_shape()

    if payload.control_type == control.CONTROL_TYPE_WORKSPACE_GENESIS:
        control.verify_genesis_certificate(payload.cert_bytes, payload.root_sig, root_pk)
        genesis = payload.genesis_certificate()
        if genesis.root_pk != root_pk:
            # The Root inside the signed genesis must be the Root this receiver
            # pinned: that cross-check is why it is in there at all.
            raise ControlPayloadError("cert_root_pk_mismatch")
        # The founder's registration is *inside* the genesis, so the binding check
        # runs against it while the genesis certificate stays what was signed.
        _check_registration_binds_the_envelope(genesis.as_registration(), envelope, header)
        return genesis

    if payload.control_type == control.CONTROL_TYPE_MEMBER_REGISTER:
        control.verify_registration_certificate(payload.cert_bytes, payload.root_sig, root_pk)
        registration = payload.certificate()
        _check_registration_binds_the_envelope(registration, envelope, header)
        return registration

    # Grant and Revoke: the authority is Root or an owning Member, and *which*
    # key verifies the certificate is decided by the payload's own `authority`
    # field and nothing else.  The envelope itself is verified against the
    # author's directory key, as any non-registering op is.
    if payload.control_type == control.CONTROL_TYPE_ROTATE:
        # No certificate and no separate signature: a rotate's authority is the
        # author's own live owner Grant, which is receiver state a vector cannot
        # carry, so what is checkable here is the envelope signature and the
        # statement's own shape.  The authority check is pinned by the route tests.
        env.verify_envelope(envelope, _member_sign_pk(str(header.author_member_id)))
        assert not payload.is_root_signed
        return payload.rotate_statement()

    authority_pk = (
        root_pk if payload.authority == control.GRANTER_ROOT else _member_sign_pk(payload.authority)
    )
    env.verify_envelope(envelope, _member_sign_pk(str(header.author_member_id)))
    if payload.control_type == control.CONTROL_TYPE_GRANT:
        control.verify_grant_certificate(payload.cert_bytes, payload.signature, authority_pk)
        grant = payload.grant_certificate()
        if grant.granter != payload.authority:
            # The signed certificate names its own granter; the payload field
            # only says which key to check it against.
            raise ControlPayloadError("cert_granter_mismatch")
        return grant

    control.verify_revoke_certificate(payload.cert_bytes, payload.signature, authority_pk)
    revoke = payload.revoke_certificate()
    if revoke.revoker != payload.authority:
        raise ControlPayloadError("cert_granter_mismatch")
    return revoke


def test_protocol_constants_match_the_frozen_file() -> None:
    assert _PROTOCOL["header_length_bytes"] == env.HEADER_LENGTH_BYTES
    assert _PROTOCOL["signature_length_bytes"] == env.SIGNATURE_LENGTH_BYTES
    assert _PROTOCOL["envelope_overhead_bytes"] == env.ENVELOPE_OVERHEAD_BYTES
    assert _PROTOCOL["signing_domain"] == env.SIGNING_DOMAIN_OP_V1.decode("ascii")
    assert _PROTOCOL["suites"]["plaintext_v1"] == env.SUITE_PLAINTEXT_V1
    assert _PROTOCOL["suites"]["aead_v1"] == env.SUITE_AEAD_V1
    assert _PROTOCOL["served_suites"] == sorted(env.SERVED_SUITES)
    aead = _PROTOCOL["aead"]
    assert aead["tag_bytes"] == env.AEAD_TAG_BYTES
    assert aead["workspace_key_bytes"] == env.WORKSPACE_KEY_BYTES
    assert aead["minimum_envelope_bytes"] == {
        str(suite): env.minimum_envelope_bytes_for_suite(suite)
        for suite in sorted(env.SERVED_SUITES)
    }
    wrap = _PROTOCOL["keywrap"]
    assert wrap["member_info_domain"] == kw.KEYWRAP_INFO_DOMAIN.decode("ascii")
    assert wrap["escrow_info_domain"] == kw.EPOCH_KEY_ESCROW_INFO_DOMAIN.decode("ascii")
    assert wrap["digest_domain"] == kw.KEYWRAP_DIGEST_DOMAIN.decode("ascii")
    assert wrap["ephemeral_public_key_bytes"] == kw.EPHEMERAL_PUBLIC_KEY_BYTES
    assert wrap["nonce_bytes"] == kw.WRAP_NONCE_BYTES
    assert wrap["master_wrap_key_bytes"] == kw.MASTER_WRAP_KEY_BYTES
    assert wrap["keywrap_bytes"] == kw.KEYWRAP_BYTES
    assert wrap["escrow_wrap_bytes"] == kw.EPOCH_KEY_ESCROW_WRAP_BYTES
    assert _PROTOCOL["served_op_classes"] == sorted(env.SERVED_OP_CLASSES)
    assert _PROTOCOL["known_op_classes"] == sorted(env.KNOWN_OP_CLASSES)
    assert _PROTOCOL["body_size_classes_bytes"] == list(env.BODY_SIZE_CLASSES_BYTES)
    assert _PROTOCOL["body_oversize_multiple_bytes"] == env.BODY_OVERSIZE_MULTIPLE_BYTES
    assert _PROTOCOL["payload_length_prefix_bytes"] == env.PAYLOAD_LENGTH_PREFIX_BYTES
    assert _PROTOCOL["workspace_namespace_uuid"] == str(JEEVES_WORKSPACE_NAMESPACE)
    assert [
        (entry["name"], entry["offset"], entry["length_bytes"])
        for entry in _PROTOCOL["header_field_layout"]
    ] == list(env.HEADER_FIELD_LAYOUT)


def test_header_field_layout_sums_to_the_header_length() -> None:
    layout = _PROTOCOL["header_field_layout"]
    assert sum(entry["length_bytes"] for entry in layout) == env.HEADER_LENGTH_BYTES
    running_offset = 0
    for entry in layout:
        assert entry["offset"] == running_offset, entry["name"]
        running_offset += entry["length_bytes"]


def test_derived_identities_match_the_frozen_file() -> None:
    workspace_id = default_workspace_id(_IDENTITIES["user_id"])
    assert str(workspace_id) == _IDENTITIES["workspace_id"]
    assert (
        str(default_workspace_id(_IDENTITIES["other_user_id"]))
        == (_IDENTITIES["other_workspace_id"])
    )
    assert (
        str(preference_entity_id(workspace_id, _IDENTITIES["preference_key"]))
        == (_IDENTITIES["preference_entity_id"])
    )


def test_key_ids_are_derived_from_the_public_keys() -> None:
    for entry in _IDENTITIES["keys"]:
        signing_key = SigningKey(bytes.fromhex(entry["seed_hex"]))
        sign_pk = bytes(signing_key.verify_key)
        assert sign_pk.hex() == entry["sign_pk_hex"]
        assert env.derive_key_id(sign_pk).hex() == entry["key_id_hex"]


@pytest.mark.parametrize("vector", _DOCUMENT["header_vectors"], ids=lambda v: str(v["name"]))
def test_header_vector_serializes_and_round_trips(vector: dict[str, Any]) -> None:
    header = _header_from_json(vector["header"])
    serialized = header.serialize()
    assert serialized.hex() == vector["header_hex"]
    assert len(serialized) == env.HEADER_LENGTH_BYTES
    assert OpHeader.parse(serialized) == header


@pytest.mark.parametrize("vector", _DOCUMENT["vectors"], ids=lambda v: str(v["name"]))
def test_positive_vector_is_byte_identical(vector: dict[str, Any]) -> None:
    key_entry = _KEYS_BY_LABEL[vector["key"]]
    signing_key = SigningKey(bytes.fromhex(key_entry["seed_hex"]))
    header = _header_from_json(vector["header"])
    payload = vector["payload_json"].encode("utf-8")

    assert header.serialize().hex() == vector["header_hex"]
    assert len(payload) == vector["payload_length_bytes"]

    body = env.frame_body(payload)
    assert len(body) == vector["body_length_bytes"]
    assert body.hex() == vector["body_hex"]

    envelope = env.build_envelope(header, body, signing_key)
    assert envelope.hex() == vector["envelope_hex"]
    assert envelope[-env.SIGNATURE_LENGTH_BYTES :].hex() == vector["signature_hex"]
    assert env.envelope_hash(envelope).hex() == vector["envelope_sha256_hex"]
    assert len(envelope) == env.ENVELOPE_OVERHEAD_BYTES + vector["body_length_bytes"]


@pytest.mark.parametrize("vector", _DOCUMENT["vectors"], ids=lambda v: str(v["name"]))
def test_positive_vector_round_trips_through_the_receive_pipeline(
    vector: dict[str, Any],
) -> None:
    key_entry = _KEYS_BY_LABEL[vector["key"]]
    envelope = bytes.fromhex(vector["envelope_hex"])
    header_bytes, body, _ = env.split_envelope(envelope)

    assert OpHeader.parse(header_bytes) == _header_from_json(vector["header"])
    assert env.parse_body(body).decode("utf-8") == vector["payload_json"]

    payload = _receive(
        envelope,
        uuid.UUID(vector["header"]["workspace_id"]),
        bytes.fromhex(key_entry["sign_pk_hex"]),
    )
    # Re-encoding is not part of verification (the signed artifact is the body
    # bytes), but a decode that loses information would silently break merges.
    assert OpPayload.decode(payload.encode()) == payload


@pytest.mark.parametrize("vector", _DOCUMENT["negative_vectors"], ids=lambda v: str(v["name"]))
def test_negative_vector_fails_closed_with_the_pinned_reason(
    vector: dict[str, Any],
) -> None:
    key_entry = _KEYS_BY_LABEL[vector["key"]]
    envelope = bytes.fromhex(vector["envelope_hex"])
    try:
        _receive(
            envelope,
            uuid.UUID(vector["expected_workspace_id"]),
            bytes.fromhex(key_entry["sign_pk_hex"]),
        )
    except (EnvelopeError, MalformedPayloadError) as rejection:
        assert rejection.reason == vector["reason"]
    else:
        pytest.fail(f"{vector['name']} was accepted; expected {vector['reason']}")


def test_non_zero_padding_vector_puts_the_byte_at_the_first_padding_position() -> None:
    """An off-by-one in the padding scan must not survive this vector."""
    vector = next(v for v in _DOCUMENT["negative_vectors"] if v["name"] == "non_zero_padding")
    _, body, _ = env.split_envelope(bytes.fromhex(vector["envelope_hex"]))
    payload_length = int.from_bytes(body[: env.PAYLOAD_LENGTH_PREFIX_BYTES], "big")
    first_padding_offset = env.PAYLOAD_LENGTH_PREFIX_BYTES + payload_length
    assert body[first_padding_offset] != 0
    assert not any(body[first_padding_offset + 1 :])


@pytest.mark.parametrize("vector", _DOCUMENT["aead_vectors"], ids=lambda v: str(v["name"]))
def test_aead_vector_seals_to_the_pinned_bytes(vector: dict[str, Any]) -> None:
    key_entry = _KEYS_BY_LABEL[vector["key"]]
    signing_key = SigningKey(bytes.fromhex(key_entry["seed_hex"]))
    header = _header_from_json(vector["header"])
    header_bytes = header.serialize()
    epoch_key = bytes.fromhex(vector["workspace_key_hex"])

    assert header.suite == env.SUITE_AEAD_V1
    assert header_bytes.hex() == vector["header_hex"]

    framed = env.frame_body(vector["payload_json"].encode("utf-8"))
    # The framed plaintext is byte for byte what plaintext_v1 would have carried.
    # That equality *is* the "aead_v1 is a body wrapper" claim, so it is asserted.
    assert framed.hex() == vector["framed_body_hex"]
    assert env.is_legal_body_length(len(framed))

    body = env.seal_body(header_bytes, framed, epoch_key)
    assert body.hex() == vector["body_hex"]
    assert len(body) == len(framed) + env.AEAD_TAG_BYTES
    assert env.is_legal_body_length_for_suite(env.SUITE_AEAD_V1, len(body))
    # ...and illegal for the other suite, which is the whole suite-conditional rule.
    assert not env.is_legal_body_length(len(body))

    envelope = env.build_envelope(header, body, signing_key)
    assert envelope.hex() == vector["envelope_hex"]
    assert env.envelope_hash(envelope).hex() == vector["envelope_sha256_hex"]


@pytest.mark.parametrize("vector", _DOCUMENT["aead_vectors"], ids=lambda v: str(v["name"]))
def test_aead_vector_opens_back_through_the_receive_order(vector: dict[str, Any]) -> None:
    key_entry = _KEYS_BY_LABEL[vector["key"]]
    envelope = bytes.fromhex(vector["envelope_hex"])
    header_bytes, body, _ = env.split_envelope(envelope)
    env.check_served(OpHeader.parse(header_bytes))

    # Verify **then** decrypt: Ed25519 authenticates the author, and only then does
    # the AEAD authenticate the header binding and the confidentiality.
    env.verify_envelope(envelope, bytes.fromhex(key_entry["sign_pk_hex"]))

    framed = env.open_body(header_bytes, body, bytes.fromhex(vector["workspace_key_hex"]))
    assert framed.hex() == vector["framed_body_hex"]
    # The padding rules run on the decrypted plaintext, through the same function
    # the plaintext suite uses.
    assert env.parse_body(framed).decode("utf-8") == vector["payload_json"]


@pytest.mark.parametrize("vector", _DOCUMENT["negative_aead_vectors"], ids=lambda v: str(v["name"]))
def test_negative_aead_vector_fails_closed_with_the_pinned_reason(
    vector: dict[str, Any],
) -> None:
    header_bytes, body, _ = env.split_envelope(bytes.fromhex(vector["envelope_hex"]))
    try:
        env.open_body(header_bytes, body, bytes.fromhex(vector["workspace_key_hex"]))
    except EnvelopeError as rejection:
        assert rejection.reason == vector["reason"]
    else:
        pytest.fail(f"{vector['name']} was accepted; expected {vector['reason']}")


@pytest.mark.parametrize("name", ["aead_tampered_ciphertext", "aead_tampered_header_key_epoch"])
def test_the_tampered_aead_vectors_still_carry_a_valid_author_signature(name: str) -> None:
    """Otherwise they would prove nothing about the AEAD.

    ``bad_signature`` would fire first and the AAD binding would go untested — which
    is precisely the property the header-tamper vector exists to demonstrate.
    """
    vector = next(v for v in _DOCUMENT["negative_aead_vectors"] if v["name"] == name)
    envelope = bytes.fromhex(vector["envelope_hex"])
    env.verify_envelope(envelope, bytes.fromhex(_KEYS_BY_LABEL[vector["key"]]["sign_pk_hex"]))


def test_a_control_op_under_suite_aead_v1_is_refused_by_check_served() -> None:
    vector = next(v for v in _DOCUMENT["negative_vectors"] if v["name"] == "encrypted_control_op")
    header_bytes, _, _ = env.split_envelope(bytes.fromhex(vector["envelope_hex"]))
    header = OpHeader.parse(header_bytes)
    assert header.suite == env.SUITE_AEAD_V1
    assert header.op_class == env.OP_CLASS_CONTROL
    # Both halves are individually served, and the pair is forbidden — which is why
    # this cannot be expressed as a served-set membership test.
    assert header.suite in env.SERVED_SUITES
    assert header.op_class in env.SERVED_OP_CLASSES
    with pytest.raises(env.EncryptedControlOpError):
        env.check_served(header)


def _wrap_vector(name: str) -> dict[str, Any]:
    return next(v for v in _DOCUMENT["keywrap_vectors"] if v["name"] == name)


@pytest.mark.parametrize("label", ["device_a", "device_b"])
def test_keywrap_seals_to_the_pinned_bytes_and_unwraps_back(label: str) -> None:
    vector = _wrap_vector(f"keywrap_{label}_epoch_1")
    workspace_id = uuid.UUID(vector["workspace_id"])
    member_id = uuid.UUID(vector["member_id"])
    kex_key_id = bytes.fromhex(vector["kex_key_id_hex"])
    kex_seed = bytes.fromhex(vector["kex_seed_hex"])

    # The kex key id is the same derivation the signing key id uses — literally the
    # same function, so the two cannot drift apart.
    assert (
        env.derive_key_id(bytes.fromhex(vector["kex_pk_hex"])).hex() == (vector["kex_key_id_hex"])
    )

    wrap = kw.wrap_epoch_key_for_member(
        workspace_key=bytes.fromhex(vector["workspace_key_hex"]),
        kex_pk=bytes.fromhex(vector["kex_pk_hex"]),
        workspace_id=workspace_id,
        epoch=vector["epoch"],
        member_id=member_id,
        kex_key_id=kex_key_id,
        ephemeral_secret_key=bytes.fromhex(vector["ephemeral_seed_hex"]),
        nonce=bytes.fromhex(vector["nonce_hex"]),
    )
    assert wrap.hex() == vector["wrap_hex"]
    assert len(wrap) == kw.KEYWRAP_BYTES
    # The info is the HKDF info *and* the AEAD AAD, so it is pinned once here rather
    # than left an internal detail.
    assert (
        kw.keywrap_info(
            ephemeral_public_key=wrap[: kw.EPHEMERAL_PUBLIC_KEY_BYTES],
            workspace_id=workspace_id,
            epoch=vector["epoch"],
            member_id=member_id,
            kex_key_id=kex_key_id,
        ).hex()
        == vector["info_hex"]
    )

    assert (
        kw.unwrap_epoch_key_for_member(
            wrap=wrap,
            kex_secret_key=kex_seed,
            workspace_id=workspace_id,
            epoch=vector["epoch"],
            member_id=member_id,
            kex_key_id=kex_key_id,
        ).hex()
        == vector["workspace_key_hex"]
    )


def test_the_escrow_wrap_seals_and_opens_under_the_master_wrap_key() -> None:
    vector = _wrap_vector("epoch_key_escrow_wrap_epoch_1")
    workspace_id = uuid.UUID(vector["workspace_id"])
    master_wrap_key = bytes.fromhex(vector["master_wrap_key_hex"])
    wrap = kw.wrap_epoch_key_for_escrow(
        workspace_key=bytes.fromhex(vector["workspace_key_hex"]),
        master_wrap_key=master_wrap_key,
        workspace_id=workspace_id,
        epoch=vector["epoch"],
        nonce=bytes.fromhex(vector["nonce_hex"]),
    )
    assert wrap.hex() == vector["wrap_hex"]
    assert len(wrap) == kw.EPOCH_KEY_ESCROW_WRAP_BYTES
    assert (
        kw.epoch_key_escrow_info(workspace_id=workspace_id, epoch=vector["epoch"]).hex()
        == vector["info_hex"]
    )
    assert (
        kw.unwrap_epoch_key_from_escrow(
            escrow_wrap=wrap,
            master_wrap_key=master_wrap_key,
            workspace_id=workspace_id,
            epoch=vector["epoch"],
        ).hex()
        == vector["workspace_key_hex"]
    )


def test_the_keywrap_digest_commits_to_the_whole_set_order_independently() -> None:
    vector = _wrap_vector("keywrap_digest_two_members_epoch_1")
    entries = [
        (
            uuid.UUID(entry["member_id"]),
            bytes.fromhex(entry["kex_key_id_hex"]),
            bytes.fromhex(entry["wrap_hex"]),
        )
        for entry in vector["member_wraps"]
    ]
    escrow_wrap = bytes.fromhex(vector["escrow_wrap_hex"])
    digest = kw.keywrap_digest(epoch=vector["epoch"], member_wraps=entries, escrow_wrap=escrow_wrap)
    assert digest.hex() == vector["digest_hex"]
    assert len(digest) == kw.KEYWRAP_DIGEST_BYTES
    # Sorted inside the digest, so an upload order the server chose cannot move the
    # commitment.
    assert (
        kw.keywrap_digest(
            epoch=vector["epoch"],
            member_wraps=list(reversed(entries)),
            escrow_wrap=escrow_wrap,
        ).hex()
        == vector["digest_hex"]
    )
    # Omitting a wrap, changing the epoch, or swapping the escrow wrap all move it —
    # which is what makes the digest a defence against a curating server.
    assert (
        kw.keywrap_digest(
            epoch=vector["epoch"], member_wraps=entries[:1], escrow_wrap=escrow_wrap
        ).hex()
        != vector["digest_hex"]
    )
    assert (
        kw.keywrap_digest(
            epoch=vector["epoch"] + 1, member_wraps=entries, escrow_wrap=escrow_wrap
        ).hex()
        != vector["digest_hex"]
    )
    assert (
        kw.keywrap_digest(
            epoch=vector["epoch"],
            member_wraps=entries,
            escrow_wrap=bytes(kw.EPOCH_KEY_ESCROW_WRAP_BYTES),
        ).hex()
        != vector["digest_hex"]
    )


@pytest.mark.parametrize(
    "name",
    ["keywrap_replayed_into_another_member_slot", "keywrap_replayed_into_another_epoch"],
)
def test_a_misrouted_keywrap_refuses(name: str) -> None:
    vector = _wrap_vector(name)
    with pytest.raises(EnvelopeError) as refusal:
        kw.unwrap_epoch_key_for_member(
            wrap=bytes.fromhex(vector["wrap_hex"]),
            kex_secret_key=bytes.fromhex(vector["kex_seed_hex"]),
            workspace_id=uuid.UUID(vector["workspace_id"]),
            epoch=vector["epoch"],
            member_id=uuid.UUID(vector["member_id"]),
            kex_key_id=bytes.fromhex(vector["kex_key_id_hex"]),
        )
    assert refusal.value.reason == vector["reason"]


def test_a_wrap_of_the_wrong_width_is_refused_before_any_crypto_runs() -> None:
    with pytest.raises(kw.MalformedKeyWrapError):
        kw.unwrap_epoch_key_for_member(
            wrap=bytes(kw.KEYWRAP_BYTES - 1),
            kex_secret_key=bytes(32),
            workspace_id=uuid.UUID(_IDENTITIES["workspace_id"]),
            epoch=1,
            member_id=uuid.UUID(_KEYS_BY_LABEL["device_a"]["member_id"]),
            kex_key_id=bytes(8),
        )


def test_a_low_order_epk_is_refused_before_any_key_is_derived() -> None:
    """Contributory behaviour: an all-zero ``epk`` yields a constant shared secret.

    A hostile server minting a wrap around a low-order point would know the whole
    key schedule, so the wrap could authenticate while installing a key the server
    chose — the exact property ADR-0037 claims the wrap format denies it.  The
    refusal must be ``malformed_keywrap``, not a bare ``RuntimeError`` escaping
    from libsodium.
    """
    genuine = bytes.fromhex(_wrap_vector("keywrap_device_a_epoch_1")["wrap_hex"])
    zero_epk_wrap = bytes(kw.EPHEMERAL_PUBLIC_KEY_BYTES) + genuine[kw.EPHEMERAL_PUBLIC_KEY_BYTES :]
    with pytest.raises(kw.MalformedKeyWrapError):
        kw.unwrap_epoch_key_for_member(
            wrap=zero_epk_wrap,
            kex_secret_key=bytes.fromhex(_wrap_vector("keywrap_device_a_epoch_1")["kex_seed_hex"]),
            workspace_id=uuid.UUID(_IDENTITIES["workspace_id"]),
            epoch=1,
            member_id=uuid.UUID(_KEYS_BY_LABEL["device_a"]["member_id"]),
            kex_key_id=bytes.fromhex(_wrap_vector("keywrap_device_a_epoch_1")["kex_key_id_hex"]),
        )


def test_the_hand_rolled_hkdf_matches_rfc_5869_test_case_1() -> None:
    """RFC 5869 A.1, so the hand-rolled expansion is checked against the standard.

    PyNaCl ships no HKDF (ADR-0037), and the golden vectors only prove that this
    implementation agrees with the Dart one — two wrong implementations would agree
    just as happily.  This anchors both of them to the RFC.
    """
    okm = kw.hkdf_sha256(
        ikm=bytes.fromhex("0b" * 22),
        salt=bytes.fromhex("000102030405060708090a0b0c"),
        info=bytes.fromhex("f0f1f2f3f4f5f6f7f8f9"),
        length=42,
    )
    assert okm.hex() == (
        "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
    )


def test_an_empty_hkdf_salt_is_the_rfcs_default_of_hashlen_zero_bytes() -> None:
    """The one reading the two languages could plausibly disagree about.

    ``package:cryptography``'s ``Hkdf`` calls the salt ``nonce`` and defaults it to
    empty; RFC 5869 says an absent salt is ``HashLen`` zeros.  If the Dart side ever
    meant "no salt at all" instead, every wrap would be unopenable across languages,
    so the equivalence is asserted rather than assumed.
    """
    assert kw.hkdf_sha256(b"ikm", b"", b"info", 32) == kw.hkdf_sha256(
        b"ikm", bytes(32), b"info", 32
    )


def test_body_size_class_arithmetic() -> None:
    assert env.padded_body_length(1) == 256
    assert env.padded_body_length(256) == 256
    assert env.padded_body_length(257) == 1024
    assert env.padded_body_length(16384) == 16384
    assert env.padded_body_length(16385) == 32768
    assert env.padded_body_length(32768) == 32768
    assert env.padded_body_length(32769) == 49152

    assert env.is_legal_body_length(256)
    assert env.is_legal_body_length(32768)
    assert env.is_legal_body_length(49152)
    assert not env.is_legal_body_length(0)
    assert not env.is_legal_body_length(300)
    assert not env.is_legal_body_length(16385)


def test_frame_body_round_trips_across_every_size_class_boundary() -> None:
    for payload_length in (0, 1, 251, 252, 253, 1019, 1020, 16379, 16380, 16381):
        payload = b"z" * payload_length
        body = env.frame_body(payload)
        assert env.is_legal_body_length(len(body))
        assert env.parse_body(body) == payload


# --- Control plane -----------------------------------------------------------


def test_control_constants_match_the_frozen_file() -> None:
    domains = _PROTOCOL["signing_domains"]
    assert domains["op_v1"] == env.SIGNING_DOMAIN_OP_V1.decode("ascii")
    assert domains["member_register_v1"] == control.SIGNING_DOMAIN_MEMBER_REGISTER_V1.decode(
        "ascii"
    )
    assert domains["workspace_genesis_v1"] == control.SIGNING_DOMAIN_WORKSPACE_GENESIS_V1.decode(
        "ascii"
    )
    assert domains["grant_v1"] == control.SIGNING_DOMAIN_GRANT_V1.decode("ascii")
    assert domains["revoke_v1"] == control.SIGNING_DOMAIN_REVOKE_V1.decode("ascii")
    assert domains["auth_challenge_v1"] == member_auth.SIGNING_DOMAIN_AUTH_CHALLENGE_V1.decode(
        "ascii"
    )
    assert domains["escrow_v1"] == esc.SIGNING_DOMAIN_ESCROW_V1.decode("ascii")
    # Seven distinct domains, or a signature made for one use would verify for
    # another (review F7).  Grant and Revoke are separate for exactly that
    # reason: an unmaking must never be replayable as a making.  The count is
    # asserted alongside the distinctness so an eighth domain cannot slip in
    # under prose that still says seven.
    assert len(domains) == 7
    assert len(set(domains.values())) == len(domains)

    frozen = _PROTOCOL["control"]
    assert frozen["member_register_type"] == control.CONTROL_TYPE_MEMBER_REGISTER
    assert frozen["workspace_genesis_type"] == control.CONTROL_TYPE_WORKSPACE_GENESIS
    assert frozen["grant_type"] == control.CONTROL_TYPE_GRANT
    assert frozen["revoke_type"] == control.CONTROL_TYPE_REVOKE
    assert frozen["rotate_type"] == control.CONTROL_TYPE_ROTATE
    assert frozen["served_control_types"] == sorted(control.SERVED_CONTROL_TYPES)
    assert frozen["member_kind_device"] == control.MEMBER_KIND_DEVICE
    assert frozen["member_kind_service"] == control.MEMBER_KIND_SERVICE
    assert frozen["prev_control_hash_bytes"] == control.PREV_CONTROL_HASH_BYTES
    assert frozen["zero_prev_control_hash_hex"] == control.ZERO_PREV_CONTROL_HASH.hex()
    assert frozen["kex_public_key_bytes"] == control.KEX_PUBLIC_KEY_BYTES
    assert frozen["granter_root"] == control.GRANTER_ROOT
    assert frozen["roles"] == list(control.KNOWN_ROLES)
    assert frozen["role_op_class_matrix"] == {
        str(op_class): sorted(roles)
        for op_class, roles in sorted(control.ROLE_OP_CLASS_MATRIX.items())
    }
    # op_class 2 is served now: that is what #548 changed about the wire, and this
    # slice widened what a control op may *say* rather than whether it is carried.
    assert env.OP_CLASS_CONTROL in env.SERVED_OP_CLASSES


def test_the_compaction_exemption_is_pinned_before_prune_exists() -> None:
    """#555 must honour a rule the vectors already froze.

    Compacting a control op away would delete the evidence a Grant ever existed,
    and a prune op is itself the attestation that history was removed.  Pinning
    the predicate now means prune inherits the rule rather than inventing it.
    """
    frozen = _PROTOCOL["control"]
    assert frozen["compaction_exempt_op_classes"] == sorted(control.COMPACTION_EXEMPT_OP_CLASSES)
    assert control.is_compaction_exempt(env.OP_CLASS_CONTROL)
    assert control.is_compaction_exempt(env.OP_CLASS_PRUNE)
    assert not control.is_compaction_exempt(env.OP_CLASS_CONTENT)
    assert not control.is_compaction_exempt(env.OP_CLASS_COMPACTION)


def test_both_implicit_workspace_ids_match_the_frozen_file() -> None:
    """Two derivation-addressed Workspaces per User, independent by construction.

    Neither id is computable from the other, which is what lets a client that
    knows only one reach only one.
    """
    assert _PROTOCOL["workspace_namespace_uuid"] == str(JEEVES_WORKSPACE_NAMESPACE)
    assert _PROTOCOL["user_preferences_workspace_namespace_uuid"] == str(
        USER_PREFERENCES_WORKSPACE_NAMESPACE
    )
    user_id = _IDENTITIES["user_id"]
    assert _IDENTITIES["workspace_id"] == str(default_workspace_id(user_id))
    assert _IDENTITIES["user_preferences_workspace_id"] == str(
        user_preferences_workspace_id(user_id)
    )
    assert _IDENTITIES["workspace_id"] != _IDENTITIES["user_preferences_workspace_id"]


@pytest.mark.parametrize("vector", _DOCUMENT["control_vectors"], ids=lambda v: str(v["name"]))
def test_control_vector_is_byte_identical(vector: dict[str, Any]) -> None:
    key_entry = _KEYS_BY_LABEL[vector["key"]]
    signing_key = SigningKey(bytes.fromhex(key_entry["seed_hex"]))
    header = _header_from_json(vector["header"])
    payload = vector["payload_json"].encode("utf-8")

    assert header.op_class == env.OP_CLASS_CONTROL
    assert header.serialize().hex() == vector["header_hex"]
    assert len(payload) == vector["payload_length_bytes"]

    body = env.frame_body(payload)
    assert body.hex() == vector["body_hex"]
    envelope = env.build_envelope(header, body, signing_key)
    assert envelope.hex() == vector["envelope_hex"]
    assert env.envelope_hash(envelope).hex() == vector["envelope_sha256_hex"]

    # The control chain link is over the payload bytes, never the envelope — and
    # the per-author link is over the envelope, never the payload.  Two different
    # hashes over two different byte ranges, and a codec that confused them would
    # fail right here.
    assert control.control_payload_hash(payload).hex() == vector["payload_sha256_hex"]
    assert control.control_payload_hash(payload).hex() != vector["envelope_sha256_hex"]


@pytest.mark.parametrize("vector", _DOCUMENT["control_vectors"], ids=lambda v: str(v["name"]))
def test_control_vector_round_trips_through_the_receive_pipeline(
    vector: dict[str, Any],
) -> None:
    envelope = bytes.fromhex(vector["envelope_hex"])
    decoded = _receive_control(envelope, _ROOT_PUBLIC_KEY)

    payload = ControlPayload.decode(env.parse_body(env.split_envelope(envelope)[1]))
    assert payload.control_type == vector["control_type"]
    assert payload.prev_control_hash.hex() == vector["prev_control_hash_hex"]

    if vector["control_type"] == control.CONTROL_TYPE_ROTATE:
        # No certificate and no separate signature — the fields *are* the payload, so
        # a round-trip through the payload codec is the whole of what there is to
        # check.  See RotateStatement for why that follows from where its authority
        # comes from.
        assert vector["cert_json"] == ""
        assert payload.signature == b""
        assert payload.authority == ""
        assert payload.to_json_dict() == json.loads(vector["payload_json"])
        assert decoded == payload.rotate_statement()
        return

    # The signed artifact is the certificate's literal bytes; re-encoding is not
    # part of verification, but a lossy decode would break every verifier.
    assert decoded.encode().decode("utf-8") == vector["cert_json"]
    assert decoded.encode().hex() == vector["cert_hex"]
    assert payload.signature.hex() == vector["signature_hex"]
    assert payload.authority == vector["authority"]


@pytest.mark.parametrize(
    "vector",
    [v for v in _DOCUMENT["control_vectors"] if v["control_type"] in _REGISTERING_TYPES],
    ids=lambda v: str(v["name"]),
)
def test_a_registering_control_vector_carries_its_authors_own_keys(
    vector: dict[str, Any],
) -> None:
    """An author's first op must be the control op that registers it.

    #548's rule was "a ``member_register`` is its author's op 1"; genesis
    generalises it, because genesis *is* the founding Device's registration
    (ADR-0031).  Either way the certificate has to carry the very key that signed
    the envelope, or the envelope could not be verified at all.
    """
    decoded = _receive_control(bytes.fromhex(vector["envelope_hex"]), _ROOT_PUBLIC_KEY)
    registration = (
        decoded.as_registration() if isinstance(decoded, control.GenesisCertificate) else decoded
    )
    key_entry = _KEYS_BY_LABEL[vector["key"]]
    assert _header_from_json(vector["header"]).author_seq == 1
    assert registration.sign_pk.hex() == key_entry["sign_pk_hex"]
    assert registration.kex_pk.hex() == key_entry["kex_pk_hex"]
    assert str(registration.member_id) == key_entry["member_id"]
    assert registration.member_kind == control.MEMBER_KIND_DEVICE


def test_the_canonical_control_chain_links_payload_hash_to_payload_hash() -> None:
    """Genesis first, zero link, then every successor naming its predecessor.

    This is the whole cross-author chain in one assertion: the ops are authored by
    two different devices under three different authorities, and the link is the
    same hash-of-payload-bytes throughout.
    """
    chain = _DOCUMENT["control_vectors"]
    assert [vector["control_type"] for vector in chain] == [
        control.CONTROL_TYPE_WORKSPACE_GENESIS,
        control.CONTROL_TYPE_GRANT,
        control.CONTROL_TYPE_MEMBER_REGISTER,
        control.CONTROL_TYPE_GRANT,
        control.CONTROL_TYPE_GRANT,
        control.CONTROL_TYPE_REVOKE,
        # The revoke-then-rotate pair `revokeAndRotate` authors back to back, which
        # is also what turning encryption on looks like: a rotate chains off the
        # control head like any other type, and its link is the same
        # hash-of-payload-bytes even though it carries no certificate.
        control.CONTROL_TYPE_ROTATE,
    ]
    assert chain[0]["prev_control_hash_hex"] == control.ZERO_PREV_CONTROL_HASH.hex()
    for predecessor, successor in zip(chain, chain[1:], strict=False):
        assert successor["prev_control_hash_hex"] == predecessor["payload_sha256_hex"]
        assert successor["prev_control_hash_hex"] != control.ZERO_PREV_CONTROL_HASH.hex()


def test_the_canonical_chain_pins_both_authority_shapes() -> None:
    """Root-minted owner Grants, and an owning Device minting a lesser role."""
    chain = _DOCUMENT["control_vectors"]
    owner_grants = [
        vector
        for vector in chain
        if vector["control_type"] == control.CONTROL_TYPE_GRANT
        and control.GrantCertificate.decode(bytes.fromhex(vector["cert_hex"])).role
        == control.ROLE_OWNER
    ]
    assert owner_grants, "the chain must exercise the Root-only owner mint"
    for vector in owner_grants:
        # The ceiling, in the vectors rather than only in the prose.
        assert vector["authority"] == control.GRANTER_ROOT

    member_signed = [
        vector
        for vector in chain
        if vector["control_type"] == control.CONTROL_TYPE_GRANT
        and vector["authority"] != control.GRANTER_ROOT
    ]
    assert len(member_signed) == 1
    grant = control.GrantCertificate.decode(bytes.fromhex(member_signed[0]["cert_hex"]))
    assert grant.role != control.ROLE_OWNER
    # Authority does not travel by courier: the envelope author, the payload's
    # authority and the certificate's granter are one member.
    assert grant.granter == member_signed[0]["authority"]
    assert member_signed[0]["header"]["author_member_id"] == grant.granter
    # A Grant carries no key material — that is the Grant/KeyWrap split (F19) — so
    # its grantee need not be anything this document holds a keypair for.
    assert str(grant.member_id) == _IDENTITIES["suggester_member_id"]


def test_the_canonical_chain_revokes_by_grant_id() -> None:
    """Revocation is grant-granular: it names a Grant, never a member (F19)."""
    chain = _DOCUMENT["control_vectors"]
    revoke_vector = next(
        vector for vector in chain if vector["control_type"] == control.CONTROL_TYPE_REVOKE
    )
    revoke = control.RevokeCertificate.decode(bytes.fromhex(revoke_vector["cert_hex"]))
    granted = {
        control.GrantCertificate.decode(bytes.fromhex(vector["cert_hex"])).grant_id
        for vector in chain
        if vector["control_type"] == control.CONTROL_TYPE_GRANT
    }
    assert revoke.grant_id in granted
    # Only Root revokes an owner; this one takes away a suggester, so it could
    # have been member-signed and is Root-signed here for the canonical path.
    assert revoke.revoker == control.GRANTER_ROOT


@pytest.mark.parametrize(
    "vector",
    [v for v in _DOCUMENT["control_vectors"] if v["control_type"] == control.CONTROL_TYPE_REVOKE],
    ids=lambda v: str(v["name"]),
)
def test_a_revokes_clock_is_stamped_with_its_authoring_devices_member_id(
    vector: dict[str, Any],
) -> None:
    """The HLC's tie-breaker node is a *member* id, never a certificate id.

    The control-fork tie-break compares the revoke certificate's HLC first and the
    author's member id second, so a node carrying the freshly minted ``revoke_id``
    would order revocations by certificate rather than by the device behind them.
    Mirrors ``backend/tests/sync/builders.py``'s ``revoke_certificate``.
    """
    revoke = control.RevokeCertificate.decode(bytes.fromhex(vector["cert_hex"]))
    author_member_id = uuid.UUID(_KEYS_BY_LABEL[vector["key"]]["member_id"])
    assert vector["header"]["author_member_id"] == str(author_member_id)
    assert revoke.revoked_at_hlc.member_id_hex == author_member_id.hex
    assert revoke.revoked_at_hlc.member_id_hex != revoke.revoke_id.hex


@pytest.mark.parametrize(
    "vector", _DOCUMENT["negative_control_vectors"], ids=lambda v: str(v["name"])
)
def test_negative_control_vector_fails_closed_with_the_pinned_reason(
    vector: dict[str, Any],
) -> None:
    envelope = bytes.fromhex(vector["envelope_hex"])
    try:
        _receive_control(envelope, _ROOT_PUBLIC_KEY)
    except (EnvelopeError, ControlPayloadError) as rejection:
        assert rejection.reason == vector["reason"]
    else:
        pytest.fail(f"{vector['name']} was accepted; expected {vector['reason']}")


def test_a_certificate_wrapped_around_another_devices_envelope_is_refused() -> None:
    """D6 step 4, the load-bearing one.

    A genuine Root-signed certificate is public once it is in the log.  Without
    checking the envelope signature against the certificate's own key, anyone
    holding a copy could wrap it around self-signed envelopes and manufacture
    forks in the victim's chain.
    """
    genuine = _DOCUMENT["control_vectors"][0]
    payload = env.parse_body(env.split_envelope(bytes.fromhex(genuine["envelope_hex"]))[1])
    header = _header_from_json(genuine["header"])

    forger = SigningKey(bytes.fromhex(_KEYS_BY_LABEL["device_b"]["seed_hex"]))
    forged = env.build_envelope(header, env.frame_body(payload), forger)

    with pytest.raises(env.BadSignatureEnvelopeError):
        _receive_control(forged, _ROOT_PUBLIC_KEY)


# --- Escrow and challenge preimages -----------------------------------------


def test_escrow_constants_match_the_frozen_file() -> None:
    frozen = _PROTOCOL["escrow"]
    assert frozen["blob_magic"] == esc.ESCROW_BLOB_MAGIC.decode("ascii")
    assert frozen["salt_bytes"] == esc.ESCROW_SALT_BYTES
    assert frozen["nonce_bytes"] == esc.ESCROW_NONCE_BYTES
    assert frozen["secret_bytes"] == esc.ESCROW_SECRET_BYTES
    assert frozen["blob_header_bytes"] == esc.ESCROW_BLOB_HEADER_BYTES
    assert frozen["blob_bytes"] == esc.ESCROW_BLOB_BYTES
    assert frozen["first_version"] == esc.FIRST_ESCROW_VERSION
    assert frozen["argon2id_floor"] == {
        "memory_kib": esc.ARGON2ID_FLOOR_MEMORY_KIB,
        "time_cost": esc.ARGON2ID_FLOOR_TIME_COST,
        "parallelism": esc.ARGON2ID_FLOOR_PARALLELISM,
    }


@pytest.mark.parametrize("vector", _DOCUMENT["escrow_vectors"], ids=lambda v: str(v["name"]))
def test_escrow_signature_vector_is_byte_identical(vector: dict[str, Any]) -> None:
    workspace_id = uuid.UUID(vector["workspace_id"])
    blob = bytes.fromhex(vector["blob_hex"])
    signing_input = esc.escrow_signing_input(workspace_id, vector["version"], blob)
    assert signing_input.hex() == vector["signing_input_hex"]
    # The slot is inside the signed bytes: workspace first, then the version.
    assert signing_input.startswith(esc.SIGNING_DOMAIN_ESCROW_V1 + workspace_id.bytes)

    root = SigningKey(bytes.fromhex(_IDENTITIES["root"]["seed_hex"]))
    assert (
        esc.sign_escrow(workspace_id, vector["version"], blob, root).hex() == vector["root_sig_hex"]
    )
    esc.verify_escrow_signature(
        workspace_id,
        vector["version"],
        blob,
        bytes.fromhex(vector["root_sig_hex"]),
        _ROOT_PUBLIC_KEY,
    )


def test_an_escrow_signature_does_not_transfer_between_slots_or_versions() -> None:
    first, second = _DOCUMENT["escrow_vectors"]
    assert first["root_sig_hex"] != second["root_sig_hex"]
    blob = bytes.fromhex(first["blob_hex"])
    signature = bytes.fromhex(first["root_sig_hex"])

    with pytest.raises(esc.EscrowSignatureError):
        esc.verify_escrow_signature(
            uuid.UUID(first["workspace_id"]), second["version"], blob, signature, _ROOT_PUBLIC_KEY
        )
    with pytest.raises(esc.EscrowSignatureError):
        esc.verify_escrow_signature(
            uuid.UUID(_IDENTITIES["other_workspace_id"]),
            first["version"],
            blob,
            signature,
            _ROOT_PUBLIC_KEY,
        )


@pytest.mark.parametrize(
    "vector", _DOCUMENT["member_challenge_vectors"], ids=lambda v: str(v["name"])
)
def test_member_challenge_vector_is_byte_identical(vector: dict[str, Any]) -> None:
    member_id = uuid.UUID(vector["member_id"])
    nonce = bytes.fromhex(vector["nonce_hex"])
    signing_input = member_auth.member_challenge_signing_input(member_id, nonce)
    assert signing_input.hex() == vector["signing_input_hex"]

    key_entry = _KEYS_BY_LABEL[vector["key"]]
    signing_key = SigningKey(bytes.fromhex(key_entry["seed_hex"]))
    assert signing_key.sign(signing_input).signature.hex() == vector["signature_hex"]
    member_auth.verify_member_challenge(
        member_id,
        nonce,
        bytes.fromhex(vector["signature_hex"]),
        bytes.fromhex(key_entry["sign_pk_hex"]),
    )

    # The member id is inside the preimage, so the same nonce under another
    # member's slot is a different signature.
    with pytest.raises(member_auth.MemberChallengeError):
        member_auth.verify_member_challenge(
            uuid.UUID(_KEYS_BY_LABEL["device_b"]["member_id"]),
            nonce,
            bytes.fromhex(vector["signature_hex"]),
            bytes.fromhex(key_entry["sign_pk_hex"]),
        )
