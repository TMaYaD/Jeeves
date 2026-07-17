"""Connector-upload tests for the capture split (ADR-0006, issue #184).

These mirror test_todos.py::test_connector_shaped_payload_roundtrips_client_state
and test_todo_tags_user_id_populated_on_all_write_paths for the three new
capture tables.  The capture routes are connector-only (POST/PATCH/DELETE, no
GET), so round-trips are verified straight off the DB row.
"""

from datetime import datetime
from uuid import uuid4

import jwt
import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.todos.models import Capture, CaptureOutcome, CaptureTag
from tests.conftest import auth_header, register


def _assert_instant(value: str, expected_iso: str) -> None:
    """Assert a returned timestamp matches the expected instant.

    Production Postgres (TIMESTAMPTZ) returns timezone-aware values that
    compare as instants.  The SQLite test harness strips the offset on a
    DB re-read and hands back the naive wall-clock exactly as sent, so a
    naive value is compared against the expectation's wall-clock instead."""
    returned = datetime.fromisoformat(value)
    expected = datetime.fromisoformat(expected_iso)
    if returned.tzinfo is None:
        assert returned == expected.replace(tzinfo=None), (value, expected_iso)
    else:
        assert returned == expected, (value, expected_iso)


def _user_id(token: str) -> str:
    claims = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
    return str(claims["sub"])


async def _make_todo(client: AsyncClient, token: str, title: str = "Outcome") -> str:
    resp = await client.post("/todos/", json={"title": title}, headers=auth_header(token))
    assert resp.status_code == 201, resp.text
    return str(resp.json()["id"])


async def _make_tag(client: AsyncClient, token: str, name: str = "@home") -> str:
    resp = await client.post(
        "/tags/", json={"name": name, "type": "context"}, headers=auth_header(token)
    )
    assert resp.status_code == 201, resp.text
    return str(resp.json()["id"])


# ── captures: connector-shaped roundtrip ──────────────────────────────────────


@pytest.mark.asyncio
async def test_capture_connector_payload_roundtrips_with_clarified_at(
    client: AsyncClient, db: AsyncSession
) -> None:
    token = await register(client, "capture-clarified@example.com")
    headers = auth_header(token)
    capture_id = str(uuid4())

    payload = {
        "id": capture_id,
        "title": "Connector-shaped capture",
        "notes": "raw note",
        "capture_source": "share_sheet",
        "created_at": "2026-07-10T09:15:00.000 +05:30",
        "clarified_at": "2026-07-11T18:30:00.000Z",
        "updated_at": "2026-07-11T18:30:00.000 +05:30",
        "user_id": "spoofed-user-id",  # server-owned: must be ignored
    }
    create = await client.post("/captures/", json=payload, headers=headers)
    assert create.status_code == 201, create.text
    created = create.json()
    _assert_instant(created["created_at"], "2026-07-10T09:15:00+05:30")
    _assert_instant(created["clarified_at"], "2026-07-11T18:30:00+00:00")
    _assert_instant(created["updated_at"], "2026-07-11T18:30:00+05:30")
    assert created["capture_source"] == "share_sheet"

    row = (await db.execute(select(Capture).where(Capture.id == capture_id))).scalar_one()
    assert row.title == "Connector-shaped capture"
    assert row.notes == "raw note"
    assert row.capture_source == "share_sheet"
    assert row.user_id == _user_id(token)
    assert row.user_id != "spoofed-user-id"


@pytest.mark.asyncio
async def test_capture_connector_payload_roundtrips_inbox_null_clarified_at(
    client: AsyncClient, db: AsyncSession
) -> None:
    """clarified_at absent = still in the Inbox: it must persist as NULL."""
    token = await register(client, "capture-inbox@example.com")
    headers = auth_header(token)
    capture_id = str(uuid4())

    payload = {
        "id": capture_id,
        "title": "Inbox thought",
        "created_at": "2026-07-10T09:15:00.000 +05:30",
        "user_id": "spoofed-user-id",
    }
    create = await client.post("/captures/", json=payload, headers=headers)
    assert create.status_code == 201, create.text
    assert create.json()["clarified_at"] is None
    assert create.json()["updated_at"] is None

    row = (await db.execute(select(Capture).where(Capture.id == capture_id))).scalar_one()
    assert row.clarified_at is None
    assert row.user_id == _user_id(token)


@pytest.mark.asyncio
async def test_capture_patch_can_unclarify(client: AsyncClient, db: AsyncSession) -> None:
    """clarified_at is nullable — explicit null on PATCH moves back to Inbox."""
    token = await register(client, "capture-unclarify@example.com")
    headers = auth_header(token)
    capture_id = str(uuid4())
    await client.post(
        "/captures/",
        json={"id": capture_id, "title": "t", "clarified_at": "2026-07-11T18:30:00.000Z"},
        headers=headers,
    )
    patch = await client.patch(
        f"/captures/{capture_id}", json={"clarified_at": None}, headers=headers
    )
    assert patch.status_code == 200
    assert patch.json()["clarified_at"] is None


@pytest.mark.asyncio
async def test_capture_patch_null_title_rejected(client: AsyncClient) -> None:
    token = await register(client, "capture-null-title@example.com")
    headers = auth_header(token)
    capture_id = str(uuid4())
    await client.post("/captures/", json={"id": capture_id, "title": "t"}, headers=headers)
    patch = await client.patch(f"/captures/{capture_id}", json={"title": None}, headers=headers)
    assert patch.status_code == 422


@pytest.mark.asyncio
async def test_capture_create_same_id_idempotent_and_conflict(
    client: AsyncClient,
) -> None:
    # Replaying the identical create is idempotent (returns the stored row);
    # replaying the same id with different data is a 409 rather than silently
    # discarding the conflicting offline upload.
    token = await register(client, "capture-same-id@example.com")
    headers = auth_header(token)
    capture_id = str(uuid4())
    body = {"id": capture_id, "title": "t", "notes": "n"}
    first = await client.post("/captures/", json=body, headers=headers)
    assert first.status_code == 201
    replay = await client.post("/captures/", json=body, headers=headers)
    assert replay.status_code == 201
    assert replay.json()["id"] == first.json()["id"]
    conflict = await client.post(
        "/captures/",
        json={"id": capture_id, "title": "different"},
        headers=headers,
    )
    assert conflict.status_code == 409


@pytest.mark.asyncio
async def test_capture_create_explicit_null_created_at_rejected(client: AsyncClient) -> None:
    # created_at is NOT NULL; an explicit null must 422, not null the column
    # (omission is fine — the server default applies).
    token = await register(client, "capture-null-created@example.com")
    resp = await client.post(
        "/captures/",
        json={"id": str(uuid4()), "title": "t", "created_at": None},
        headers=auth_header(token),
    )
    assert resp.status_code == 422


@pytest.mark.asyncio
async def test_capture_create_over_length_fields_rejected(client: AsyncClient) -> None:
    # title/capture_source lengths mirror the DB columns so an over-long value
    # 422s at the schema instead of a commit-time 500 → infinite retry.
    token = await register(client, "capture-toolong@example.com")
    headers = auth_header(token)
    long_title = await client.post(
        "/captures/",
        json={"id": str(uuid4()), "title": "x" * 501},
        headers=headers,
    )
    assert long_title.status_code == 422
    long_source = await client.post(
        "/captures/",
        json={"id": str(uuid4()), "title": "t", "capture_source": "s" * 51},
        headers=headers,
    )
    assert long_source.status_code == 422


@pytest.mark.asyncio
async def test_capture_delete_clears_children(client: AsyncClient, db: AsyncSession) -> None:
    token = await register(client, "capture-delete@example.com")
    headers = auth_header(token)
    capture_id = str(uuid4())
    await client.post("/captures/", json={"id": capture_id, "title": "t"}, headers=headers)
    todo_id = await _make_todo(client, token)
    tag_id = await _make_tag(client, token)
    await client.post(
        "/capture_outcomes/",
        json={"capture_id": capture_id, "outcome_id": todo_id},
        headers=headers,
    )
    await client.post(
        "/capture_tags/",
        json={"capture_id": capture_id, "tag_id": tag_id},
        headers=headers,
    )

    delete = await client.delete(f"/captures/{capture_id}", headers=headers)
    assert delete.status_code == 204

    outcomes = (
        (await db.execute(select(CaptureOutcome).where(CaptureOutcome.capture_id == capture_id)))
        .scalars()
        .all()
    )
    tags = (
        (await db.execute(select(CaptureTag).where(CaptureTag.capture_id == capture_id)))
        .scalars()
        .all()
    )
    assert outcomes == []
    assert tags == []
    # Idempotent delete: gone → 404.
    again = await client.delete(f"/captures/{capture_id}", headers=headers)
    assert again.status_code == 404


# ── capture_outcomes: roundtrip, denormalization, ownership, idempotency ───────


@pytest.mark.asyncio
async def test_capture_outcome_roundtrips_client_created_at(
    client: AsyncClient, db: AsyncSession
) -> None:
    token = await register(client, "co-roundtrip@example.com")
    headers = auth_header(token)
    capture_id = str(uuid4())
    await client.post("/captures/", json={"id": capture_id, "title": "t"}, headers=headers)
    todo_id = await _make_todo(client, token)
    row_id = str(uuid4())

    create = await client.post(
        "/capture_outcomes/",
        json={
            "id": row_id,
            "capture_id": capture_id,
            "outcome_id": todo_id,
            "created_at": "2026-07-12T08:00:00.000 +05:30",
            "user_id": "spoofed-user-id",
        },
        headers=headers,
    )
    assert create.status_code == 201, create.text
    created = create.json()
    _assert_instant(created["created_at"], "2026-07-12T08:00:00+05:30")
    assert created["user_id"] == _user_id(token)
    assert created["user_id"] != "spoofed-user-id"

    row = (await db.execute(select(CaptureOutcome).where(CaptureOutcome.id == row_id))).scalar_one()
    assert row.capture_id == capture_id
    assert row.outcome_id == todo_id
    assert row.user_id == _user_id(token)

    # PATCH by client id: created_at is client-owned and must persist.
    patch = await client.patch(
        f"/capture_outcomes/{row_id}",
        json={"created_at": "2026-07-13T09:30:00.000 +05:30"},
        headers=headers,
    )
    assert patch.status_code == 200, patch.text
    _assert_instant(patch.json()["created_at"], "2026-07-13T09:30:00+05:30")
    db.expire_all()
    row = (await db.execute(select(CaptureOutcome).where(CaptureOutcome.id == row_id))).scalar_one()
    _assert_instant(row.created_at.isoformat(), "2026-07-13T09:30:00+05:30")

    # DELETE by client id: 204, row gone; idempotent replay is a 404 the
    # connector's fatal-4xx path skips harmlessly (docs/SYNC.md).
    delete = await client.delete(f"/capture_outcomes/{row_id}", headers=headers)
    assert delete.status_code == 204
    db.expire_all()
    gone = (
        await db.execute(select(CaptureOutcome).where(CaptureOutcome.id == row_id))
    ).scalar_one_or_none()
    assert gone is None
    again = await client.delete(f"/capture_outcomes/{row_id}", headers=headers)
    assert again.status_code == 404


@pytest.mark.asyncio
async def test_capture_outcome_user_id_populated(client: AsyncClient, db: AsyncSession) -> None:
    token = await register(client, "co-user@example.com")
    headers = auth_header(token)
    user_id = _user_id(token)
    capture_id = str(uuid4())
    await client.post("/captures/", json={"id": capture_id, "title": "t"}, headers=headers)
    todo_id = await _make_todo(client, token)
    await client.post(
        "/capture_outcomes/",
        json={"capture_id": capture_id, "outcome_id": todo_id},
        headers=headers,
    )
    rows = (
        (await db.execute(select(CaptureOutcome).where(CaptureOutcome.capture_id == capture_id)))
        .scalars()
        .all()
    )
    assert len(rows) == 1
    assert rows[0].user_id == user_id


@pytest.mark.asyncio
async def test_capture_outcome_rejects_unowned_capture(client: AsyncClient) -> None:
    token_a = await register(client, "co-owner-a@example.com")
    token_b = await register(client, "co-owner-b@example.com")
    capture_id = str(uuid4())
    await client.post(
        "/captures/", json={"id": capture_id, "title": "t"}, headers=auth_header(token_a)
    )
    todo_id = await _make_todo(client, token_b)
    # B tries to link A's capture.
    resp = await client.post(
        "/capture_outcomes/",
        json={"capture_id": capture_id, "outcome_id": todo_id},
        headers=auth_header(token_b),
    )
    assert resp.status_code == 404


@pytest.mark.asyncio
async def test_capture_outcome_rejects_unowned_outcome(client: AsyncClient) -> None:
    token_a = await register(client, "co-out-a@example.com")
    token_b = await register(client, "co-out-b@example.com")
    capture_id = str(uuid4())
    await client.post(
        "/captures/", json={"id": capture_id, "title": "t"}, headers=auth_header(token_b)
    )
    todo_id = await _make_todo(client, token_a)  # A's todo
    resp = await client.post(
        "/capture_outcomes/",
        json={"capture_id": capture_id, "outcome_id": todo_id},
        headers=auth_header(token_b),
    )
    assert resp.status_code == 404


@pytest.mark.asyncio
async def test_capture_outcome_idempotent_same_id(client: AsyncClient) -> None:
    token = await register(client, "co-idem@example.com")
    headers = auth_header(token)
    capture_id = str(uuid4())
    await client.post("/captures/", json={"id": capture_id, "title": "t"}, headers=headers)
    todo_id = await _make_todo(client, token)
    row_id = str(uuid4())
    body = {"id": row_id, "capture_id": capture_id, "outcome_id": todo_id}
    first = await client.post("/capture_outcomes/", json=body, headers=headers)
    second = await client.post("/capture_outcomes/", json=body, headers=headers)
    assert first.status_code == 201
    assert second.status_code == 201
    assert first.json()["id"] == second.json()["id"]


@pytest.mark.asyncio
async def test_capture_outcome_pair_dedupe_across_client_ids(client: AsyncClient) -> None:
    # Two devices carve the same (capture, outcome) link with different client
    # ids: the second must dedupe on the pair and return the already-persisted
    # row rather than create a duplicate or wedge the queue with a 4xx.
    token = await register(client, "co-pair@example.com")
    headers = auth_header(token)
    capture_id = str(uuid4())
    await client.post("/captures/", json={"id": capture_id, "title": "t"}, headers=headers)
    todo_id = await _make_todo(client, token)
    first = await client.post(
        "/capture_outcomes/",
        json={"id": str(uuid4()), "capture_id": capture_id, "outcome_id": todo_id},
        headers=headers,
    )
    second = await client.post(
        "/capture_outcomes/",
        json={"id": str(uuid4()), "capture_id": capture_id, "outcome_id": todo_id},
        headers=headers,
    )
    assert first.status_code == 201
    assert second.status_code == 201
    # Same persisted row — the pair, not the client id, is the dedupe key.
    assert second.json()["id"] == first.json()["id"]


@pytest.mark.asyncio
async def test_capture_outcome_same_id_different_relation_conflicts(
    client: AsyncClient,
) -> None:
    token = await register(client, "co-conflict@example.com")
    headers = auth_header(token)
    capture_id = str(uuid4())
    await client.post("/captures/", json={"id": capture_id, "title": "t"}, headers=headers)
    todo_a = await _make_todo(client, token, "a")
    todo_b = await _make_todo(client, token, "b")
    row_id = str(uuid4())
    first = await client.post(
        "/capture_outcomes/",
        json={"id": row_id, "capture_id": capture_id, "outcome_id": todo_a},
        headers=headers,
    )
    assert first.status_code == 201
    conflict = await client.post(
        "/capture_outcomes/",
        json={"id": row_id, "capture_id": capture_id, "outcome_id": todo_b},
        headers=headers,
    )
    assert conflict.status_code == 409


# ── capture_tags: denormalization, ownership, idempotency ─────────────────────


@pytest.mark.asyncio
async def test_capture_tag_user_id_populated(client: AsyncClient, db: AsyncSession) -> None:
    token = await register(client, "ct-user@example.com")
    headers = auth_header(token)
    user_id = _user_id(token)
    capture_id = str(uuid4())
    await client.post("/captures/", json={"id": capture_id, "title": "t"}, headers=headers)
    tag_id = await _make_tag(client, token)
    row_id = str(uuid4())
    create = await client.post(
        "/capture_tags/",
        json={
            "id": row_id,
            "capture_id": capture_id,
            "tag_id": tag_id,
            "user_id": "spoofed-user-id",
        },
        headers=headers,
    )
    assert create.status_code == 201, create.text
    assert create.json()["user_id"] == user_id
    assert create.json()["user_id"] != "spoofed-user-id"

    row = (await db.execute(select(CaptureTag).where(CaptureTag.id == row_id))).scalar_one()
    assert row.capture_id == capture_id
    assert row.tag_id == tag_id
    assert row.user_id == user_id


@pytest.mark.asyncio
async def test_capture_tag_rejects_unowned_capture(client: AsyncClient) -> None:
    token_a = await register(client, "ct-a@example.com")
    token_b = await register(client, "ct-b@example.com")
    capture_id = str(uuid4())
    await client.post(
        "/captures/", json={"id": capture_id, "title": "t"}, headers=auth_header(token_a)
    )
    tag_id = await _make_tag(client, token_b)
    resp = await client.post(
        "/capture_tags/",
        json={"capture_id": capture_id, "tag_id": tag_id},
        headers=auth_header(token_b),
    )
    assert resp.status_code == 404


@pytest.mark.asyncio
async def test_capture_tag_rejects_unowned_tag(client: AsyncClient) -> None:
    token_a = await register(client, "ct-tag-a@example.com")
    token_b = await register(client, "ct-tag-b@example.com")
    capture_id = str(uuid4())
    await client.post(
        "/captures/", json={"id": capture_id, "title": "t"}, headers=auth_header(token_b)
    )
    tag_id = await _make_tag(client, token_a)  # A's tag
    resp = await client.post(
        "/capture_tags/",
        json={"capture_id": capture_id, "tag_id": tag_id},
        headers=auth_header(token_b),
    )
    assert resp.status_code == 404


@pytest.mark.asyncio
async def test_capture_tag_idempotent_and_conflict(client: AsyncClient) -> None:
    token = await register(client, "ct-idem@example.com")
    headers = auth_header(token)
    capture_id = str(uuid4())
    await client.post("/captures/", json={"id": capture_id, "title": "t"}, headers=headers)
    tag_a = await _make_tag(client, token, "@home")
    tag_b = await _make_tag(client, token, "@office")
    row_id = str(uuid4())
    body = {"id": row_id, "capture_id": capture_id, "tag_id": tag_a}
    first = await client.post("/capture_tags/", json=body, headers=headers)
    second = await client.post("/capture_tags/", json=body, headers=headers)
    assert first.status_code == 201
    assert second.status_code == 201
    assert first.json()["id"] == second.json()["id"]

    conflict = await client.post(
        "/capture_tags/",
        json={"id": row_id, "capture_id": capture_id, "tag_id": tag_b},
        headers=headers,
    )
    assert conflict.status_code == 409


@pytest.mark.asyncio
async def test_capture_tag_pair_dedupe_across_client_ids(client: AsyncClient) -> None:
    # Same (capture, tag) hint replayed with a different client id dedupes on
    # the pair and returns the persisted row, never a duplicate or a 4xx.
    token = await register(client, "ct-pair@example.com")
    headers = auth_header(token)
    capture_id = str(uuid4())
    await client.post("/captures/", json={"id": capture_id, "title": "t"}, headers=headers)
    tag_id = await _make_tag(client, token)
    first = await client.post(
        "/capture_tags/",
        json={"id": str(uuid4()), "capture_id": capture_id, "tag_id": tag_id},
        headers=headers,
    )
    second = await client.post(
        "/capture_tags/",
        json={"id": str(uuid4()), "capture_id": capture_id, "tag_id": tag_id},
        headers=headers,
    )
    assert first.status_code == 201
    assert second.status_code == 201
    assert second.json()["id"] == first.json()["id"]


@pytest.mark.asyncio
async def test_capture_tag_delete_idempotent(client: AsyncClient) -> None:
    token = await register(client, "ct-delete@example.com")
    headers = auth_header(token)
    capture_id = str(uuid4())
    await client.post("/captures/", json={"id": capture_id, "title": "t"}, headers=headers)
    tag_id = await _make_tag(client, token)
    row_id = str(uuid4())
    await client.post(
        "/capture_tags/",
        json={"id": row_id, "capture_id": capture_id, "tag_id": tag_id},
        headers=headers,
    )
    first = await client.delete(f"/capture_tags/{row_id}", headers=headers)
    assert first.status_code == 204
    second = await client.delete(f"/capture_tags/{row_id}", headers=headers)
    assert second.status_code == 404
