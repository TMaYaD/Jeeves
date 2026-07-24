"""Connector-upload tests for the actions table (ADR-0001 story 1, issue #471).

Mirror test_captures.py: the action routes are connector-only (POST/PATCH/
DELETE, no GET), so round-trips are verified straight off the DB row.  The
route contract is the ADR-0015 upsert-on-replay one — a same-user id replay
upserts (2xx), a cross-user id collision is a 409, and Outcome ownership is a
route-level 404.
"""

from datetime import datetime
from uuid import uuid4

import jwt
import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.todos.models import Action
from tests.conftest import auth_header, register


def _assert_instant(value: str, expected_iso: str) -> None:
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


# ── actions: connector-shaped roundtrip ───────────────────────────────────────


@pytest.mark.asyncio
async def test_action_connector_payload_roundtrips_client_state(
    client: AsyncClient, db: AsyncSession
) -> None:
    token = await register(client, "action-roundtrip@example.com")
    headers = auth_header(token)
    todo_id = await _make_todo(client, token)
    action_id = str(uuid4())

    payload = {
        "id": action_id,
        "outcome_id": todo_id,
        "text": "draft the memo",
        "role": "current",
        "energy_level": "medium",
        "time_estimate": 25,
        "created_at": "2026-07-10T09:15:00.000 +05:30",
        "updated_at": "2026-07-11T18:30:00.000 +05:30",
        "user_id": "spoofed-user-id",  # server-owned: must be ignored
    }
    create = await client.post("/actions/", json=payload, headers=headers)
    assert create.status_code == 201, create.text
    created = create.json()
    assert created["role"] == "current"
    assert created["text"] == "draft the memo"
    assert created["energy_level"] == "medium"
    assert created["time_estimate"] == 25
    _assert_instant(created["created_at"], "2026-07-10T09:15:00+05:30")
    _assert_instant(created["updated_at"], "2026-07-11T18:30:00+05:30")
    assert created["done_at"] is None
    assert created["position"] is None

    row = (await db.execute(select(Action).where(Action.id == action_id))).scalar_one()
    assert row.outcome_id == todo_id
    assert row.text == "draft the memo"
    assert row.role == "current"
    assert row.user_id == _user_id(token)
    assert row.user_id != "spoofed-user-id"


@pytest.mark.asyncio
async def test_action_create_replay_converges_client_state(
    client: AsyncClient, db: AsyncSession
) -> None:
    # Upsert-on-replay (ADR-0015): replaying the identical create is idempotent;
    # a same-id replay carrying newer client-owned values converges the server
    # row (2xx) instead of reverting the offline edit one checkpoint later.
    token = await register(client, "action-same-id@example.com")
    headers = auth_header(token)
    todo_id = await _make_todo(client, token)
    action_id = str(uuid4())
    body = {
        "id": action_id,
        "outcome_id": todo_id,
        "text": "first",
        "role": "current",
        "time_estimate": 10,
    }
    first = await client.post("/actions/", json=body, headers=headers)
    assert first.status_code == 201
    replay = await client.post("/actions/", json=body, headers=headers)
    assert replay.status_code == 201
    assert replay.json()["id"] == first.json()["id"]
    # A consolidated replay carries the newer offline edit — it must converge.
    converge = await client.post(
        "/actions/",
        json={"id": action_id, "outcome_id": todo_id, "text": "second", "role": "current"},
        headers=headers,
    )
    assert converge.status_code == 201
    assert converge.json()["text"] == "second"
    # The omitted time_estimate is left untouched (exclude_unset), not defaulted.
    assert converge.json()["time_estimate"] == 10
    row = (await db.execute(select(Action).where(Action.id == action_id))).scalar_one()
    assert row.text == "second"
    assert row.time_estimate == 10


@pytest.mark.asyncio
async def test_action_create_same_id_across_users_is_409(client: AsyncClient) -> None:
    token_a = await register(client, "action-xuser-a@example.com")
    token_b = await register(client, "action-xuser-b@example.com")
    todo_a = await _make_todo(client, token_a)
    todo_b = await _make_todo(client, token_b)
    action_id = str(uuid4())
    first = await client.post(
        "/actions/",
        json={"id": action_id, "outcome_id": todo_a, "text": "t", "role": "current"},
        headers=auth_header(token_a),
    )
    assert first.status_code == 201
    conflict = await client.post(
        "/actions/",
        json={"id": action_id, "outcome_id": todo_b, "text": "t", "role": "current"},
        headers=auth_header(token_b),
    )
    assert conflict.status_code == 409


@pytest.mark.asyncio
async def test_action_create_rejects_unowned_outcome(client: AsyncClient) -> None:
    token_a = await register(client, "action-own-a@example.com")
    token_b = await register(client, "action-own-b@example.com")
    todo_a = await _make_todo(client, token_a)  # A's Outcome
    resp = await client.post(
        "/actions/",
        json={"id": str(uuid4()), "outcome_id": todo_a, "text": "t", "role": "current"},
        headers=auth_header(token_b),
    )
    assert resp.status_code == 404


@pytest.mark.asyncio
async def test_action_create_invalid_role_rejected(client: AsyncClient) -> None:
    token = await register(client, "action-bad-role@example.com")
    headers = auth_header(token)
    todo_id = await _make_todo(client, token)
    resp = await client.post(
        "/actions/",
        json={"id": str(uuid4()), "outcome_id": todo_id, "text": "t", "role": "nope"},
        headers=headers,
    )
    assert resp.status_code == 422


@pytest.mark.asyncio
async def test_action_create_explicit_null_created_at_rejected(client: AsyncClient) -> None:
    # created_at is NOT NULL; an explicit null must 422, not null the column
    # (omission is fine — the server default applies).
    token = await register(client, "action-null-created@example.com")
    headers = auth_header(token)
    todo_id = await _make_todo(client, token)
    resp = await client.post(
        "/actions/",
        json={
            "id": str(uuid4()),
            "outcome_id": todo_id,
            "text": "t",
            "role": "current",
            "created_at": None,
        },
        headers=headers,
    )
    assert resp.status_code == 422


@pytest.mark.asyncio
async def test_action_patch_and_delete(client: AsyncClient, db: AsyncSession) -> None:
    token = await register(client, "action-patch@example.com")
    headers = auth_header(token)
    todo_id = await _make_todo(client, token)
    action_id = str(uuid4())
    await client.post(
        "/actions/",
        json={"id": action_id, "outcome_id": todo_id, "text": "t", "role": "current"},
        headers=headers,
    )

    patch = await client.patch(
        f"/actions/{action_id}",
        json={"role": "done", "done_at": "2026-07-12T08:00:00.000Z"},
        headers=headers,
    )
    assert patch.status_code == 200, patch.text
    assert patch.json()["role"] == "done"
    _assert_instant(patch.json()["done_at"], "2026-07-12T08:00:00+00:00")

    # PATCH on an unknown id is a 404.
    missing = await client.patch(f"/actions/{uuid4()}", json={"text": "x"}, headers=headers)
    assert missing.status_code == 404

    # DELETE by id: 204, gone; idempotent replay is a 404.
    delete = await client.delete(f"/actions/{action_id}", headers=headers)
    assert delete.status_code == 204
    db.expire_all()
    gone = (await db.execute(select(Action).where(Action.id == action_id))).scalar_one_or_none()
    assert gone is None
    again = await client.delete(f"/actions/{action_id}", headers=headers)
    assert again.status_code == 404


@pytest.mark.asyncio
async def test_completion_patch_replays_idempotently(client: AsyncClient, db: AsyncSession) -> None:
    """A completion replayed from an offline queue converges (ADR-0001 story 4).

    The client uploads Action completion as PATCH {role, done_at, updated_at};
    `update_action` applies fields unconditionally, so replaying the identical
    payload lands the identical terminal row — no duplicate terminal rows and
    no resurrection of the `current` role.
    """
    token = await register(client, "action-replay@example.com")
    headers = auth_header(token)
    todo_id = await _make_todo(client, token)
    action_id = str(uuid4())
    await client.post(
        "/actions/",
        json={"id": action_id, "outcome_id": todo_id, "text": "t", "role": "current"},
        headers=headers,
    )

    payload = {
        "role": "done",
        "done_at": "2026-07-12T08:00:00.000Z",
        "updated_at": "2026-07-12T08:00:00.000Z",
    }
    first = await client.patch(f"/actions/{action_id}", json=payload, headers=headers)
    assert first.status_code == 200, first.text
    replay = await client.patch(f"/actions/{action_id}", json=payload, headers=headers)
    assert replay.status_code == 200, replay.text
    assert first.json() == replay.json()

    db.expire_all()
    rows = (await db.execute(select(Action).where(Action.outcome_id == todo_id))).scalars().all()
    assert len(rows) == 1
    assert rows[0].role == "done"
    _assert_instant(replay.json()["done_at"], "2026-07-12T08:00:00+00:00")


@pytest.mark.asyncio
async def test_action_patch_null_text_rejected(client: AsyncClient) -> None:
    token = await register(client, "action-null-text@example.com")
    headers = auth_header(token)
    todo_id = await _make_todo(client, token)
    action_id = str(uuid4())
    await client.post(
        "/actions/",
        json={"id": action_id, "outcome_id": todo_id, "text": "t", "role": "current"},
        headers=headers,
    )
    patch = await client.patch(f"/actions/{action_id}", json={"text": None}, headers=headers)
    assert patch.status_code == 422
