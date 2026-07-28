"""The op-log transport contract.

``app/test/sync/fake_sync_server_contract_test.dart`` mirrors this file
case-for-case under the same test names.  The in-process fake the harness runs
against is only worth anything if it behaves like the real server, and a
missing or failing twin is how a divergence announces itself.
"""

from __future__ import annotations

import base64
import uuid

import pytest
import pytest_asyncio
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.sync.control_payload import (
    CONTROL_TYPE_MEMBER_REGISTER,
    MEMBER_KIND_DEVICE,
    ZERO_PREV_CONTROL_HASH,
    ControlPayload,
    control_payload_hash,
)
from app.sync.envelope import (
    HEADER_LENGTH_BYTES,
    MINIMUM_ENVELOPE_BYTES,
    OP_CLASS_COMPACTION,
    OP_CLASS_CONTENT,
    OP_CLASS_CONTROL,
    OpHeader,
    build_envelope,
    derive_key_id,
    frame_body,
    parse_body,
    split_envelope,
)
from app.sync.ids import default_workspace_id
from app.sync.models import Member, Op
from tests.conftest import auth_header, register
from tests.sync.builders import (
    SpecDevice,
    SpecRoot,
    encode,
    encode_all,
    user_id_from_token,
)


class Session:
    """One user, one Root, one registered device holding a member token.

    ``headers`` is the *member* credential — the sync data routes take nothing
    else.  ``user_headers`` is the User credential the registry and escrow
    routes take, and the two are deliberately not interchangeable.

    ``control_head`` tracks the cross-author chain link the next control op must
    name, exactly as a pulling client would compute it: SHA-256 over the previous
    control op's payload bytes.
    """

    def __init__(
        self,
        token: str,
        member_token: str,
        workspace_id: uuid.UUID,
        device: SpecDevice,
        root: SpecRoot,
    ) -> None:
        self.token = token
        self.member_token = member_token
        self.workspace_id = workspace_id
        self.device = device
        self.root = root
        self.control_head = ZERO_PREV_CONTROL_HASH
        #: The founding device's own owner Grant, for tests that revoke it.
        self.owner_grant_id: uuid.UUID | None = None
        #: The highest seq the founding ceremony spent, so a pull test can start
        #: its cursor past the control ops rather than paging through them.
        self.founded_through_seq = 0

    @property
    def headers(self) -> dict[str, str]:
        return auth_header(self.member_token)

    @property
    def user_headers(self) -> dict[str, str]:
        return auth_header(self.token)

    def advance_control_head(self, envelope: bytes) -> bytes:
        """Record ``envelope`` as the new control head and return it unchanged."""
        self.control_head = control_payload_hash(parse_body(split_envelope(envelope)[1]))
        return envelope


async def _member_token(client: AsyncClient, device: SpecDevice) -> str:
    challenge = await client.post(f"/members/{device.member_id}/challenge")
    assert challenge.status_code == 200, challenge.text
    nonce = challenge.json()["nonce"]
    exchanged = await client.post(
        f"/members/{device.member_id}/token",
        json={"nonce": nonce, "signature": device.challenge_signature(nonce)},
    )
    assert exchanged.status_code == 200, exchanged.text
    token: str = exchanged.json()["access_token"]
    return token


async def _open_session(
    client: AsyncClient,
    email: str,
    *,
    workspace_id: uuid.UUID | None = None,
    genesis: bool = True,
) -> Session:
    """Enrol one device, and by default run its two-op founding ceremony.

    ``genesis=False`` stops after the member credential, leaving a device that is
    enrolled and holds **no Grant whatsoever** — the state the real ceremony pulls
    the control log in, and the state every ``no_live_grant`` test needs.
    """
    token = await register(client, email)
    resolved_workspace_id = workspace_id or default_workspace_id(user_id_from_token(token))
    root = SpecRoot()
    # Account creation writes the escrow in the same breath: without a stored
    # root_pk the server has no Root to check a control op against.
    escrow = await client.put(
        f"/w/{resolved_workspace_id}/recovery",
        json=root.escrow_body(resolved_workspace_id),
        headers=auth_header(token),
    )
    assert escrow.status_code == 200, escrow.text

    device = SpecDevice()
    response = await client.post(
        "/members", json=device.registration_body(), headers=auth_header(token)
    )
    assert response.status_code == 201, response.text
    session = Session(
        token, await _member_token(client, device), resolved_workspace_id, device, root
    )
    if genesis:
        await _found_workspace(client, session)
    return session


async def _found_workspace(client: AsyncClient, session: Session) -> None:
    """The founding ceremony: genesis, then a root-signed owner self-grant.

    Two ops in one batch and in that order, exactly as ``EnrolmentService`` posts
    them.  Genesis embeds the founder's registration, so there is no separate
    ``member_register`` for the founding device.
    """
    genesis = session.advance_control_head(
        session.root.genesis_envelope(session.device, session.workspace_id)
    )
    grant_certificate = session.root.grant_certificate(
        session.workspace_id, member_id=session.device.member_id
    )
    grant = session.advance_control_head(
        session.root.grant_envelope(
            session.device,
            session.workspace_id,
            certificate=grant_certificate,
            prev_control_hash=control_payload_hash(parse_body(split_envelope(genesis)[1])),
        )
    )
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(genesis, grant),
        headers=session.headers,
    )
    assert response.status_code == 200, response.text
    session.owner_grant_id = grant_certificate.grant_id
    session.founded_through_seq = max(result["seq"] for result in response.json()["results"])


@pytest_asyncio.fixture
async def session(client: AsyncClient) -> Session:
    return await _open_session(client, "ops-owner@example.com")


@pytest_asyncio.fixture
async def ungranted_session(client: AsyncClient) -> Session:
    """Enrolled, credentialed, and holding no Grant — the pre-grant state."""
    return await _open_session(client, "ops-ungranted@example.com", genesis=False)


def detail_of(response: object) -> dict[str, object]:
    """The structured error object every route rejection carries."""
    body = response.json()  # type: ignore[attr-defined]
    detail = body["detail"]
    assert isinstance(detail, dict), detail
    return detail


async def content_ops(db: AsyncSession) -> list[Op]:
    """Only the content rows, in seq order.

    Every founded Workspace's log opens with the two control ops of its founding
    ceremony — the genesis and the owner self-grant — so a test about *content*
    appends filters them out rather than counting them.
    """
    rows = await db.execute(select(Op).where(Op.op_class == OP_CLASS_CONTENT).order_by(Op.seq))
    return list(rows.scalars().all())


async def all_ops(db: AsyncSession) -> list[Op]:
    """Every row, in seq order — the founding control ops included."""
    rows = await db.execute(select(Op).order_by(Op.seq))
    return list(rows.scalars().all())


#: The founding ceremony spends the founding device's first two chain slots, so
#: its first content op sits here.
FIRST_CONTENT_AUTHOR_SEQ = 3


async def _join_sibling(client: AsyncClient, session: Session) -> tuple[SpecDevice, str]:
    """Register a second Device's keys and take its member credential.

    It holds **no Grant**: a register-plus-grant batch is what it posts next.
    Everything about a *bad* ``member_register`` is tested through a sibling
    rather than through the founder, whose registration the genesis already
    embedded — the founder has no separate register to get wrong.
    """
    sibling = SpecDevice()
    response = await client.post(
        "/members", json=sibling.registration_body(), headers=session.user_headers
    )
    assert response.status_code == 201, response.text
    return sibling, await _member_token(client, sibling)


# --- POST /w/{w}/ops ---------------------------------------------------------


async def test_post_assigns_increasing_seq_and_indexes_the_header(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    first = session.device.next_envelope(session.workspace_id)
    second = session.device.next_envelope(session.workspace_id)

    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(first, second),
        headers=session.headers,
    )
    assert response.status_code == 200, response.text
    results = response.json()["results"]
    assert [r["duplicate"] for r in results] == [False, False]
    assert results[0]["seq"] < results[1]["seq"]

    stored = await content_ops(db)
    assert [op.envelope for op in stored] == [first, second]
    # Index columns come from the envelope, never from the request.
    for op, envelope in zip(stored, (first, second), strict=True):
        header = OpHeader.parse(envelope)
        assert op.workspace_id == header.workspace_id == session.workspace_id
        assert op.op_id == header.op_id
        assert op.op_class == header.op_class
        assert op.key_epoch == header.key_epoch
        assert op.author_member_id == header.author_member_id
        assert op.author_key_id == header.author_key_id
        assert op.author_seq == header.author_seq
        assert op.compacted_by is None


async def test_replaying_the_exact_batch_is_all_duplicates_and_appends_nothing(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    batch = encode_all(
        session.device.next_envelope(session.workspace_id),
        session.device.next_envelope(session.workspace_id),
    )
    first = await client.post(f"/w/{session.workspace_id}/ops", json=batch, headers=session.headers)
    assert first.status_code == 200, first.text

    replay = await client.post(
        f"/w/{session.workspace_id}/ops", json=batch, headers=session.headers
    )
    assert replay.status_code == 200, replay.text
    assert [r["duplicate"] for r in replay.json()["results"]] == [True, True]
    # Same seqs, and no new rows: replay is a no-op, not a re-append.
    assert replay.json()["results"] == [{**r, "duplicate": True} for r in first.json()["results"]]
    assert len(await content_ops(db)) == 2


async def test_partially_duplicate_batch_appends_only_the_new_ops(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    already_sent = session.device.next_envelope(session.workspace_id)
    await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(already_sent),
        headers=session.headers,
    )

    fresh = session.device.next_envelope(session.workspace_id)
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(already_sent, fresh),
        headers=session.headers,
    )
    assert response.status_code == 200, response.text
    assert [r["duplicate"] for r in response.json()["results"]] == [True, False]
    assert len(await content_ops(db)) == 2


async def test_a_repeat_inside_one_batch_is_a_duplicate_of_its_first_appearance(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    envelope = session.device.next_envelope(session.workspace_id)
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(envelope, envelope),
        headers=session.headers,
    )
    assert response.status_code == 200, response.text
    results = response.json()["results"]
    assert [r["duplicate"] for r in results] == [False, True]
    assert results[0]["seq"] == results[1]["seq"]
    assert len(await content_ops(db)) == 1


async def test_author_seq_gap_rejects_the_whole_batch(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """The gap 409, and the fields a single-writer client's verdict turns on.

    ``expected_author_seq`` is what lets a client tell "the server is behind us"
    from "the server is ahead of us" from "no verdict at all", so it is asserted
    here rather than left to the prose.
    """
    session.device.next_envelope(session.workspace_id)  # burn one chain slot
    valid_after_the_gap = session.device.next_envelope(session.workspace_id)

    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(valid_after_the_gap),
        headers=session.headers,
    )
    assert response.status_code == 409, response.text
    assert response.json()["detail"] == {
        "code": "author_chain_conflict",
        "index": 0,
        "author_seq": FIRST_CONTENT_AUTHOR_SEQ + 1,
        "expected_author_seq": FIRST_CONTENT_AUTHOR_SEQ,
    }
    assert await content_ops(db) == []


async def test_two_ops_claiming_the_same_author_seq_land_exactly_once(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """One slot of an author's chain holds one op — the invariant behind
    ``uq_ops_workspace_author_seq``.

    Both envelopes are validly signed and differ only in op id, so nothing but
    the chain rule separates them.  Sequentially the gap check refuses the
    second; concurrently the database does (see
    ``test_ops_author_chain_race_postgres.py``).  Either way it is a status, not
    a crash, and the log keeps one op.
    """
    first = session.device.next_envelope(session.workspace_id, advance=False)
    second = session.device.next_envelope(session.workspace_id, advance=False)
    assert first != second

    accepted = await client.post(
        f"/w/{session.workspace_id}/ops", json=encode_all(first), headers=session.headers
    )
    assert accepted.status_code == 200, accepted.text

    refused = await client.post(
        f"/w/{session.workspace_id}/ops", json=encode_all(second), headers=session.headers
    )
    assert refused.status_code == 409, refused.text
    assert refused.json()["detail"]["code"] == "author_chain_conflict"

    stored = await content_ops(db)
    assert [op.envelope for op in stored] == [first]


async def test_header_workspace_mismatch_is_rejected(client: AsyncClient, session: Session) -> None:
    foreign = session.device.next_envelope(default_workspace_id("someone-else"))
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(foreign),
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "workspace_mismatch", "index": 0}


async def test_unserved_suite_is_rejected(client: AsyncClient, session: Session) -> None:
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(session.device.next_envelope(session.workspace_id, suite=0x7F)),
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "unsupported_suite", "index": 0}


@pytest.mark.parametrize("op_class", [9, OP_CLASS_COMPACTION])
async def test_unserved_op_class_is_rejected(
    client: AsyncClient, session: Session, op_class: int
) -> None:
    """Unknown (9) and known-but-unimplemented (4) fail closed identically."""
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(session.device.next_envelope(session.workspace_id, op_class=op_class)),
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "unsupported_op_class", "index": 0}


async def test_truncated_envelope_is_rejected(client: AsyncClient, session: Session) -> None:
    envelope = session.device.next_envelope(session.workspace_id)
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json={"ops": [encode(envelope[:100])]},
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "truncated_envelope", "index": 0}


async def test_envelope_shorter_than_the_minimum_is_rejected(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """Past the header, but shorter than the smallest body class allows.

    Bodies are padded to 256 bytes at minimum, so anything under
    ``MINIMUM_ENVELOPE_BYTES`` could never have been framed legally.  The server
    refuses it without reading a body byte rather than storing bytes every
    puller would then have to quarantine.
    """
    too_short = session.device.next_envelope(session.workspace_id)[: MINIMUM_ENVELOPE_BYTES - 1]
    # Long enough to parse as a header: this is not the truncated-header case.
    assert len(too_short) > HEADER_LENGTH_BYTES

    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json={"ops": [encode(too_short)]},
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "envelope_too_short", "index": 0}
    assert await content_ops(db) == []


async def test_foreign_author_is_rejected(client: AsyncClient, session: Session) -> None:
    """A member registered to another user cannot author into this workspace."""
    other = await _open_session(client, "ops-stranger@example.com")
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(other.device.next_envelope(session.workspace_id)),
        headers=session.headers,
    )
    assert response.status_code == 403, response.text
    assert detail_of(response) == {"code": "author_member_mismatch", "index": 0}


async def test_unregistered_author_is_rejected(client: AsyncClient, session: Session) -> None:
    stranger = SpecDevice()
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(stranger.next_envelope(session.workspace_id)),
        headers=session.headers,
    )
    assert response.status_code == 403, response.text
    assert detail_of(response) == {"code": "author_member_mismatch", "index": 0}


async def test_a_member_token_cannot_post_as_another_member_of_the_same_user(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """F10, the case a user credential used to permit.

    Both devices belong to the same User, so the old "author is a member of this
    user" check would have waved this through.  A member token speaks for
    exactly one member.
    """
    sibling = SpecDevice()
    registered = await client.post(
        "/members", json=sibling.registration_body(), headers=session.user_headers
    )
    assert registered.status_code == 201, registered.text

    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(sibling.next_envelope(session.workspace_id)),
        headers=session.headers,
    )
    assert response.status_code == 403, response.text
    assert detail_of(response) == {"code": "author_member_mismatch", "index": 0}
    assert await content_ops(db) == []


async def test_a_user_credential_cannot_post_ops(client: AsyncClient, session: Session) -> None:
    """AC3: a stolen *user* credential cannot post ops as an existing member."""
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(session.device.next_envelope(session.workspace_id)),
        headers=session.user_headers,
    )
    assert response.status_code == 401, response.text


async def test_a_member_token_is_not_a_user_session(client: AsyncClient, session: Session) -> None:
    """The guard in the other direction: a member token is not a login."""
    assert (await client.get("/user", headers=session.headers)).status_code == 401
    registration = await client.post(
        "/members", json=SpecDevice().registration_body(), headers=session.headers
    )
    assert registration.status_code == 401, registration.text


async def test_another_users_workspace_is_rejected(client: AsyncClient, session: Session) -> None:
    other = await _open_session(client, "ops-neighbour@example.com")
    response = await client.post(
        f"/w/{other.workspace_id}/ops",
        json=encode_all(session.device.next_envelope(other.workspace_id)),
        headers=session.headers,
    )
    assert response.status_code == 403, response.text

    pull = await client.get(f"/w/{other.workspace_id}/ops", headers=session.headers)
    assert pull.status_code == 403, pull.text


async def test_ops_require_authentication(client: AsyncClient, session: Session) -> None:
    assert (await client.get(f"/w/{session.workspace_id}/ops")).status_code == 401


# --- GET /w/{w}/ops ----------------------------------------------------------


async def test_pull_pages_by_seq_and_reports_has_more(
    client: AsyncClient, session: Session
) -> None:
    envelopes = [session.device.next_envelope(session.workspace_id) for _ in range(5)]
    await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(*envelopes),
        headers=session.headers,
    )

    # Past the founding ceremony's control ops: paging is what is under test, and
    # the genesis and self-grant are not part of the page arithmetic.
    first_page = (
        await client.get(
            f"/w/{session.workspace_id}/ops",
            params={"since": session.founded_through_seq, "limit": 2},
            headers=session.headers,
        )
    ).json()
    assert first_page["has_more"] is True
    assert [base64.b64decode(op["envelope"]) for op in first_page["ops"]] == envelopes[:2]

    cursor = first_page["ops"][-1]["seq"]
    rest = (
        await client.get(
            f"/w/{session.workspace_id}/ops",
            params={"since": cursor, "limit": 10},
            headers=session.headers,
        )
    ).json()
    assert rest["has_more"] is False
    assert [base64.b64decode(op["envelope"]) for op in rest["ops"]] == envelopes[2:]


async def test_pull_excludes_compacted_rows(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    envelopes = [session.device.next_envelope(session.workspace_id) for _ in range(2)]
    await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(*envelopes),
        headers=session.headers,
    )

    # #555's prune op will set this; v1 prunes are soft deletes, so the row
    # stays and only the default pull hides it.
    stored = await content_ops(db)
    stored[0].compacted_by = stored[1].seq
    await db.commit()

    pulled = (
        await client.get(
            f"/w/{session.workspace_id}/ops",
            params={"since": session.founded_through_seq},
            headers=session.headers,
        )
    ).json()
    assert [base64.b64decode(op["envelope"]) for op in pulled["ops"]] == [envelopes[1]]


async def test_empty_batch_is_accepted_and_appends_nothing(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    response = await client.post(
        f"/w/{session.workspace_id}/ops", json={"ops": []}, headers=session.headers
    )
    assert response.status_code == 200, response.text
    assert response.json() == {"results": []}
    assert await content_ops(db) == []


# --- op_class=2: MemberRegister ----------------------------------------------


def _control_envelope_with_body(device: SpecDevice, workspace_id: uuid.UUID, body: bytes) -> bytes:
    """A signed op_class=2 envelope carrying a body the framing rules refuse.

    Built by hand because ``frame_body`` cannot produce an illegal frame, and
    signed over the bad body so nothing but the framing rule can fire.
    """
    header = OpHeader(
        suite=0,
        op_class=OP_CLASS_CONTROL,
        workspace_id=workspace_id,
        key_epoch=0,
        op_id=uuid.uuid4(),
        author_member_id=device.member_id,
        author_key_id=device.key_id,
        author_seq=1,
    )
    return build_envelope(header, body, device.signing_key)


async def test_a_root_signed_member_register_materialises_the_membership(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """A sibling Device joining a founded Workspace.

    The *founder* has no separate register — the genesis embedded it (ADR-0031) —
    so this is the shape every Nth device's registration takes: a
    ``member_register`` naming the observed control head as its ``prev``.
    """
    sibling, sibling_token = await _join_sibling(client, session)
    envelope = session.root.member_register_envelope(
        sibling, session.workspace_id, prev_control_hash=session.control_head
    )
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(envelope),
        headers=auth_header(sibling_token),
    )
    assert response.status_code == 200, response.text

    stored = await all_ops(db)
    assert stored[-1].envelope == envelope
    assert stored[-1].op_class == OP_CLASS_CONTROL
    member = await db.get(Member, sibling.member_id)
    assert member is not None and member.chained_at is not None
    # The kind is materialised from the certificate, never claimed by the shell
    # row ``POST /members`` created.
    assert member.member_kind == MEMBER_KIND_DEVICE


async def test_a_member_register_with_a_zero_chain_link_is_rejected(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """An all-zero ``prev_control_hash`` is **genesis-only** (ADR-0031).

    Refused even by a receiver whose control state is empty, which is what makes
    a truncated history always detectable: the alternative — treating a zero link
    as "fresh chain" — is exactly the claim a server serving a truncated log
    makes.
    """
    sibling, sibling_token = await _join_sibling(client, session)
    envelope = session.root.member_register_envelope(
        sibling, session.workspace_id, prev_control_hash=ZERO_PREV_CONTROL_HASH
    )
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(envelope),
        headers=auth_header(sibling_token),
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "control_chain_break", "index": 0}
    member = await db.get(Member, sibling.member_id)
    assert member is not None and member.chained_at is None


async def test_the_control_chain_link_is_the_predecessors_payload_hash(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """The link is over the *payload bytes*, not the envelope.

    Recomputing it from what the log serves back is the whole point: a client
    that pulls the log can follow the chain without re-framing anything.
    """
    before = len(await all_ops(db))
    first_sibling, first_token = await _join_sibling(client, session)
    first = session.root.member_register_envelope(
        first_sibling, session.workspace_id, prev_control_hash=session.control_head
    )
    accepted = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(first),
        headers=auth_header(first_token),
    )
    assert accepted.status_code == 200, accepted.text

    second_sibling, second_token = await _join_sibling(client, session)
    _header, body, _signature = split_envelope(first)
    chained = session.root.member_register_envelope(
        second_sibling,
        session.workspace_id,
        prev_control_hash=control_payload_hash(parse_body(body)),
    )
    payload = ControlPayload.decode(parse_body(split_envelope(chained)[1]))
    assert payload.prev_control_hash == control_payload_hash(parse_body(body))
    assert payload.prev_control_hash != ZERO_PREV_CONTROL_HASH

    accepted = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(chained),
        headers=auth_header(second_token),
    )
    assert accepted.status_code == 200, accepted.text
    assert len(await all_ops(db)) == before + 2


async def test_a_control_op_with_a_bad_root_signature_is_rejected(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """AC3: a stolen user credential cannot register an *authoritative* member."""
    sibling, sibling_token = await _join_sibling(client, session)
    envelope = session.root.member_register_envelope(
        sibling,
        session.workspace_id,
        prev_control_hash=session.control_head,
        corrupt_signature=True,
    )
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(envelope),
        headers=auth_header(sibling_token),
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "bad_root_signature", "index": 0}
    member = await db.get(Member, sibling.member_id)
    assert member is not None and member.chained_at is None


async def test_a_control_op_signed_by_a_foreign_root_is_rejected(
    client: AsyncClient, session: Session
) -> None:
    """Only the Root in this slot's escrow can register into this Workspace."""
    sibling, sibling_token = await _join_sibling(client, session)
    envelope = SpecRoot().member_register_envelope(
        sibling, session.workspace_id, prev_control_hash=session.control_head
    )
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(envelope),
        headers=auth_header(sibling_token),
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "bad_root_signature", "index": 0}


async def test_an_unserved_control_type_is_rejected(client: AsyncClient, session: Session) -> None:
    """#554's landing slot: every control type this build does not serve is closed."""
    payload = ControlPayload(control_type="rotate", prev_control_hash=session.control_head).encode()
    envelope = session.device.next_envelope(
        session.workspace_id, op_class=OP_CLASS_CONTROL, payload=payload
    )
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(envelope),
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {
        "code": "unsupported_control_type",
        "index": 0,
        "type": "rotate",
    }


async def test_a_malformed_control_payload_is_rejected(
    client: AsyncClient, session: Session
) -> None:
    envelope = session.device.next_envelope(
        session.workspace_id, op_class=OP_CLASS_CONTROL, payload=b"not json at all"
    )
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(envelope),
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "malformed_control_payload", "index": 0}


@pytest.mark.parametrize(
    ("code", "body"),
    [
        ("invalid_body_length", bytes(300)),
        ("payload_overruns_body", (256).to_bytes(4, "big") + bytes(252)),
    ],
)
async def test_a_control_body_the_framing_refuses_is_rejected(
    client: AsyncClient, session: Session, code: str, body: bytes
) -> None:
    """``parse_body`` raising on the control path is the same fail-closed family.

    A body the framing cannot even delimit never reaches control parsing.
    """
    envelope = _control_envelope_with_body(session.device, session.workspace_id, body)
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(envelope),
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": code, "index": 0}


async def test_a_member_register_away_from_author_seq_1_is_rejected(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """The position rule, and its precedence over the chain-gap 409.

    The chain check only guarantees that an author's *first* op is seq 1; it does
    not guarantee that seq 1 is the registering control op.  A mispositioned
    register earns this 422 and never the 409, so #551's chain verdict only ever
    sees registers already at seq 1.
    """
    sibling, sibling_token = await _join_sibling(client, session)
    before = await all_ops(db)
    envelope = session.root.member_register_envelope(
        sibling, session.workspace_id, prev_control_hash=session.control_head, author_seq=4
    )
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(envelope),
        headers=auth_header(sibling_token),
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {
        "code": "member_register_not_first",
        "index": 0,
        "author_seq": 4,
    }
    assert len(await all_ops(db)) == len(before)


async def test_a_certificate_naming_another_member_is_rejected(
    client: AsyncClient, session: Session
) -> None:
    sibling, sibling_token = await _join_sibling(client, session)
    certificate = session.root.certificate(sibling, session.workspace_id, member_id=uuid.uuid4())
    envelope = session.root.member_register_envelope(
        sibling,
        session.workspace_id,
        prev_control_hash=session.control_head,
        certificate=certificate,
    )
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(envelope),
        headers=auth_header(sibling_token),
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "cert_member_mismatch", "index": 0}


async def test_a_certificate_naming_another_key_is_rejected(
    client: AsyncClient, session: Session
) -> None:
    sibling, sibling_token = await _join_sibling(client, session)
    certificate = session.root.certificate(
        sibling, session.workspace_id, sign_pk=SpecDevice().sign_pk
    )
    envelope = session.root.member_register_envelope(
        sibling,
        session.workspace_id,
        prev_control_hash=session.control_head,
        certificate=certificate,
    )
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(envelope),
        headers=auth_header(sibling_token),
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "cert_key_mismatch", "index": 0}


async def test_a_control_op_without_a_stored_root_fails_closed(
    client: AsyncClient, db: AsyncSession
) -> None:
    """No escrow means no Root the server can check against.

    Exercised through *genesis*, because that is the first control op a Workspace
    ever sees and therefore the first place the missing slot bites.  It is also
    why the ceremony's escrow PUT is strictly sequenced before its genesis post:
    posting into a slotless Workspace is unverifiable by construction.
    """
    token = await register(client, "ops-no-escrow@example.com")
    workspace_id = default_workspace_id(user_id_from_token(token))
    device = SpecDevice()
    await client.post("/members", json=device.registration_body(), headers=auth_header(token))
    member_token = await _member_token(client, device)

    envelope = SpecRoot().genesis_envelope(device, workspace_id)
    response = await client.post(
        f"/w/{workspace_id}/ops",
        json=encode_all(envelope),
        headers=auth_header(member_token),
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "bad_root_signature", "index": 0}
    assert await all_ops(db) == []


async def test_a_content_op_body_is_never_read(client: AsyncClient, session: Session) -> None:
    """Content stays opaque: only op_class=2 opens the body.

    The same bytes that are a malformed control payload are an unremarkable
    content op, because nothing server-side looks at them.
    """
    envelope = session.device.next_envelope(session.workspace_id, payload=b"not json at all")
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(envelope),
        headers=session.headers,
    )
    assert response.status_code == 200, response.text


async def test_a_control_op_body_frames_like_any_other(session: Session) -> None:
    """The control payload rides in the ordinary body frame, padded as usual."""
    envelope = session.root.member_register_envelope(session.device, session.workspace_id)
    _header, body, _signature = split_envelope(envelope)
    payload = ControlPayload.decode(parse_body(body))
    assert payload.control_type == CONTROL_TYPE_MEMBER_REGISTER
    assert body == frame_body(parse_body(body))


# --- POST /members -----------------------------------------------------------


async def test_member_registration_derives_the_key_id(client: AsyncClient) -> None:
    token = await register(client, "members-derive@example.com")
    device = SpecDevice()
    response = await client.post(
        "/members", json=device.registration_body(), headers=auth_header(token)
    )
    assert response.status_code == 201, response.text
    body = response.json()
    assert base64.b64decode(body["key_id"]) == derive_key_id(device.sign_pk)
    assert base64.b64decode(body["sign_pk"]) == device.sign_pk


async def test_member_registration_rejects_a_mismatched_key_id_claim(
    client: AsyncClient,
) -> None:
    token = await register(client, "members-claim@example.com")
    device = SpecDevice()
    response = await client.post(
        "/members",
        json={**device.registration_body(), "key_id": base64.b64encode(b"\x00" * 8).decode()},
        headers=auth_header(token),
    )
    assert response.status_code == 422, response.text


async def test_member_registration_accepts_a_matching_key_id_claim(
    client: AsyncClient,
) -> None:
    token = await register(client, "members-matching@example.com")
    device = SpecDevice()
    response = await client.post(
        "/members",
        json={
            **device.registration_body(),
            "key_id": base64.b64encode(device.key_id).decode(),
        },
        headers=auth_header(token),
    )
    assert response.status_code == 201, response.text


async def test_re_registering_the_same_member_is_idempotent(
    client: AsyncClient,
) -> None:
    token = await register(client, "members-idempotent@example.com")
    device = SpecDevice()
    body = device.registration_body()
    assert (await client.post("/members", json=body, headers=auth_header(token))).status_code == 201
    repeat = await client.post("/members", json=body, headers=auth_header(token))
    assert repeat.status_code == 200, repeat.text


async def test_re_registering_a_member_id_under_a_different_key_conflicts(
    client: AsyncClient,
) -> None:
    token = await register(client, "members-conflict@example.com")
    device = SpecDevice()
    await client.post("/members", json=device.registration_body(), headers=auth_header(token))
    impostor = SpecDevice(member_id=device.member_id)
    response = await client.post(
        "/members", json=impostor.registration_body(), headers=auth_header(token)
    )
    assert response.status_code == 409, response.text


async def test_workspace_member_registry_lists_the_users_devices(
    client: AsyncClient, session: Session
) -> None:
    response = await client.get(f"/w/{session.workspace_id}/members", headers=session.headers)
    assert response.status_code == 200, response.text
    members = response.json()["members"]
    assert [m["member_id"] for m in members] == [str(session.device.member_id)]
    assert base64.b64decode(members[0]["key_id"]) == session.device.key_id
