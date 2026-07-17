"""REST CRUD for `user_preferences`, called by the PowerSync BackendConnector.

These tests exercise the upload-side path that the mobile client uses to
persist offline writes to the `user_preferences` table. Reconciliation /
conflict semantics are covered separately (see issue #306).
"""

from datetime import datetime

import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.todos.models import UserPreference
from tests.conftest import auth_header, register


@pytest.mark.asyncio
async def test_create_requires_auth(client: AsyncClient) -> None:
    resp = await client.post(
        "/user_preferences/",
        json={
            "key": "last_completed",
            "value": '"2026-05-17T00:00:00Z"',
            "updated_at": "2026-05-17T00:00:00Z",
        },
    )
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_create_persists_row(client: AsyncClient, db: AsyncSession) -> None:
    token = await register(client, "pref-create@example.com")
    resp = await client.post(
        "/user_preferences/",
        json={
            "id": "11111111-1111-1111-1111-111111111111",
            "key": "last_completed",
            "value": '"2026-05-17T10:00:00Z"',
            "updated_at": "2026-05-17T10:00:00Z",
        },
        headers=auth_header(token),
    )
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert body["id"] == "11111111-1111-1111-1111-111111111111"
    assert body["key"] == "last_completed"
    assert body["value"] == '"2026-05-17T10:00:00Z"'

    row = (
        await db.execute(select(UserPreference).where(UserPreference.id == body["id"]))
    ).scalar_one()
    assert row.key == "last_completed"
    assert row.value == '"2026-05-17T10:00:00Z"'


@pytest.mark.asyncio
async def test_create_is_idempotent_and_converges_on_replay(
    client: AsyncClient, db: AsyncSession
) -> None:
    """PowerSync may re-upload the same CRUD entry; the second POST must not
    error.  Upsert-on-replay (ADR-0015): a replay carrying a newer value/
    updated_at converges the stored row instead of returning it stale."""
    token = await register(client, "pref-idem@example.com")
    pref_id = "22222222-2222-2222-2222-222222222222"
    payload = {
        "id": pref_id,
        "key": "last_completed",
        "value": '"v1"',
        "updated_at": "2026-05-17T10:00:00Z",
    }
    first = await client.post("/user_preferences/", json=payload, headers=auth_header(token))
    assert first.status_code == 201

    second = await client.post("/user_preferences/", json=payload, headers=auth_header(token))
    assert second.status_code == 201
    assert second.json()["id"] == pref_id

    converge = await client.post(
        "/user_preferences/",
        json={**payload, "value": '"v2"', "updated_at": "2026-05-17T11:00:00Z"},
        headers=auth_header(token),
    )
    assert converge.status_code == 201
    assert converge.json()["value"] == '"v2"'
    # The newer updated_at converges too — not just the value.  Compare absolute
    # instants when the value is tz-aware (Postgres TIMESTAMPTZ); the SQLite test
    # harness hands back a naive wall-clock, so normalise the expectation then.
    expected_updated = datetime.fromisoformat("2026-05-17T11:00:00+00:00")

    def _assert_instant(value: datetime) -> None:
        if value.tzinfo is None:
            assert value == expected_updated.replace(tzinfo=None)
        else:
            assert value == expected_updated

    _assert_instant(datetime.fromisoformat(converge.json()["updated_at"]))
    row = (
        await db.execute(select(UserPreference).where(UserPreference.id == pref_id))
    ).scalar_one()
    assert row.value == '"v2"'
    _assert_instant(row.updated_at)


@pytest.mark.asyncio
async def test_create_same_id_across_users_is_409(client: AsyncClient) -> None:
    """A same-id collision across users is a genuine anomaly, not a replay."""
    token_a = await register(client, "pref-xuser-a@example.com")
    token_b = await register(client, "pref-xuser-b@example.com")
    payload = {
        "id": "44444444-4444-4444-4444-444444444444",
        "key": "last_completed",
        "value": '"v1"',
        "updated_at": "2026-05-17T10:00:00Z",
    }
    first = await client.post("/user_preferences/", json=payload, headers=auth_header(token_a))
    assert first.status_code == 201
    conflict = await client.post("/user_preferences/", json=payload, headers=auth_header(token_b))
    assert conflict.status_code == 409


@pytest.mark.asyncio
async def test_patch_updates_value_and_timestamp(client: AsyncClient, db: AsyncSession) -> None:
    token = await register(client, "pref-patch@example.com")
    pref_id = "33333333-3333-3333-3333-333333333333"
    await client.post(
        "/user_preferences/",
        json={
            "id": pref_id,
            "key": "last_completed",
            "value": '"v1"',
            "updated_at": "2026-05-17T10:00:00Z",
        },
        headers=auth_header(token),
    )

    resp = await client.patch(
        f"/user_preferences/{pref_id}",
        json={"value": '"v2"', "updated_at": "2026-05-17T11:00:00Z"},
        headers=auth_header(token),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["value"] == '"v2"'

    row = (
        await db.execute(select(UserPreference).where(UserPreference.id == pref_id))
    ).scalar_one()
    assert row.value == '"v2"'


@pytest.mark.asyncio
async def test_patch_can_tombstone_with_null_value(client: AsyncClient) -> None:
    """A patch with value=null is the tombstone path the DAO uses for deletes."""
    token = await register(client, "pref-tombstone@example.com")
    pref_id = "44444444-4444-4444-4444-444444444444"
    await client.post(
        "/user_preferences/",
        json={
            "id": pref_id,
            "key": "last_completed",
            "value": '"v1"',
            "updated_at": "2026-05-17T10:00:00Z",
        },
        headers=auth_header(token),
    )

    resp = await client.patch(
        f"/user_preferences/{pref_id}",
        json={"value": None, "updated_at": "2026-05-17T12:00:00Z"},
        headers=auth_header(token),
    )
    assert resp.status_code == 200
    assert resp.json()["value"] is None


@pytest.mark.asyncio
async def test_patch_explicit_null_updated_at_is_422(client: AsyncClient, db: AsyncSession) -> None:
    """updated_at is NOT NULL: an explicit null on PATCH must be rejected at
    validation (422), not surface as a commit-time IntegrityError (#387).
    value=null stays valid — that is the tombstone path above."""
    token = await register(client, "pref-null-updated-at@example.com")
    pref_id = "88888888-8888-8888-8888-888888888888"
    await client.post(
        "/user_preferences/",
        json={
            "id": pref_id,
            "key": "last_completed",
            "value": '"v1"',
            "updated_at": "2026-05-17T10:00:00Z",
        },
        headers=auth_header(token),
    )

    resp = await client.patch(
        f"/user_preferences/{pref_id}",
        json={"value": '"v2"', "updated_at": None},
        headers=auth_header(token),
    )
    assert resp.status_code == 422

    row = (
        await db.execute(select(UserPreference).where(UserPreference.id == pref_id))
    ).scalar_one()
    assert row.value == '"v1"'


@pytest.mark.asyncio
async def test_delete_removes_row(client: AsyncClient, db: AsyncSession) -> None:
    token = await register(client, "pref-delete@example.com")
    pref_id = "55555555-5555-5555-5555-555555555555"
    await client.post(
        "/user_preferences/",
        json={
            "id": pref_id,
            "key": "last_completed",
            "value": '"v1"',
            "updated_at": "2026-05-17T10:00:00Z",
        },
        headers=auth_header(token),
    )

    resp = await client.delete(f"/user_preferences/{pref_id}", headers=auth_header(token))
    assert resp.status_code == 204

    row = (
        await db.execute(select(UserPreference).where(UserPreference.id == pref_id))
    ).scalar_one_or_none()
    assert row is None


@pytest.mark.asyncio
async def test_user_isolation(client: AsyncClient) -> None:
    """User A cannot patch or delete user B's preference rows."""
    token_a = await register(client, "pref-alice@example.com")
    token_b = await register(client, "pref-bob@example.com")
    pref_id = "66666666-6666-6666-6666-666666666666"

    create = await client.post(
        "/user_preferences/",
        json={
            "id": pref_id,
            "key": "last_completed",
            "value": '"alice"',
            "updated_at": "2026-05-17T10:00:00Z",
        },
        headers=auth_header(token_a),
    )
    assert create.status_code == 201

    bob_patch = await client.patch(
        f"/user_preferences/{pref_id}",
        json={"value": '"bob"', "updated_at": "2026-05-17T11:00:00Z"},
        headers=auth_header(token_b),
    )
    assert bob_patch.status_code == 404

    bob_delete = await client.delete(f"/user_preferences/{pref_id}", headers=auth_header(token_b))
    assert bob_delete.status_code == 404


@pytest.mark.asyncio
async def test_patch_missing_row_returns_404(client: AsyncClient) -> None:
    token = await register(client, "pref-missing@example.com")
    resp = await client.patch(
        "/user_preferences/77777777-7777-7777-7777-777777777777",
        json={"value": '"v1"', "updated_at": "2026-05-17T10:00:00Z"},
        headers=auth_header(token),
    )
    assert resp.status_code == 404
