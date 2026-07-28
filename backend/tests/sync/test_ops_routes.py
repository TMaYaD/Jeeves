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

from app.sync.envelope import (
    HEADER_LENGTH_BYTES,
    MINIMUM_ENVELOPE_BYTES,
    OP_CLASS_COMPACTION,
    OpHeader,
    derive_key_id,
)
from app.sync.ids import implicit_workspace_id
from app.sync.models import Op
from tests.conftest import auth_header, register
from tests.sync.builders import SpecDevice, encode, encode_all, user_id_from_token


class Session:
    """One authenticated user with one registered device."""

    def __init__(self, token: str, workspace_id: uuid.UUID, device: SpecDevice) -> None:
        self.token = token
        self.workspace_id = workspace_id
        self.device = device

    @property
    def headers(self) -> dict[str, str]:
        return auth_header(self.token)


async def _open_session(client: AsyncClient, email: str) -> Session:
    token = await register(client, email)
    device = SpecDevice()
    response = await client.post(
        "/members", json=device.registration_body(), headers=auth_header(token)
    )
    assert response.status_code == 201, response.text
    return Session(token, implicit_workspace_id(user_id_from_token(token)), device)


@pytest_asyncio.fixture
async def session(client: AsyncClient) -> Session:
    return await _open_session(client, "ops-owner@example.com")


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

    stored = (await db.execute(select(Op).order_by(Op.seq))).scalars().all()
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
    assert len((await db.execute(select(Op))).scalars().all()) == 2


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
    assert len((await db.execute(select(Op))).scalars().all()) == 2


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
    assert len((await db.execute(select(Op))).scalars().all()) == 1


async def test_author_seq_gap_rejects_the_whole_batch(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    session.device.next_envelope(session.workspace_id)  # burn author_seq 1
    valid_after_the_gap = session.device.next_envelope(session.workspace_id)

    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(valid_after_the_gap),
        headers=session.headers,
    )
    assert response.status_code == 409, response.text
    assert (await db.execute(select(Op))).scalars().all() == []


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

    stored = (await db.execute(select(Op))).scalars().all()
    assert [op.envelope for op in stored] == [first]


async def test_header_workspace_mismatch_is_rejected(client: AsyncClient, session: Session) -> None:
    foreign = session.device.next_envelope(implicit_workspace_id("someone-else"))
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(foreign),
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert "workspace_mismatch" in response.json()["detail"]


async def test_unserved_suite_is_rejected(client: AsyncClient, session: Session) -> None:
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(session.device.next_envelope(session.workspace_id, suite=0x7F)),
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert "unsupported_suite" in response.json()["detail"]


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
    assert "unsupported_op_class" in response.json()["detail"]


async def test_truncated_envelope_is_rejected(client: AsyncClient, session: Session) -> None:
    envelope = session.device.next_envelope(session.workspace_id)
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json={"ops": [encode(envelope[:100])]},
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert "truncated_envelope" in response.json()["detail"]


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
    assert "envelope_too_short" in response.json()["detail"]
    assert (await db.execute(select(Op))).scalars().all() == []


async def test_foreign_author_is_rejected(client: AsyncClient, session: Session) -> None:
    """A member registered to another user cannot author into this workspace."""
    other = await _open_session(client, "ops-stranger@example.com")
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(other.device.next_envelope(session.workspace_id)),
        headers=session.headers,
    )
    assert response.status_code == 403, response.text


async def test_unregistered_author_is_rejected(client: AsyncClient, session: Session) -> None:
    stranger = SpecDevice()
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(stranger.next_envelope(session.workspace_id)),
        headers=session.headers,
    )
    assert response.status_code == 403, response.text


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

    first_page = (
        await client.get(
            f"/w/{session.workspace_id}/ops",
            params={"since": 0, "limit": 2},
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
    stored = (await db.execute(select(Op).order_by(Op.seq))).scalars().all()
    stored[0].compacted_by = stored[1].seq
    await db.commit()

    pulled = (await client.get(f"/w/{session.workspace_id}/ops", headers=session.headers)).json()
    assert [base64.b64decode(op["envelope"]) for op in pulled["ops"]] == [envelopes[1]]


async def test_empty_batch_is_accepted_and_appends_nothing(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    response = await client.post(
        f"/w/{session.workspace_id}/ops", json={"ops": []}, headers=session.headers
    )
    assert response.status_code == 200, response.text
    assert response.json() == {"results": []}
    assert (await db.execute(select(Op))).scalars().all() == []


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
