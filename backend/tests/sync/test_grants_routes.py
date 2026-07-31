"""The control plane's route contract: genesis, Grants, roles, revocation.

Everything here is *server-side* authorization, and every assertion is about
something a client is nevertheless obliged to check for itself.  That duplication
is the point of ADR-0028: the ``workspaces`` and ``grants`` tables are the
server's own index, authoritative for nobody, and a client's verdict comes from
the signed control ops in the log.  Refusing here closes the storage-DoS door;
refusing on the client is what makes role elevation impossible.
"""

from __future__ import annotations

import json
import uuid
from typing import Any, Protocol

import pytest_asyncio
from httpx import AsyncClient, Response
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.models import RefreshToken
from app.sync.control_payload import (
    CONTROL_TYPE_GRANT,
    GRANTER_ROOT,
    MEMBER_KIND_SERVICE,
    ROLE_COMPACTOR,
    ROLE_OWNER,
    ROLE_PARTICIPANT,
    ROLE_SUGGESTER,
    ZERO_PREV_CONTROL_HASH,
    ControlPayload,
    control_payload_hash,
    sign_grant_certificate,
)
from app.sync.envelope import OP_CLASS_CONTROL, parse_body, split_envelope
from app.sync.ids import default_workspace_id, user_preferences_workspace_id
from app.sync.models import Grant, Member, Workspace
from tests.conftest import auth_header
from tests.sync.builders import (
    Session,
    SpecDevice,
    SpecRoot,
    encode_all,
    found_workspace,
    member_token,
    open_session,
    user_id_from_token,
)
from tests.sync.helpers import detail_of
from tests.sync.test_ops_routes import _join_sibling, all_ops


@pytest_asyncio.fixture
async def session(client: AsyncClient) -> Session:
    """A founded default Workspace: genesis plus the founder's owner Grant."""
    return await open_session(client, "grants-owner@example.com")


@pytest_asyncio.fixture
async def unfounded(client: AsyncClient) -> Session:
    """Enrolled and credentialed, with nothing signed into existence yet."""
    return await open_session(client, "grants-unfounded@example.com", genesis=False)


async def _post(
    client: AsyncClient, session: Session, *envelopes: bytes, token: str | None = None
) -> Response:
    return await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(*envelopes),
        headers=auth_header(token) if token else session.headers,
    )


def _chain_after(envelope: bytes) -> bytes:
    return control_payload_hash(parse_body(split_envelope(envelope)[1]))


class _JsonDocument(Protocol):
    """What ``_forged_cert_bytes`` actually needs of a certificate.

    Structural, so every certificate dataclass satisfies it without declaring
    anything — and typed, so the call does not have to be excused with an
    ``attr-defined`` ignore against a bare ``object``.
    """

    def to_json_dict(self) -> dict[str, Any]: ...


def _forged_cert_bytes(certificate: _JsonDocument, **overrides: object) -> bytes:
    """Serialise a certificate document the codec refuses to *decode*.

    Some rules — an unknown role, an owner Grant minted by a member — are pure
    document invariants, so the dataclass cannot produce the shape the wire has to
    carry.  Building the JSON by hand is the only way to put those bytes on it.
    """
    document = certificate.to_json_dict() | overrides
    return json.dumps(document, separators=(",", ":")).encode("utf-8")


async def _found_preferences_workspace(client: AsyncClient, email: str) -> Session:
    """A founded ``user_preferences`` Workspace: its own escrow slot, its own genesis.

    Two slots per User is what keeps the server's control verification uniform —
    ``root_pk`` is resolved from the slot of the Workspace being posted to — and it
    survives shared Workspaces without a shape change.
    """
    prefs = await open_session(client, email, genesis=False)
    prefs.workspace_id = user_preferences_workspace_id(user_id_from_token(prefs.user_token))
    escrow = await client.put(
        f"/w/{prefs.workspace_id}/recovery",
        json=prefs.root.escrow_body(prefs.workspace_id),
        headers=prefs.user_headers,
    )
    assert escrow.status_code == 200, escrow.text
    await found_workspace(client, prefs)
    return prefs


async def _materialise_as_a_service(db: AsyncSession, member_id: uuid.UUID) -> None:
    """Stamp the kind a Service registration certificate would have carried.

    Done to the index directly because minting a Service *identity* is #557's, and
    what is under test here is the Grant rule rather than how the kind got set.
    """
    row = await db.get(Member, member_id)
    assert row is not None
    row.member_kind = MEMBER_KIND_SERVICE
    await db.commit()


# --- Genesis -----------------------------------------------------------------


async def test_genesis_materialises_the_workspace_and_the_founders_registration(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """One op does two jobs, and it has to (ADR-0031).

    Genesis is the Workspace's first control op *and* the founding Device's
    registration: the envelope's author key is unknowable before the certificate
    parses, and there is no earlier op to learn it from.
    """
    workspace = await db.get(Workspace, session.workspace_id)
    assert workspace is not None
    stored = await all_ops(db)
    assert workspace.genesis_seq == stored[0].seq

    # Participation *is* the Grants: there is no owner column, and the founder is
    # an owner only because a separate signed fact says so.
    grants = (
        (await db.execute(select(Grant).where(Grant.workspace_id == session.workspace_id)))
        .scalars()
        .all()
    )
    assert [(row.member_id, row.role, row.granter) for row in grants] == [
        (session.device.member_id, ROLE_OWNER, GRANTER_ROOT)
    ]
    assert grants[0].revoked_by_seq is None
    assert grants[0].granted_seq == stored[1].seq


async def test_a_second_genesis_is_refused(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """Genesis is first in the log as well as first in the batch.

    The server holds no control chain, so a second genesis is not a fork for it to
    resolve — it refuses and leaves the tie-break to the clients that do.
    """
    before = len(await all_ops(db))
    response = await _post(
        client, session, session.root.genesis_envelope(session.device, session.workspace_id)
    )
    assert response.status_code == 409, response.text
    assert detail_of(response) == {"code": "genesis_not_first", "index": 0}
    assert len(await all_ops(db)) == before


async def test_genesis_must_be_the_batchs_first_op(
    client: AsyncClient, unfounded: Session, db: AsyncSession
) -> None:
    content = unfounded.device.next_envelope(unfounded.workspace_id, advance=False)
    genesis = unfounded.root.genesis_envelope(
        unfounded.device, unfounded.workspace_id, author_seq=2
    )
    response = await _post(client, unfounded, content, genesis)
    assert response.status_code == 409, response.text
    # The content op is refused first, because at index 0 the Workspace does not
    # exist yet — which is the same refusal read from the other end.
    assert detail_of(response) == {"code": "workspace_not_created", "index": 0}
    assert await all_ops(db) == []


async def test_genesis_for_an_underivable_workspace_is_refused(
    client: AsyncClient, unfounded: Session
) -> None:
    """The v1 anti-junk-workspace rule.

    A stolen credential cannot fill the log with Workspaces nobody asked for.
    Real user-created Workspaces lift this by resolving membership instead.
    """
    stranger = default_workspace_id("somebody-entirely-else")
    envelope = unfounded.root.genesis_envelope(unfounded.device, stranger)
    response = await client.post(
        f"/w/{stranger}/ops", json=encode_all(envelope), headers=unfounded.headers
    )
    assert response.status_code == 403, response.text
    assert detail_of(response) == {"code": "workspace_not_derivable"}


async def test_a_genesis_naming_another_root_is_refused(
    client: AsyncClient, unfounded: Session
) -> None:
    """``root_pk`` inside the signed genesis must be the Root the slot holds.

    That cross-check is why it is in there at all: it gives every later verifier a
    log-internal comparison against the Root it pinned.
    """
    certificate = unfounded.root.genesis_certificate(
        unfounded.device, unfounded.workspace_id, root_pk=SpecRoot().root_pk
    )
    envelope = unfounded.root.genesis_envelope(
        unfounded.device, unfounded.workspace_id, certificate=certificate
    )
    response = await _post(client, unfounded, envelope)
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "cert_root_pk_mismatch", "index": 0}


# --- The pre-grant and pre-genesis GET rules --------------------------------


async def test_a_pre_genesis_get_returns_an_empty_page(
    client: AsyncClient, unfounded: Session
) -> None:
    """The observation the enrolment ceremony branches on.

    ``workspace_not_created`` is a POST-path refusal only.  A pre-genesis GET
    returning an error instead of an empty page would make the uniform step-5 pull
    impossible, and with it the log-state-conditioned genesis rule.
    """
    pulled = await client.get(f"/w/{unfounded.workspace_id}/ops", headers=unfounded.headers)
    assert pulled.status_code == 200, pulled.text
    assert pulled.json() == {"ops": [], "has_more": False}


async def test_a_pre_grant_member_may_read_before_it_claims_anything(
    client: AsyncClient, session: Session
) -> None:
    """Pull-before-claim, which is load-bearing rather than incidental.

    A device that authored before pulling would emit a fork-lie
    ``prev_control_hash``.  So the ceremony pulls first — while holding a member
    credential and **no Grant whatsoever** — and that is exactly what this GET
    rule exists to admit.  It reopens nothing: reads were always User-scoped by
    derivation, and the storage-DoS closure lives on the write path.
    """
    sibling, sibling_token = await _join_sibling(client, session)
    assert sibling is not None

    pulled = await client.get(f"/w/{session.workspace_id}/ops", headers=auth_header(sibling_token))
    assert pulled.status_code == 200, pulled.text
    assert len(pulled.json()["ops"]) == 2

    members = await client.get(
        f"/w/{session.workspace_id}/members", headers=auth_header(sibling_token)
    )
    assert members.status_code == 200, members.text


async def test_a_pre_grant_member_cannot_post_content(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """AC1, server half: the storage-DoS door the read rule leaves open elsewhere.

    An unchained member holding a member credential can no longer post junk
    content — the write path is where the closure lives.
    """
    sibling, sibling_token = await _join_sibling(client, session)
    before = len(await all_ops(db))
    response = await _post(
        client,
        session,
        sibling.next_envelope(session.workspace_id),
        token=sibling_token,
    )
    assert response.status_code == 403, response.text
    # No `revoked` flag: never granted is not the same claim as taken away.
    assert detail_of(response) == {"code": "no_live_grant", "index": 0}
    assert len(await all_ops(db)) == before


# --- The register-plus-grant batch ------------------------------------------


async def _enrol_participant(
    client: AsyncClient, session: Session, *, role: str = ROLE_PARTICIPANT
) -> tuple[SpecDevice, str, uuid.UUID]:
    """Bring a sibling in with a role the founder mints, in one batch.

    Root-signed for ``owner``; owner-signed for anything less, which is the shape
    that proves a Device can delegate without the passphrase.
    """
    sibling, sibling_token = await _join_sibling(client, session)
    register = session.root.member_register_envelope(
        sibling, session.workspace_id, prev_control_hash=session.control_head
    )
    posted = await _post(client, session, register, token=sibling_token)
    assert posted.status_code == 200, posted.text
    session.control_head = _chain_after(register)

    certificate = session.root.grant_certificate(
        session.workspace_id,
        member_id=sibling.member_id,
        role=role,
        granter=GRANTER_ROOT if role == ROLE_OWNER else str(session.device.member_id),
    )
    grant = session.root.grant_envelope(
        session.device,
        session.workspace_id,
        certificate=certificate,
        prev_control_hash=session.control_head,
        signing_key=None if role == ROLE_OWNER else session.device.signing_key,
    )
    posted = await _post(client, session, grant)
    assert posted.status_code == 200, posted.text
    session.control_head = _chain_after(grant)
    return sibling, sibling_token, certificate.grant_id


async def test_a_root_signed_batch_lands_without_the_author_holding_a_grant(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """How an ungranted device gets in at all.

    A root-signed control payload is admitted regardless of Grants — Root's
    signature is the strongest authority there is — and the batch that registers a
    Device is by definition authored before it holds one.
    """
    sibling, sibling_token = await _join_sibling(client, session)
    register = session.root.member_register_envelope(
        sibling, session.workspace_id, prev_control_hash=session.control_head
    )
    certificate = session.root.grant_certificate(
        session.workspace_id, member_id=sibling.member_id, role=ROLE_OWNER
    )
    grant = session.root.grant_envelope(
        sibling,
        session.workspace_id,
        certificate=certificate,
        prev_control_hash=_chain_after(register),
    )
    response = await _post(client, session, register, grant, token=sibling_token)
    assert response.status_code == 200, response.text

    row = await db.get(Grant, (session.workspace_id, certificate.grant_id))
    assert row is not None
    assert (row.member_id, row.role, row.revoked_by_seq) == (
        sibling.member_id,
        ROLE_OWNER,
        None,
    )

    # And the Grant counts from the moment it is materialised: a content op posted
    # next is authorized, which is "validity at the log position of signing".
    content = await _post(
        client, session, sibling.next_envelope(session.workspace_id), token=sibling_token
    )
    assert content.status_code == 200, content.text


async def test_a_grant_authored_earlier_in_a_batch_authorizes_a_later_content_op(
    client: AsyncClient, session: Session
) -> None:
    """The server materialises in arrival order, so index 1 counts for index 2."""
    sibling, sibling_token = await _join_sibling(client, session)
    register = session.root.member_register_envelope(
        sibling, session.workspace_id, prev_control_hash=session.control_head
    )
    certificate = session.root.grant_certificate(
        session.workspace_id, member_id=sibling.member_id, role=ROLE_OWNER
    )
    grant = session.root.grant_envelope(
        sibling,
        session.workspace_id,
        certificate=certificate,
        prev_control_hash=_chain_after(register),
    )
    content = sibling.next_envelope(session.workspace_id)
    response = await _post(client, session, register, grant, content, token=sibling_token)
    assert response.status_code == 200, response.text
    assert [result["duplicate"] for result in response.json()["results"]] == [False] * 3


# --- Roles and the matrix ---------------------------------------------------


async def test_a_participant_may_post_content(client: AsyncClient, session: Session) -> None:
    sibling, sibling_token, _grant_id = await _enrol_participant(client, session)
    response = await _post(
        client, session, sibling.next_envelope(session.workspace_id), token=sibling_token
    )
    assert response.status_code == 200, response.text


async def test_a_suggester_may_not_post_content(client: AsyncClient, session: Session) -> None:
    """The role exists, is granted, and is enforced to *deny* (#557 owns the rest)."""
    sibling, sibling_token, _grant_id = await _enrol_participant(
        client, session, role=ROLE_SUGGESTER
    )
    response = await _post(
        client, session, sibling.next_envelope(session.workspace_id), token=sibling_token
    )
    assert response.status_code == 403, response.text
    detail = detail_of(response)
    assert detail["code"] == "role_forbids_op_class"
    assert detail["roles"] == [ROLE_SUGGESTER]


async def test_a_compactor_may_not_post_content(client: AsyncClient, session: Session) -> None:
    """Compaction rows are defined and unserved; content is not theirs either."""
    sibling, sibling_token, _grant_id = await _enrol_participant(
        client, session, role=ROLE_COMPACTOR
    )
    response = await _post(
        client, session, sibling.next_envelope(session.workspace_id), token=sibling_token
    )
    assert response.status_code == 403, response.text
    assert detail_of(response)["code"] == "role_forbids_op_class"


async def test_a_participant_may_not_author_a_member_signed_control_op(
    client: AsyncClient, session: Session
) -> None:
    """Control ops that are not root-signed need a live *owner* Grant."""
    sibling, sibling_token, _grant_id = await _enrol_participant(client, session)
    certificate = session.root.grant_certificate(
        session.workspace_id,
        member_id=session.device.member_id,
        role=ROLE_SUGGESTER,
        granter=str(sibling.member_id),
    )
    envelope = session.root.grant_envelope(
        sibling,
        session.workspace_id,
        certificate=certificate,
        prev_control_hash=session.control_head,
        signing_key=sibling.signing_key,
    )
    response = await _post(client, session, envelope, token=sibling_token)
    assert response.status_code == 403, response.text
    assert detail_of(response)["code"] == "role_forbids_op_class"


# --- The owner ceiling ------------------------------------------------------


async def test_a_member_cannot_mint_an_owner_grant(client: AsyncClient, session: Session) -> None:
    """The mint half of the ceiling (ADR-0031).

    Devices *become* owners, via the Root-signed enrolment grant — but elevation
    to owner always takes the passphrase, exactly like demotion from it.  An
    owner-mints-owner rule would let a compromised device create an
    attacker-owner cheaply while removing one still cost Root.
    """
    sibling, _sibling_token = await _join_sibling(client, session)
    register = session.root.member_register_envelope(
        sibling, session.workspace_id, prev_control_hash=session.control_head
    )
    posted = await _post(client, session, register, token=await member_token(client, sibling))
    assert posted.status_code == 200, posted.text
    session.control_head = _chain_after(register)

    certificate = session.root.grant_certificate(
        session.workspace_id,
        member_id=sibling.member_id,
        role=ROLE_PARTICIPANT,
        granter=str(session.device.member_id),
    )
    cert_bytes = _forged_cert_bytes(certificate, role=ROLE_OWNER)
    envelope = session.device.next_envelope(
        session.workspace_id,
        op_class=OP_CLASS_CONTROL,
        payload=ControlPayload(
            control_type=CONTROL_TYPE_GRANT,
            prev_control_hash=session.control_head,
            cert_bytes=cert_bytes,
            signature=sign_grant_certificate(cert_bytes, session.device.signing_key),
            authority=str(session.device.member_id),
        ).encode(),
    )
    response = await _post(client, session, envelope)
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "owner_grant_requires_root", "index": 0}


async def test_a_member_cannot_revoke_an_owner_grant(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """The revoke half of the ceiling, and why revoking a Device takes Root.

    Devices are owners because the User acts through them, so this is F14f working
    as intended rather than an accident of the matrix.
    """
    sibling, sibling_token, _grant_id = await _enrol_participant(client, session, role=ROLE_OWNER)
    assert session.owner_grant_id is not None
    certificate = session.root.revoke_certificate(
        session.workspace_id,
        grant_id=session.owner_grant_id,
        revoker=str(sibling.member_id),
        revoker_member_id=sibling.member_id,
    )
    envelope = session.root.revoke_envelope(
        sibling,
        session.workspace_id,
        certificate=certificate,
        prev_control_hash=session.control_head,
        signing_key=sibling.signing_key,
    )
    response = await _post(client, session, envelope, token=sibling_token)
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "owner_revoke_requires_root", "index": 0}

    still_live = await db.get(Grant, (session.workspace_id, session.owner_grant_id))
    assert still_live is not None and still_live.revoked_by_seq is None


async def test_a_member_cannot_revoke_an_owner_grant_staged_in_the_same_batch(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """The ceiling holds against a Grant that has no ``grants`` row yet.

    The revoke half of the ceiling is the one that needs *state*: the frozen
    certificate names a ``grant_id``, not a role, so only a reader holding the
    Grant can tell an owner revocation from any other.  Within one batch that
    reader is ``_GrantIndex``'s in-memory walk rather than the table — nothing is
    flushed between ops — so a rule that consulted the database directly would let
    a mint-then-revoke pair slip the ceiling in a single POST.

    Which would be the whole ceiling gone: a member who can mint an owner Grant to
    a device it controls and revoke it in the same breath does not need Root for
    anything.  Both ops are refused together, because the batch is atomic.
    """
    sibling, sibling_token = await _join_sibling(client, session)
    register = session.root.member_register_envelope(
        sibling, session.workspace_id, prev_control_hash=session.control_head
    )
    posted = await _post(client, session, register, token=sibling_token)
    assert posted.status_code == 200, posted.text
    session.control_head = _chain_after(register)

    # Index 0: a genuine Root-signed owner Grant, which is legal on its own — and
    # authored by the sibling, because one POST speaks for exactly one Member (F10)
    # and a Root-signed control payload lands whatever Grants its author holds.
    minted = session.root.grant_certificate(
        session.workspace_id, member_id=sibling.member_id, role=ROLE_OWNER
    )
    grant = session.root.grant_envelope(
        sibling,
        session.workspace_id,
        certificate=minted,
        prev_control_hash=session.control_head,
    )
    # Index 1: the sibling revoking it under its own authority — an owner revoking
    # an owner, which is exactly what only Root may do.
    revoke = session.root.revoke_envelope(
        sibling,
        session.workspace_id,
        certificate=session.root.revoke_certificate(
            session.workspace_id,
            grant_id=minted.grant_id,
            revoker=str(sibling.member_id),
            revoker_member_id=sibling.member_id,
        ),
        prev_control_hash=_chain_after(grant),
        signing_key=sibling.signing_key,
    )

    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(grant, revoke),
        headers=auth_header(sibling_token),
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "owner_revoke_requires_root", "index": 1}

    # Neither op landed: the refusal is the batch's, not the second op's. Three
    # ops stand — the founding genesis and Grant, and the sibling's register.
    assert await db.get(Grant, (session.workspace_id, minted.grant_id)) is None
    assert len(await all_ops(db)) == 3
    # Guarded like its sibling above: an ``owner_grant_id`` the fixture failed to
    # set would otherwise reach ``db.get`` as a ``None`` key component and fail
    # somewhere far from the cause.
    assert session.owner_grant_id is not None
    still_live = await db.get(Grant, (session.workspace_id, session.owner_grant_id))
    assert still_live is not None and still_live.revoked_by_seq is None


# --- Fail-closed grantees ---------------------------------------------------


async def test_a_grant_to_an_unregistered_member_is_refused(
    client: AsyncClient, session: Session
) -> None:
    """Never a dangling forward reference.

    The server's bar is the same one the client's chain-gated directory applies: a
    grantee it cannot resolve is refused rather than held pending.
    """
    certificate = session.root.grant_certificate(
        session.workspace_id, member_id=uuid.uuid4(), role=ROLE_PARTICIPANT
    )
    envelope = session.root.grant_envelope(
        session.device,
        session.workspace_id,
        certificate=certificate,
        prev_control_hash=session.control_head,
    )
    response = await _post(client, session, envelope)
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "unknown_grantee", "index": 0}


async def test_a_grant_to_a_shell_row_with_no_registration_is_refused(
    client: AsyncClient, session: Session
) -> None:
    """``POST /members`` confers nothing, and a Grant cannot borrow authority."""
    sibling, _token = await _join_sibling(client, session)
    certificate = session.root.grant_certificate(
        session.workspace_id, member_id=sibling.member_id, role=ROLE_PARTICIPANT
    )
    envelope = session.root.grant_envelope(
        session.device,
        session.workspace_id,
        certificate=certificate,
        prev_control_hash=session.control_head,
    )
    response = await _post(client, session, envelope)
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "unknown_grantee", "index": 0}


async def test_a_revoke_naming_an_unknown_grant_is_refused(
    client: AsyncClient, session: Session
) -> None:
    """``unknown_grant``, not ``unknown_grantee``.

    A Revoke names a ``grant_id``, so the thing it fails to resolve is a Grant.
    Reusing the grantee code would leave a client unable to tell a failed
    revocation from an invalid grantee.
    """
    certificate = session.root.revoke_certificate(
        session.workspace_id, grant_id=uuid.uuid4(), revoker_member_id=session.device.member_id
    )
    envelope = session.root.revoke_envelope(
        session.device,
        session.workspace_id,
        certificate=certificate,
        prev_control_hash=session.control_head,
    )
    response = await _post(client, session, envelope)
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "unknown_grant", "index": 0}


async def test_a_grant_signed_by_someone_other_than_its_author_is_refused(
    client: AsyncClient, session: Session
) -> None:
    """Authority does not travel by courier.

    The signed certificate names its own granter; the payload's ``granter`` field
    only says which key to check it against.  Neither may disagree with the
    envelope's author.
    """
    sibling, sibling_token, _grant_id = await _enrol_participant(client, session, role=ROLE_OWNER)
    certificate = session.root.grant_certificate(
        session.workspace_id,
        member_id=session.device.member_id,
        role=ROLE_SUGGESTER,
        granter=str(session.device.member_id),
    )
    # Authored by the sibling, but claiming the founder's authority.
    envelope = session.root.grant_envelope(
        sibling,
        session.workspace_id,
        certificate=certificate,
        prev_control_hash=session.control_head,
        signing_key=session.device.signing_key,
    )
    response = await _post(client, session, envelope, token=sibling_token)
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "cert_granter_mismatch", "index": 0}


async def test_a_grant_whose_certificate_disagrees_about_the_granter_is_refused(
    client: AsyncClient, session: Session
) -> None:
    """The same code, one step earlier: the certificate and the payload disagree.

    Distinct from the case above, which reaches ``cert_granter_mismatch`` inside
    ``_authority_public_key`` because the *author* is not the authority it claims.
    Here author and authority agree and the **certificate** names somebody else.
    The certificate is Root-signed and the payload nominates Root, so
    ``verify_grant_certificate`` passes and only the field comparison refuses —
    which is why ``bad_grant_signature`` would name the wrong thing (#580).
    """
    certificate = session.root.grant_certificate(
        session.workspace_id,
        member_id=session.device.member_id,
        role=ROLE_SUGGESTER,
        granter=str(session.device.member_id),
    )
    envelope = session.root.grant_envelope(
        session.device,
        session.workspace_id,
        certificate=certificate,
        prev_control_hash=session.control_head,
        authority=GRANTER_ROOT,
    )
    response = await _post(client, session, envelope)
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "cert_granter_mismatch", "index": 0}


async def test_a_registration_naming_another_workspace_is_refused(
    client: AsyncClient, session: Session
) -> None:
    """A Root-signed certificate must name the Workspace it is posted into.

    Not the header-level ``workspace_mismatch``: the envelope header names this
    Workspace, so the route was reached honestly and the *document* is what
    disagrees. The client draws the same distinction under the same code (#580).
    """
    sibling, sibling_token = await _join_sibling(client, session)
    certificate = session.root.certificate(sibling, default_workspace_id("somebody-entirely-else"))
    envelope = session.root.member_register_envelope(
        sibling,
        session.workspace_id,
        prev_control_hash=session.control_head,
        certificate=certificate,
    )
    response = await _post(client, session, envelope, token=sibling_token)
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "cert_workspace_mismatch", "index": 0}


# --- The preferences Workspace ----------------------------------------------


async def test_the_preferences_workspace_refuses_a_service_grant(
    client: AsyncClient, db: AsyncSession
) -> None:
    """ "Every Device, no Service ever" — structurally, not by policy.

    That boundary is why preferences are a Workspace of their own: a preference
    can never leak through an AI grant, because the Grant itself is refused.
    """
    prefs = await _found_preferences_workspace(client, "grants-prefs-owner@example.com")

    # A Service member, registered and then materialised as a Service kind.
    service = SpecDevice()
    registered = await client.post(
        "/members", json=service.registration_body(), headers=prefs.user_headers
    )
    assert registered.status_code == 201, registered.text
    service_token = await member_token(client, service)
    service_certificate = prefs.root.certificate(service, prefs.workspace_id)
    service_register = prefs.root.member_register_envelope(
        service,
        prefs.workspace_id,
        prev_control_hash=prefs.control_head,
        certificate=service_certificate,
    )
    posted = await _post(client, prefs, service_register, token=service_token)
    assert posted.status_code == 200, posted.text
    prefs.control_head = _chain_after(service_register)

    await _materialise_as_a_service(db, service.member_id)

    certificate = prefs.root.grant_certificate(
        prefs.workspace_id, member_id=service.member_id, role=ROLE_SUGGESTER
    )
    envelope = prefs.root.grant_envelope(
        prefs.device,
        prefs.workspace_id,
        certificate=certificate,
        prev_control_hash=prefs.control_head,
    )
    response = await _post(client, prefs, envelope)
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "service_grant_forbidden", "index": 0}


async def test_the_default_workspace_admits_a_service_grant(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """The mirror: the rule is the preferences Workspace's, not a global ban."""
    service = SpecDevice()
    registered = await client.post(
        "/members", json=service.registration_body(), headers=session.user_headers
    )
    assert registered.status_code == 201, registered.text
    service_token = await member_token(client, service)
    register = session.root.member_register_envelope(
        service, session.workspace_id, prev_control_hash=session.control_head
    )
    posted = await _post(client, session, register, token=service_token)
    assert posted.status_code == 200, posted.text
    session.control_head = _chain_after(register)

    await _materialise_as_a_service(db, service.member_id)

    certificate = session.root.grant_certificate(
        session.workspace_id, member_id=service.member_id, role=ROLE_SUGGESTER
    )
    envelope = session.root.grant_envelope(
        session.device,
        session.workspace_id,
        certificate=certificate,
        prev_control_hash=session.control_head,
    )
    response = await _post(client, session, envelope)
    assert response.status_code == 200, response.text


# --- Revocation -------------------------------------------------------------


async def test_revoking_the_last_grant_refuses_reads_writes_and_kills_the_transport(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """AC1 and the revocation obligations, in one pass.

    A revoked member is refused on **POST and GET immediately**, and its refresh
    tokens die: revocation has to reach the transport, not merely the index, or a
    removed device keeps a working credential.
    """
    sibling, sibling_token, grant_id = await _enrol_participant(client, session)
    # It works before the revocation, so the refusal afterwards is the revocation
    # and not something that was never allowed.
    assert (
        await _post(
            client, session, sibling.next_envelope(session.workspace_id), token=sibling_token
        )
    ).status_code == 200

    certificate = session.root.revoke_certificate(
        session.workspace_id, grant_id=grant_id, revoker_member_id=session.device.member_id
    )
    envelope = session.root.revoke_envelope(
        session.device,
        session.workspace_id,
        certificate=certificate,
        prev_control_hash=session.control_head,
    )
    revoked = await _post(client, session, envelope)
    assert revoked.status_code == 200, revoked.text
    session.control_head = _chain_after(envelope)

    row = await db.get(Grant, (session.workspace_id, grant_id))
    assert row is not None and row.revoked_by_seq is not None
    # The boundary is a *seq*, not an HLC: anchoring on the certificate's clock
    # would let a revoked author backdate ops under it.
    assert row.revoked_by_seq > row.granted_seq

    refused_post = await _post(
        client, session, sibling.next_envelope(session.workspace_id), token=sibling_token
    )
    assert refused_post.status_code == 403, refused_post.text
    assert detail_of(refused_post) == {
        "code": "no_live_grant",
        "index": 0,
        "revoked": True,
    }

    refused_pull = await client.get(
        f"/w/{session.workspace_id}/ops", headers=auth_header(sibling_token)
    )
    assert refused_pull.status_code == 403, refused_pull.text
    assert detail_of(refused_pull) == {"code": "no_live_grant", "revoked": True}

    live = (
        (
            await db.execute(
                select(RefreshToken).where(
                    RefreshToken.member_id == sibling.member_id,
                    RefreshToken.revoked_at.is_(None),
                )
            )
        )
        .scalars()
        .all()
    )
    assert live == []


async def test_re_revoking_a_grant_is_refused_and_leaves_the_boundary_put(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """The revocation boundary is immutable once stamped.

    The authorization verdict is positional — ``granted_seq < S < revoked_by_seq``
    — so letting a second Revoke move ``revoked_by_seq`` forward would *widen* the
    window an already-revoked Grant covers, re-admitting ops authored after the
    first revocation.  Refused rather than silently ignored, so the client learns
    the Grant is already gone instead of believing it just revoked it.
    """
    _sibling, _token, participant_grant_id = await _enrol_participant(client, session)
    first = session.root.revoke_envelope(
        session.device,
        session.workspace_id,
        certificate=session.root.revoke_certificate(
            session.workspace_id,
            grant_id=participant_grant_id,
            revoker_member_id=session.device.member_id,
        ),
        prev_control_hash=session.control_head,
    )
    assert (await _post(client, session, first)).status_code == 200
    session.control_head = _chain_after(first)
    revoked = await db.get(Grant, (session.workspace_id, participant_grant_id))
    assert revoked is not None
    boundary = revoked.revoked_by_seq
    assert boundary is not None

    second = session.root.revoke_envelope(
        session.device,
        session.workspace_id,
        certificate=session.root.revoke_certificate(
            session.workspace_id,
            grant_id=participant_grant_id,
            revoker_member_id=session.device.member_id,
        ),
        prev_control_hash=session.control_head,
    )
    response = await _post(client, session, second)
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "already_revoked", "index": 0}

    await db.refresh(revoked)
    assert revoked.revoked_by_seq == boundary


async def test_revoking_one_of_two_grants_leaves_the_member_live(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """Revocation is grant-granular, so "revoked" means *no live Grant left*."""
    sibling, sibling_token, participant_grant_id = await _enrol_participant(client, session)
    second = session.root.grant_certificate(
        session.workspace_id,
        member_id=sibling.member_id,
        role=ROLE_COMPACTOR,
        granter=str(session.device.member_id),
    )
    grant = session.root.grant_envelope(
        session.device,
        session.workspace_id,
        certificate=second,
        prev_control_hash=session.control_head,
        signing_key=session.device.signing_key,
    )
    assert (await _post(client, session, grant)).status_code == 200
    session.control_head = _chain_after(grant)

    certificate = session.root.revoke_certificate(
        session.workspace_id,
        grant_id=participant_grant_id,
        revoker_member_id=session.device.member_id,
    )
    envelope = session.root.revoke_envelope(
        session.device,
        session.workspace_id,
        certificate=certificate,
        prev_control_hash=session.control_head,
    )
    assert (await _post(client, session, envelope)).status_code == 200
    session.control_head = _chain_after(envelope)

    # Still a member in good standing — so reads are admitted — but the surviving
    # role is a compactor's, and content is not a compactor's to write.
    pulled = await client.get(f"/w/{session.workspace_id}/ops", headers=auth_header(sibling_token))
    assert pulled.status_code == 200, pulled.text
    refused = await _post(
        client, session, sibling.next_envelope(session.workspace_id), token=sibling_token
    )
    assert refused.status_code == 403, refused.text
    assert detail_of(refused)["code"] == "role_forbids_op_class"

    live = (
        (
            await db.execute(
                select(RefreshToken).where(
                    RefreshToken.member_id == sibling.member_id,
                    RefreshToken.revoked_at.is_(None),
                )
            )
        )
        .scalars()
        .all()
    )
    assert live != [], "a member with a live Grant keeps its transport credential"


async def test_revoking_a_granter_does_not_cascade(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """F14c: a fact valid at the position it was signed at stands.

    Nothing re-evaluates it, which *is* the no-cascade rule — and it is what makes
    late arrivals honest rather than retroactively refused.
    """
    granter, granter_token, granter_grant_id = await _enrol_participant(
        client, session, role=ROLE_OWNER
    )
    grantee, grantee_token = await _join_sibling(client, session)
    register = session.root.member_register_envelope(
        grantee, session.workspace_id, prev_control_hash=session.control_head
    )
    assert (await _post(client, session, register, token=grantee_token)).status_code == 200
    session.control_head = _chain_after(register)

    delegated = session.root.grant_certificate(
        session.workspace_id,
        member_id=grantee.member_id,
        role=ROLE_PARTICIPANT,
        granter=str(granter.member_id),
    )
    grant = session.root.grant_envelope(
        granter,
        session.workspace_id,
        certificate=delegated,
        prev_control_hash=session.control_head,
        signing_key=granter.signing_key,
    )
    assert (await _post(client, session, grant, token=granter_token)).status_code == 200
    session.control_head = _chain_after(grant)

    # Now Root removes the granter.
    certificate = session.root.revoke_certificate(
        session.workspace_id, grant_id=granter_grant_id, revoker_member_id=session.device.member_id
    )
    envelope = session.root.revoke_envelope(
        session.device,
        session.workspace_id,
        certificate=certificate,
        prev_control_hash=session.control_head,
    )
    assert (await _post(client, session, envelope)).status_code == 200
    session.control_head = _chain_after(envelope)

    delegated_row = await db.get(Grant, (session.workspace_id, delegated.grant_id))
    assert delegated_row is not None and delegated_row.revoked_by_seq is None
    still_works = await _post(
        client, session, grantee.next_envelope(session.workspace_id), token=grantee_token
    )
    assert still_works.status_code == 200, still_works.text


async def test_replaying_a_revoke_does_not_move_the_boundary(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """A duplicate must not re-materialise: ``revoked_by_seq`` names one op."""
    _sibling, _token, grant_id = await _enrol_participant(client, session)
    certificate = session.root.revoke_certificate(
        session.workspace_id, grant_id=grant_id, revoker_member_id=session.device.member_id
    )
    envelope = session.root.revoke_envelope(
        session.device,
        session.workspace_id,
        certificate=certificate,
        prev_control_hash=session.control_head,
        advance=False,
    )
    assert (await _post(client, session, envelope)).status_code == 200
    row = await db.get(Grant, (session.workspace_id, grant_id))
    assert row is not None
    first_boundary = row.revoked_by_seq

    replay = await _post(client, session, envelope)
    assert replay.status_code == 200, replay.text
    assert [result["duplicate"] for result in replay.json()["results"]] == [True]
    await db.refresh(row)
    assert row.revoked_by_seq == first_boundary


async def test_a_grant_id_cannot_be_reused_by_a_different_op(
    client: AsyncClient, session: Session
) -> None:
    """A verbatim replay is dedupe; a *different* op on one grant id is refused."""
    _sibling, _token, grant_id = await _enrol_participant(client, session)
    duplicate = session.root.grant_certificate(
        session.workspace_id,
        member_id=session.device.member_id,
        role=ROLE_SUGGESTER,
        granter=str(session.device.member_id),
        grant_id=grant_id,
    )
    envelope = session.root.grant_envelope(
        session.device,
        session.workspace_id,
        certificate=duplicate,
        prev_control_hash=session.control_head,
        signing_key=session.device.signing_key,
    )
    response = await _post(client, session, envelope)
    assert response.status_code == 409, response.text
    assert detail_of(response) == {"code": "grant_id_already_used", "index": 0}


async def test_an_unknown_role_fails_closed(client: AsyncClient, session: Session) -> None:
    """A role a verifier cannot interpret is never a permissive default."""
    certificate = session.root.grant_certificate(
        session.workspace_id, member_id=session.device.member_id, role=ROLE_PARTICIPANT
    )
    cert_bytes = _forged_cert_bytes(certificate, role="archivist")
    envelope = session.device.next_envelope(
        session.workspace_id,
        op_class=OP_CLASS_CONTROL,
        payload=ControlPayload(
            control_type=CONTROL_TYPE_GRANT,
            prev_control_hash=session.control_head,
            cert_bytes=cert_bytes,
            signature=sign_grant_certificate(cert_bytes, session.root.signing_key),
            authority=GRANTER_ROOT,
        ).encode(),
    )
    response = await _post(client, session, envelope)
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "unknown_role", "index": 0}


async def test_a_grant_with_a_zero_chain_link_is_refused(
    client: AsyncClient, session: Session
) -> None:
    """The genesis-only zero-link rule covers every control type, not just registers."""
    certificate = session.root.grant_certificate(
        session.workspace_id,
        member_id=session.device.member_id,
        role=ROLE_SUGGESTER,
        granter=str(session.device.member_id),
    )
    envelope = session.root.grant_envelope(
        session.device,
        session.workspace_id,
        certificate=certificate,
        prev_control_hash=ZERO_PREV_CONTROL_HASH,
        signing_key=session.device.signing_key,
    )
    response = await _post(client, session, envelope)
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "control_chain_break", "index": 0}
