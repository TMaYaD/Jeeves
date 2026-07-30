"""The compaction and prune routes — op classes 4 and 5 (#555).

``app/test/sync/compaction_test.dart`` drives the same rules end to end through
the harness; this file is the route contract: who may author a class-4 or
class-5 op, every named refusal a prune's target enumeration can earn, and the
soft-delete materialisation that ``compacted_by`` stands for.

**Nothing here deletes anything.**  A v1 prune stamps ``ops.compacted_by`` and
the row stays: the default pull hides it, ``include_compacted=true`` serves it,
and the envelope bytes are untouched for ever.  Soft-to-hard is an easy later
shift; the reverse is impossible.
"""

from __future__ import annotations

import base64
import uuid

import pytest
import pytest_asyncio
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.sync.control_payload import ROLE_COMPACTOR, ROLE_PARTICIPANT
from app.sync.envelope import (
    OP_CLASS_COMPACTION,
    OP_CLASS_CONTENT,
    OP_CLASS_PRUNE,
    envelope_hash,
)
from app.sync.models import Op
from app.sync.prune_payload import MAX_PRUNE_TARGETS, PrunePayload, PruneTarget
from tests.sync.builders import (
    Session,
    SpecDevice,
    encode_all,
    member_token,
    open_session,
)
from tests.sync.helpers import detail_of


@pytest_asyncio.fixture
async def session(client: AsyncClient) -> Session:
    return await open_session(client, "compaction-owner@example.com")


async def _post(
    client: AsyncClient,
    session: Session,
    *envelopes: bytes,
    headers: dict[str, str] | None = None,
) -> object:
    return await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(*envelopes),
        headers=headers or session.headers,
    )


async def _stored(db: AsyncSession) -> list[Op]:
    rows = await db.execute(select(Op).order_by(Op.seq))
    return list(rows.scalars().all())


async def _append_content(
    client: AsyncClient, session: Session, count: int
) -> list[tuple[bytes, int]]:
    """``count`` content ops, appended and paired with the seqs they were given."""
    envelopes = [session.device.next_envelope(session.workspace_id) for _ in range(count)]
    response = await _post(client, session, *envelopes)
    assert response.status_code == 200, response.text
    results = response.json()["results"]
    return [(envelope, result["seq"]) for envelope, result in zip(envelopes, results, strict=True)]


def _target(envelope: bytes, seq: int, device: SpecDevice, author_seq: int) -> PruneTarget:
    return PruneTarget(
        seq=seq,
        author_member_id=device.member_id,
        author_seq=author_seq,
        envelope_hash=envelope_hash(envelope),
    )


def _compaction(session: Session, *, op_id: uuid.UUID | None = None) -> tuple[bytes, uuid.UUID]:
    """A class-4 envelope, and the ``op_id`` a prune must name it by.

    The body is deliberately uninteresting: the server never reads a class-4 body
    — under ``aead_v1`` it is ciphertext — so the *route* contract is the header,
    the role and the batch position.  The payload shape rules are pinned by the
    codecs and the golden vectors.
    """
    resolved = op_id or uuid.uuid4()
    return (
        session.device.next_envelope(
            session.workspace_id,
            op_class=OP_CLASS_COMPACTION,
            op_id=resolved,
            payload=b'{"collection":"harness_docs"}',
        ),
        resolved,
    )


def _prune(
    session: Session,
    *,
    compaction_op_id: uuid.UUID,
    targets: list[PruneTarget],
    op_id: uuid.UUID | None = None,
    author_seq: int | None = None,
    advance: bool = True,
) -> bytes:
    return session.device.next_envelope(
        session.workspace_id,
        op_class=OP_CLASS_PRUNE,
        op_id=op_id,
        payload=PrunePayload(
            compaction_op_id=compaction_op_id, targets=tuple(targets)
        ).encode(),
        author_seq=author_seq,
        advance=advance,
    )


async def _sibling_with_role(
    client: AsyncClient, session: Session, role: str
) -> tuple[SpecDevice, dict[str, str]]:
    """A second Device, chained and granted exactly ``role``.

    Register-plus-grant in one batch, the shape the enrolment ceremony posts, so
    the role under test is the only thing that differs between these cases.
    """
    sibling = SpecDevice()
    registered = await client.post(
        "/members", json=sibling.registration_body(), headers=session.user_headers
    )
    assert registered.status_code == 201, registered.text
    token = await member_token(client, sibling)
    headers = {"Authorization": f"Bearer {token}"}

    register = session.advance_control_head(
        session.root.member_register_envelope(sibling, session.workspace_id)
    )
    grant = session.advance_control_head(
        session.root.grant_envelope(
            sibling,
            session.workspace_id,
            certificate=session.root.grant_certificate(
                session.workspace_id, member_id=sibling.member_id, role=role
            ),
            prev_control_hash=session.control_head,
        )
    )
    response = await _post(client, session, register, grant, headers=headers)
    assert response.status_code == 200, response.text
    return sibling, headers


# ── Class 4: who may compact ──────────────────────────────────────────────────


async def test_an_owner_may_author_a_compaction_op(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    envelope, _ = _compaction(session)
    response = await _post(client, session, envelope)
    assert response.status_code == 200, response.text
    stored = [op for op in await _stored(db) if op.op_class == OP_CLASS_COMPACTION]
    assert [op.envelope for op in stored] == [envelope]
    assert stored[0].compacted_by is None


async def test_a_compactor_may_author_a_compaction_and_a_prune(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """The role exists for exactly this, and the matrix has admitted it since #549."""
    appended = await _append_content(client, session, 2)
    compactor, headers = await _sibling_with_role(client, session, ROLE_COMPACTOR)

    compaction = compactor.next_envelope(
        session.workspace_id,
        op_class=OP_CLASS_COMPACTION,
        payload=b'{"collection":"harness_docs"}',
    )
    compaction_op_id = uuid.UUID(bytes=compaction[22:38])
    prune = compactor.next_envelope(
        session.workspace_id,
        op_class=OP_CLASS_PRUNE,
        payload=PrunePayload(
            compaction_op_id=compaction_op_id,
            targets=(
                _target(appended[0][0], appended[0][1], session.device, 3),
            ),
        ).encode(),
    )
    response = await _post(client, session, compaction, prune, headers=headers)
    assert response.status_code == 200, response.text
    prune_seq = response.json()["results"][1]["seq"]
    stored = {op.seq: op for op in await _stored(db)}
    assert stored[appended[0][1]].compacted_by == prune_seq


@pytest.mark.parametrize("op_class", [OP_CLASS_COMPACTION, OP_CLASS_PRUNE])
async def test_a_participant_may_not_author_compaction_or_prune(
    client: AsyncClient, session: Session, op_class: int
) -> None:
    participant, headers = await _sibling_with_role(client, session, ROLE_PARTICIPANT)
    envelope = participant.next_envelope(
        session.workspace_id,
        op_class=op_class,
        payload=(
            PrunePayload(compaction_op_id=uuid.uuid4(), targets=()).encode()
            if op_class == OP_CLASS_PRUNE
            else b'{"collection":"harness_docs"}'
        ),
    )
    response = await _post(client, session, envelope, headers=headers)
    assert response.status_code == 403, response.text
    detail = detail_of(response)
    assert detail["code"] == "role_forbids_op_class"
    assert detail["op_class"] == op_class
    assert detail["index"] == 0


# ── Class 5: the target enumeration, one named refusal per rule ────────────────


async def test_a_prune_stamps_compacted_by_and_deletes_nothing(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    appended = await _append_content(client, session, 3)
    before = len(await _stored(db))
    compaction, compaction_op_id = _compaction(session)
    prune = _prune(
        session,
        compaction_op_id=compaction_op_id,
        targets=[
            _target(appended[0][0], appended[0][1], session.device, 3),
            _target(appended[1][0], appended[1][1], session.device, 4),
        ],
    )
    response = await _post(client, session, compaction, prune)
    assert response.status_code == 200, response.text
    prune_seq = response.json()["results"][1]["seq"]

    stored = {op.seq: op for op in await _stored(db)}
    # Two more rows than before, never fewer: a prune is an append plus a stamp.
    assert len(stored) == before + 2
    assert stored[appended[0][1]].compacted_by == prune_seq
    assert stored[appended[1][1]].compacted_by == prune_seq
    assert stored[appended[2][1]].compacted_by is None
    # The envelope bytes are evidence and are never touched.
    assert stored[appended[0][1]].envelope == appended[0][0]


async def test_a_prune_naming_a_seq_the_workspace_does_not_hold_is_refused(
    client: AsyncClient, session: Session
) -> None:
    compaction, compaction_op_id = _compaction(session)
    prune = _prune(
        session,
        compaction_op_id=compaction_op_id,
        targets=[
            PruneTarget(
                seq=9_999_999,
                author_member_id=session.device.member_id,
                author_seq=3,
                envelope_hash=bytes(32),
            )
        ],
    )
    response = await _post(client, session, compaction, prune)
    assert response.status_code == 422, response.text
    assert detail_of(response) == {
        "code": "prune_target_not_found",
        "index": 1,
        "seq": 9_999_999,
    }


async def test_a_prune_naming_a_control_op_is_refused(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """Compacting a control op away would delete the evidence a Grant existed."""
    genesis = (await _stored(db))[0]
    compaction, compaction_op_id = _compaction(session)
    prune = _prune(
        session,
        compaction_op_id=compaction_op_id,
        targets=[
            PruneTarget(
                seq=genesis.seq,
                author_member_id=genesis.author_member_id,
                author_seq=genesis.author_seq,
                envelope_hash=envelope_hash(genesis.envelope),
            )
        ],
    )
    response = await _post(client, session, compaction, prune)
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == "prune_target_is_control"


async def test_a_prune_naming_another_prune_is_refused(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """A prune *is* the attestation that history was removed.

    Pruning one would destroy the only thing that distinguishes garbage
    collection from a server that truncated the log.
    """
    appended = await _append_content(client, session, 1)
    first_compaction, first_op_id = _compaction(session)
    first_prune = _prune(
        session,
        compaction_op_id=first_op_id,
        targets=[_target(appended[0][0], appended[0][1], session.device, 3)],
    )
    first = await _post(client, session, first_compaction, first_prune)
    assert first.status_code == 200, first.text
    first_prune_seq = first.json()["results"][1]["seq"]

    second_compaction, second_op_id = _compaction(session)
    second_prune = _prune(
        session,
        compaction_op_id=second_op_id,
        targets=[
            PruneTarget(
                seq=first_prune_seq,
                author_member_id=session.device.member_id,
                author_seq=5,
                envelope_hash=envelope_hash(first_prune),
            )
        ],
    )
    response = await _post(client, session, second_compaction, second_prune)
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == "prune_target_is_prune"


async def test_a_prune_may_target_an_earlier_compaction_op(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """Class 4 is a legal target: the next compaction supersedes the previous one."""
    first_compaction, first_op_id = _compaction(session)
    first = await _post(client, session, first_compaction)
    assert first.status_code == 200, first.text
    first_seq = first.json()["results"][0]["seq"]

    second_compaction, second_op_id = _compaction(session)
    second_prune = _prune(
        session,
        compaction_op_id=second_op_id,
        targets=[
            PruneTarget(
                seq=first_seq,
                author_member_id=session.device.member_id,
                author_seq=3,
                envelope_hash=envelope_hash(first_compaction),
            )
        ],
    )
    response = await _post(client, session, second_compaction, second_prune)
    assert response.status_code == 200, response.text
    prune_seq = response.json()["results"][1]["seq"]
    stored = {op.seq: op for op in await _stored(db)}
    assert stored[first_seq].compacted_by == prune_seq
    del first_op_id


@pytest.mark.parametrize("field", ["author_seq", "envelope_hash", "author_member_id"])
async def test_a_forged_prune_attestation_is_refused_at_the_door(
    client: AsyncClient, session: Session, field: str
) -> None:
    """The server holds the envelopes, so it can check every attested field.

    A forged attestation would poison the chain verification of every fresh
    device that trusts the prune, so it is refused before it is stored rather
    than left for the clients to disagree about.
    """
    appended = await _append_content(client, session, 1)
    honest = _target(appended[0][0], appended[0][1], session.device, 3)
    forged = PruneTarget(
        seq=honest.seq,
        author_member_id=uuid.uuid4() if field == "author_member_id" else honest.author_member_id,
        author_seq=99 if field == "author_seq" else honest.author_seq,
        envelope_hash=bytes(32) if field == "envelope_hash" else honest.envelope_hash,
    )
    compaction, compaction_op_id = _compaction(session)
    prune = _prune(session, compaction_op_id=compaction_op_id, targets=[forged])
    response = await _post(client, session, compaction, prune)
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == "prune_target_attestation_mismatch"


async def test_a_second_prune_of_an_already_compacted_target_is_refused(
    client: AsyncClient, session: Session
) -> None:
    """The stamp is written once and never moved, exactly like ``revoked_by_seq``.

    This is also the deterministic answer a *concurrent* prune gets: the losing
    transaction rolls back and re-resolves against committed state, which is this
    sequential refusal — and it is a different code from the duplicate-target
    shape error, so the two can never be confused.
    """
    appended = await _append_content(client, session, 1)
    target = _target(appended[0][0], appended[0][1], session.device, 3)

    first_compaction, first_op_id = _compaction(session)
    first = await _post(
        client,
        session,
        first_compaction,
        _prune(session, compaction_op_id=first_op_id, targets=[target]),
    )
    assert first.status_code == 200, first.text

    second_compaction, second_op_id = _compaction(session)
    response = await _post(
        client,
        session,
        second_compaction,
        _prune(session, compaction_op_id=second_op_id, targets=[target]),
    )
    assert response.status_code == 422, response.text
    detail = detail_of(response)
    assert detail["code"] == "prune_target_already_compacted"
    assert detail["code"] != "prune_duplicate_target"


async def test_a_prune_whose_compaction_is_neither_stored_nor_staged_is_refused(
    client: AsyncClient, session: Session
) -> None:
    appended = await _append_content(client, session, 1)
    prune = _prune(
        session,
        compaction_op_id=uuid.uuid4(),
        targets=[_target(appended[0][0], appended[0][1], session.device, 3)],
    )
    response = await _post(client, session, prune)
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == "prune_compaction_not_found"


async def test_a_prune_before_its_compaction_in_one_batch_is_refused(
    client: AsyncClient, session: Session
) -> None:
    """The walk is ordered, so a prune at index 0 sees nothing staged.

    Named rather than tolerated: presenting the pair backwards is a client
    authoring bug, and the outbox flusher uploads in ``author_seq`` order
    precisely so it cannot happen.
    """
    appended = await _append_content(client, session, 1)
    compaction, compaction_op_id = _compaction(session)
    # The prune takes the *later* chain slot but the earlier batch index, which is
    # exactly the shape a client that authored them out of order would produce.
    prune = _prune(
        session,
        compaction_op_id=compaction_op_id,
        targets=[_target(appended[0][0], appended[0][1], session.device, 3)],
    )
    response = await _post(client, session, prune, compaction)
    assert response.status_code in (409, 422), response.text
    assert detail_of(response)["code"] in {
        "prune_compaction_not_found",
        "author_chain_conflict",
    }


async def test_a_compaction_and_its_prune_split_across_batches_is_accepted(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """The stored arm of the staged-or-stored rule.

    The flusher chunks at ``MAX_OPS_PER_BATCH``, so the pair legitimately arrives
    in two POSTs — and by the time the prune is judged the compaction is stored.
    """
    appended = await _append_content(client, session, 1)
    compaction, compaction_op_id = _compaction(session)
    first = await _post(client, session, compaction)
    assert first.status_code == 200, first.text

    prune = _prune(
        session,
        compaction_op_id=compaction_op_id,
        targets=[_target(appended[0][0], appended[0][1], session.device, 3)],
    )
    second = await _post(client, session, prune)
    assert second.status_code == 200, second.text
    prune_seq = second.json()["results"][0]["seq"]
    stored = {op.seq: op for op in await _stored(db)}
    assert stored[appended[0][1]].compacted_by == prune_seq


async def test_a_prune_naming_a_compaction_by_another_author_is_refused(
    client: AsyncClient, session: Session
) -> None:
    """A prune vouches for *its own* compaction, never somebody else's."""
    appended = await _append_content(client, session, 1)
    compactor, headers = await _sibling_with_role(client, session, ROLE_COMPACTOR)
    foreign = compactor.next_envelope(
        session.workspace_id,
        op_class=OP_CLASS_COMPACTION,
        payload=b'{"collection":"harness_docs"}',
    )
    posted = await _post(client, session, foreign, headers=headers)
    assert posted.status_code == 200, posted.text

    prune = _prune(
        session,
        compaction_op_id=uuid.UUID(bytes=foreign[22:38]),
        targets=[_target(appended[0][0], appended[0][1], session.device, 3)],
    )
    response = await _post(client, session, prune)
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == "prune_compaction_not_found"


async def test_a_prune_naming_a_content_op_as_its_compaction_is_refused(
    client: AsyncClient, session: Session
) -> None:
    appended = await _append_content(client, session, 2)
    prune = _prune(
        session,
        compaction_op_id=uuid.UUID(bytes=appended[0][0][22:38]),
        targets=[_target(appended[1][0], appended[1][1], session.device, 4)],
    )
    response = await _post(client, session, prune)
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == "prune_compaction_not_found"


# ── Class 5: the payload shape, refused at decode ─────────────────────────────


async def test_a_prune_with_no_targets_is_refused(
    client: AsyncClient, session: Session
) -> None:
    """A prune that attests nothing materialises nothing.

    Refused at the shape level so both codecs agree byte-for-byte rather than one
    of them storing an op the other quarantines.
    """
    compaction, compaction_op_id = _compaction(session)
    prune = _prune(session, compaction_op_id=compaction_op_id, targets=[])
    response = await _post(client, session, compaction, prune)
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == "prune_targets_empty"


@pytest.mark.parametrize("duplicate_key", ["seq", "author_position"])
async def test_a_prune_with_duplicate_targets_is_refused_at_decode(
    client: AsyncClient, session: Session, duplicate_key: str
) -> None:
    """Both duplicate keys, and **before** the materialisation rowcount check.

    With duplicates excluded at decode a rowcount mismatch has exactly one cause
    left — a concurrent prune — so the race can never be misreported as a shape
    error or the other way round.
    """
    appended = await _append_content(client, session, 2)
    first = _target(appended[0][0], appended[0][1], session.device, 3)
    second = (
        first
        if duplicate_key == "seq"
        else PruneTarget(
            seq=appended[1][1],
            author_member_id=first.author_member_id,
            author_seq=first.author_seq,
            envelope_hash=envelope_hash(appended[1][0]),
        )
    )
    compaction, compaction_op_id = _compaction(session)
    prune = _prune(session, compaction_op_id=compaction_op_id, targets=[first, second])
    response = await _post(client, session, compaction, prune)
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == "prune_duplicate_target"


async def test_a_prune_over_the_target_bound_is_refused(
    client: AsyncClient, session: Session
) -> None:
    compaction, compaction_op_id = _compaction(session)
    prune = _prune(
        session,
        compaction_op_id=compaction_op_id,
        targets=[
            PruneTarget(
                seq=index + 1,
                author_member_id=session.device.member_id,
                author_seq=index + 1,
                envelope_hash=bytes(32),
            )
            for index in range(MAX_PRUNE_TARGETS + 1)
        ],
    )
    response = await _post(client, session, compaction, prune)
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == "prune_targets_too_many"


async def test_a_malformed_prune_payload_is_refused(
    client: AsyncClient, session: Session
) -> None:
    envelope = session.device.next_envelope(
        session.workspace_id,
        op_class=OP_CLASS_PRUNE,
        payload=b'{"targets":[]}',
    )
    response = await _post(client, session, envelope)
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == "malformed_prune_payload"


# ── Replay, and the history view ──────────────────────────────────────────────


async def test_replaying_a_prune_is_idempotent_and_does_not_move_the_stamp(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    appended = await _append_content(client, session, 1)
    compaction, compaction_op_id = _compaction(session)
    prune = _prune(
        session,
        compaction_op_id=compaction_op_id,
        targets=[_target(appended[0][0], appended[0][1], session.device, 3)],
    )
    first = await _post(client, session, compaction, prune)
    assert first.status_code == 200, first.text
    prune_seq = first.json()["results"][1]["seq"]

    replay = await _post(client, session, compaction, prune)
    assert replay.status_code == 200, replay.text
    assert [result["duplicate"] for result in replay.json()["results"]] == [True, True]
    stored = {op.seq: op for op in await _stored(db)}
    assert stored[appended[0][1]].compacted_by == prune_seq


async def test_a_compacted_row_is_hidden_by_default_and_served_on_request(
    client: AsyncClient, session: Session
) -> None:
    appended = await _append_content(client, session, 2)
    compaction, compaction_op_id = _compaction(session)
    prune = _prune(
        session,
        compaction_op_id=compaction_op_id,
        targets=[_target(appended[0][0], appended[0][1], session.device, 3)],
    )
    posted = await _post(client, session, compaction, prune)
    assert posted.status_code == 200, posted.text

    def envelopes(payload: dict[str, object]) -> list[bytes]:
        ops = payload["ops"]
        assert isinstance(ops, list)
        return [base64.b64decode(op["envelope"]) for op in ops]

    default = (
        await client.get(
            f"/w/{session.workspace_id}/ops",
            params={"since": session.founded_through_seq},
            headers=session.headers,
        )
    ).json()
    assert appended[0][0] not in envelopes(default)
    assert appended[1][0] in envelopes(default)

    history = (
        await client.get(
            f"/w/{session.workspace_id}/ops",
            params={"since": session.founded_through_seq, "include_compacted": "true"},
            headers=session.headers,
        )
    ).json()
    assert appended[0][0] in envelopes(history)
    assert appended[1][0] in envelopes(history)


async def test_the_history_view_needs_no_more_than_the_member_get_bar(
    client: AsyncClient, session: Session
) -> None:
    """History stays available to the User on demand — no extra gate.

    A pre-grant Member reaches the default pull, so it reaches this one too:
    ``include_compacted`` widens *what* is served, never *who* may ask.
    """
    ungranted = await open_session(client, "compaction-ungranted@example.com", genesis=False)
    response = await client.get(
        f"/w/{ungranted.workspace_id}/ops",
        params={"include_compacted": "true"},
        headers=ungranted.headers,
    )
    assert response.status_code == 200, response.text
    assert response.json()["ops"] == []
    del session


async def test_a_freshly_appended_content_op_is_never_pre_stamped(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """The stamp has exactly one writer, and it is a verified prune op."""
    await _append_content(client, session, 2)
    assert all(
        op.compacted_by is None
        for op in await _stored(db)
        if op.op_class == OP_CLASS_CONTENT
    )
