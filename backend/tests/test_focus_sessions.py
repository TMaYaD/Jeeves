"""Upload-path CRUD for the focus-session sync shapes (#383).

The PowerSync connector uploads local writes for `focus_sessions`,
`focus_session_tasks`, `focus_session_dispositions`, and `time_logs` to these
routes.  Payloads are shaped
exactly like connector PUTs/PATCHes: client-generated `id`, a denormalized
(server-owned, ignored) `user_id`, and Drift-format timestamps.  A 4xx on a
legitimate write would drop the entry via the connector's fatal path; an
unhandled 5xx would head-of-line-block the whole CRUD queue — so these tests
lock in idempotent replay, route-level ownership checks (the SQLite harness
does not enforce FKs), and schema-level validation.
"""

from datetime import datetime
from uuid import uuid4

import jwt
import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.todos.models import (
    FocusSession,
    FocusSessionDisposition,
    FocusSessionTask,
    TimeLog,
)
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


async def _user_id_from(token: str) -> str:
    claims = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
    sub: str = claims["sub"]
    return sub


async def _make_todo(client: AsyncClient, token: str, title: str = "Outcome") -> str:
    resp = await client.post("/todos/", json={"title": title}, headers=auth_header(token))
    assert resp.status_code == 201, resp.text
    todo_id: str = resp.json()["id"]
    return todo_id


async def _make_session(client: AsyncClient, token: str) -> str:
    resp = await client.post(
        "/focus_sessions/",
        json={"id": str(uuid4()), "started_at": "2026-07-12T09:00:00.000Z"},
        headers=auth_header(token),
    )
    assert resp.status_code == 201, resp.text
    session_id: str = resp.json()["id"]
    return session_id


# ── focus_sessions ────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_focus_session_routes_require_auth(client: AsyncClient) -> None:
    for path in (
        "/focus_sessions/",
        "/focus_session_tasks/",
        "/focus_session_dispositions/",
        "/time_logs/",
    ):
        response = await client.post(path, json={})
        assert response.status_code == 401, path


@pytest.mark.asyncio
async def test_create_focus_session_connector_shaped_payload(
    client: AsyncClient, db: AsyncSession
) -> None:
    """A POST shaped exactly like a connector PUT — client id, Drift
    space-before-offset timestamp, spoofed user_id — must persist verbatim,
    with ownership taken from the JWT."""
    token = await register(client, "fs-create@example.com")
    session_id = str(uuid4())

    create = await client.post(
        "/focus_sessions/",
        json={
            "id": session_id,
            "started_at": "2026-07-12T09:00:00.000 +05:30",
            "ended_at": None,
            "current_task_id": None,
            "user_id": "spoofed-user-id",  # server-owned: must be ignored
        },
        headers=auth_header(token),
    )
    assert create.status_code == 201, create.text
    created = create.json()
    assert created["id"] == session_id
    _assert_instant(created["started_at"], "2026-07-12T09:00:00+05:30")
    assert created["ended_at"] is None
    assert created["current_task_id"] is None

    row = (await db.execute(select(FocusSession).where(FocusSession.id == session_id))).scalar_one()
    assert row.user_id == await _user_id_from(token)
    assert row.user_id != "spoofed-user-id"


@pytest.mark.asyncio
async def test_create_focus_session_replay_is_idempotent(
    client: AsyncClient, db: AsyncSession
) -> None:
    token = await register(client, "fs-replay@example.com")
    session_id = str(uuid4())
    payload = {"id": session_id, "started_at": "2026-07-12T09:00:00.000Z"}

    first = await client.post("/focus_sessions/", json=payload, headers=auth_header(token))
    assert first.status_code == 201

    retry = await client.post("/focus_sessions/", json=payload, headers=auth_header(token))
    assert retry.status_code == 201
    assert retry.json()["id"] == session_id

    # Upsert-on-replay (ADR-0015): a consolidated replay carrying a newer
    # client-owned field (the session's ended_at) converges the stored row.
    converge = await client.post(
        "/focus_sessions/",
        json={**payload, "ended_at": "2026-07-12T10:00:00.000Z"},
        headers=auth_header(token),
    )
    assert converge.status_code == 201
    _assert_instant(converge.json()["ended_at"], "2026-07-12T10:00:00Z")

    rows = (
        (await db.execute(select(FocusSession).where(FocusSession.id == session_id)))
        .scalars()
        .all()
    )
    assert len(rows) == 1
    assert rows[0].ended_at is not None
    _assert_instant(rows[0].ended_at.isoformat(), "2026-07-12T10:00:00Z")


@pytest.mark.asyncio
async def test_create_focus_session_id_conflict_across_users_is_409(client: AsyncClient) -> None:
    token_a = await register(client, "fs-conflict-a@example.com")
    token_b = await register(client, "fs-conflict-b@example.com")
    session_id = str(uuid4())
    payload = {"id": session_id, "started_at": "2026-07-12T09:00:00.000Z"}

    first = await client.post("/focus_sessions/", json=payload, headers=auth_header(token_a))
    assert first.status_code == 201

    conflict = await client.post("/focus_sessions/", json=payload, headers=auth_header(token_b))
    assert conflict.status_code == 409


@pytest.mark.asyncio
async def test_create_focus_session_unowned_current_task_is_404(client: AsyncClient) -> None:
    token = await register(client, "fs-task-owner@example.com")
    other = await register(client, "fs-task-other@example.com")
    other_todo = await _make_todo(client, other)

    for current_task_id in (str(uuid4()), other_todo):
        response = await client.post(
            "/focus_sessions/",
            json={
                "id": str(uuid4()),
                "started_at": "2026-07-12T09:00:00.000Z",
                "current_task_id": current_task_id,
            },
            headers=auth_header(token),
        )
        assert response.status_code == 404, current_task_id


@pytest.mark.asyncio
async def test_patch_focus_session_roundtrips_close_and_current_task(
    client: AsyncClient,
) -> None:
    """The connector PATCHes current_task_id when a task is focused and
    ended_at (Drift-format) when the session closes; both must persist."""
    token = await register(client, "fs-patch@example.com")
    headers = auth_header(token)
    session_id = await _make_session(client, token)
    todo_id = await _make_todo(client, token)

    focus = await client.patch(
        f"/focus_sessions/{session_id}",
        json={"current_task_id": todo_id},
        headers=headers,
    )
    assert focus.status_code == 200, focus.text
    assert focus.json()["current_task_id"] == todo_id

    close = await client.patch(
        f"/focus_sessions/{session_id}",
        json={"ended_at": "2026-07-12T17:30:00.000 +05:30", "current_task_id": None},
        headers=headers,
    )
    assert close.status_code == 200, close.text
    _assert_instant(close.json()["ended_at"], "2026-07-12T17:30:00+05:30")
    assert close.json()["current_task_id"] is None


@pytest.mark.asyncio
async def test_patch_focus_session_explicit_null_started_at_is_422(client: AsyncClient) -> None:
    """started_at is NOT NULL: an explicit null must 422 at validation, not
    surface as a commit-time IntegrityError (500 → infinite retry)."""
    token = await register(client, "fs-null@example.com")
    session_id = await _make_session(client, token)

    response = await client.patch(
        f"/focus_sessions/{session_id}",
        json={"started_at": None},
        headers=auth_header(token),
    )
    assert response.status_code == 422


@pytest.mark.asyncio
async def test_patch_focus_session_other_user_is_404(client: AsyncClient) -> None:
    token_a = await register(client, "fs-priv-a@example.com")
    token_b = await register(client, "fs-priv-b@example.com")
    session_id = await _make_session(client, token_a)

    response = await client.patch(
        f"/focus_sessions/{session_id}",
        json={"ended_at": "2026-07-12T17:00:00.000Z"},
        headers=auth_header(token_b),
    )
    assert response.status_code == 404


@pytest.mark.asyncio
async def test_delete_focus_session_removes_children_and_detaches_time_logs(
    client: AsyncClient, db: AsyncSession
) -> None:
    """Neither focus_session_tasks.focus_session_id nor
    time_logs.focus_session_id has ON DELETE CASCADE — the route must clear
    them itself or the Postgres FK violation 500s and wedges the queue.
    Time logs are the user's time data: they are detached, never deleted."""
    token = await register(client, "fs-delete@example.com")
    headers = auth_header(token)
    session_id = await _make_session(client, token)
    todo_id = await _make_todo(client, token)

    task = await client.post(
        "/focus_session_tasks/",
        json={
            "id": str(uuid4()),
            "focus_session_id": session_id,
            "task_id": todo_id,
            "position": 0,
        },
        headers=headers,
    )
    assert task.status_code == 201, task.text

    log_id = str(uuid4())
    log = await client.post(
        "/time_logs/",
        json={
            "id": log_id,
            "task_id": todo_id,
            "started_at": "2026-07-12T09:05:00.000Z",
            "focus_session_id": session_id,
        },
        headers=headers,
    )
    assert log.status_code == 201, log.text

    delete = await client.delete(f"/focus_sessions/{session_id}", headers=headers)
    assert delete.status_code == 204

    tasks = (
        (
            await db.execute(
                select(FocusSessionTask).where(FocusSessionTask.focus_session_id == session_id)
            )
        )
        .scalars()
        .all()
    )
    assert tasks == []
    log_row = (await db.execute(select(TimeLog).where(TimeLog.id == log_id))).scalar_one()
    assert log_row.focus_session_id is None

    repeat = await client.delete(f"/focus_sessions/{session_id}", headers=headers)
    assert repeat.status_code == 404


# ── focus_session_tasks ───────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_create_focus_session_task_connector_shaped_payload(
    client: AsyncClient, db: AsyncSession
) -> None:
    """The exact shape FocusSessionDao.openSession queues: client id,
    integer position, null disposition, denormalized user_id (server-owned,
    ignored)."""
    token = await register(client, "fst-create@example.com")
    session_id = await _make_session(client, token)
    todo_id = await _make_todo(client, token)
    fst_id = str(uuid4())

    create = await client.post(
        "/focus_session_tasks/",
        json={
            "id": fst_id,
            "focus_session_id": session_id,
            "task_id": todo_id,
            "position": 3,
            "disposition": None,
            "user_id": "spoofed-user-id",  # server-owned: must be ignored
        },
        headers=auth_header(token),
    )
    assert create.status_code == 201, create.text
    created = create.json()
    assert created["id"] == fst_id
    assert created["focus_session_id"] == session_id
    assert created["task_id"] == todo_id
    assert created["position"] == 3
    assert created["disposition"] is None

    row = (
        await db.execute(select(FocusSessionTask).where(FocusSessionTask.id == fst_id))
    ).scalar_one()
    assert row.user_id == await _user_id_from(token)
    assert row.user_id != "spoofed-user-id"


@pytest.mark.asyncio
async def test_create_focus_session_task_replay_is_idempotent(
    client: AsyncClient, db: AsyncSession
) -> None:
    """AC: create dedupes by client id — an offline replay of the identical
    POST returns 2xx and leaves a single row."""
    token = await register(client, "fst-replay@example.com")
    session_id = await _make_session(client, token)
    todo_id = await _make_todo(client, token)
    payload = {
        "id": str(uuid4()),
        "focus_session_id": session_id,
        "task_id": todo_id,
        "position": 0,
    }

    first = await client.post("/focus_session_tasks/", json=payload, headers=auth_header(token))
    assert first.status_code == 201

    retry = await client.post("/focus_session_tasks/", json=payload, headers=auth_header(token))
    assert retry.status_code == 201

    rows = (
        (
            await db.execute(
                select(FocusSessionTask).where(
                    FocusSessionTask.focus_session_id == session_id,
                    FocusSessionTask.task_id == todo_id,
                )
            )
        )
        .scalars()
        .all()
    )
    assert len(rows) == 1


@pytest.mark.asyncio
async def test_create_focus_session_task_id_reuse_for_different_relation_is_409(
    client: AsyncClient,
) -> None:
    token = await register(client, "fst-conflict@example.com")
    session_id = await _make_session(client, token)
    todo_a = await _make_todo(client, token, "A")
    todo_b = await _make_todo(client, token, "B")
    fst_id = str(uuid4())

    first = await client.post(
        "/focus_session_tasks/",
        json={"id": fst_id, "focus_session_id": session_id, "task_id": todo_a, "position": 0},
        headers=auth_header(token),
    )
    assert first.status_code == 201

    conflict = await client.post(
        "/focus_session_tasks/",
        json={"id": fst_id, "focus_session_id": session_id, "task_id": todo_b, "position": 1},
        headers=auth_header(token),
    )
    assert conflict.status_code == 409


@pytest.mark.asyncio
async def test_create_focus_session_task_duplicate_relation_returns_existing(
    client: AsyncClient, db: AsyncSession
) -> None:
    """A second POST for the same (session, task) pair under a fresh id is
    deduplicated by the composite relation — no duplicate junction row."""
    token = await register(client, "fst-dup@example.com")
    session_id = await _make_session(client, token)
    todo_id = await _make_todo(client, token)

    first = await client.post(
        "/focus_session_tasks/",
        json={
            "id": str(uuid4()),
            "focus_session_id": session_id,
            "task_id": todo_id,
            "position": 0,
        },
        headers=auth_header(token),
    )
    assert first.status_code == 201

    second = await client.post(
        "/focus_session_tasks/",
        json={
            "id": str(uuid4()),
            "focus_session_id": session_id,
            "task_id": todo_id,
            "position": 5,
        },
        headers=auth_header(token),
    )
    assert second.status_code == 201
    assert second.json()["position"] == 0  # existing row wins

    rows = (
        (
            await db.execute(
                select(FocusSessionTask).where(
                    FocusSessionTask.focus_session_id == session_id,
                    FocusSessionTask.task_id == todo_id,
                )
            )
        )
        .scalars()
        .all()
    )
    assert len(rows) == 1


@pytest.mark.asyncio
async def test_create_focus_session_task_unowned_parents_are_404(client: AsyncClient) -> None:
    token = await register(client, "fst-owner@example.com")
    other = await register(client, "fst-other@example.com")
    my_session = await _make_session(client, token)
    my_todo = await _make_todo(client, token)
    other_session = await _make_session(client, other)
    other_todo = await _make_todo(client, other)

    cases = [
        (str(uuid4()), my_todo),  # unknown session
        (other_session, my_todo),  # other user's session
        (my_session, str(uuid4())),  # unknown todo
        (my_session, other_todo),  # other user's todo
    ]
    for session_id, task_id in cases:
        response = await client.post(
            "/focus_session_tasks/",
            json={
                "id": str(uuid4()),
                "focus_session_id": session_id,
                "task_id": task_id,
                "position": 0,
            },
            headers=auth_header(token),
        )
        assert response.status_code == 404, (session_id, task_id)


@pytest.mark.asyncio
async def test_patch_focus_session_task_disposition_values(client: AsyncClient) -> None:
    """The review flow PATCHes disposition; every legal value must persist
    and garbage must 422 at the schema (a CHECK-constraint violation would
    be a 500 → infinite retry)."""
    token = await register(client, "fst-disposition@example.com")
    headers = auth_header(token)
    session_id = await _make_session(client, token)
    todo_id = await _make_todo(client, token)
    fst_id = str(uuid4())

    create = await client.post(
        "/focus_session_tasks/",
        json={"id": fst_id, "focus_session_id": session_id, "task_id": todo_id, "position": 0},
        headers=headers,
    )
    assert create.status_code == 201

    for disposition in ("rollover", "leave", "maybe"):
        patch = await client.patch(
            f"/focus_session_tasks/{fst_id}",
            json={"disposition": disposition},
            headers=headers,
        )
        assert patch.status_code == 200, patch.text
        assert patch.json()["disposition"] == disposition

    garbage = await client.patch(
        f"/focus_session_tasks/{fst_id}",
        json={"disposition": "shred"},
        headers=headers,
    )
    assert garbage.status_code == 422


@pytest.mark.asyncio
async def test_patch_focus_session_task_position_and_null_rejection(client: AsyncClient) -> None:
    token = await register(client, "fst-position@example.com")
    headers = auth_header(token)
    session_id = await _make_session(client, token)
    todo_id = await _make_todo(client, token)
    fst_id = str(uuid4())

    create = await client.post(
        "/focus_session_tasks/",
        json={"id": fst_id, "focus_session_id": session_id, "task_id": todo_id, "position": 0},
        headers=headers,
    )
    assert create.status_code == 201

    patch = await client.patch(
        f"/focus_session_tasks/{fst_id}", json={"position": 7}, headers=headers
    )
    assert patch.status_code == 200
    assert patch.json()["position"] == 7

    # position is NOT NULL: explicit null must 422, not IntegrityError.
    null_patch = await client.patch(
        f"/focus_session_tasks/{fst_id}", json={"position": None}, headers=headers
    )
    assert null_patch.status_code == 422


@pytest.mark.asyncio
async def test_patch_focus_session_task_other_user_is_404(client: AsyncClient) -> None:
    token_a = await register(client, "fst-priv-a@example.com")
    token_b = await register(client, "fst-priv-b@example.com")
    session_id = await _make_session(client, token_a)
    todo_id = await _make_todo(client, token_a)
    fst_id = str(uuid4())

    create = await client.post(
        "/focus_session_tasks/",
        json={"id": fst_id, "focus_session_id": session_id, "task_id": todo_id, "position": 0},
        headers=auth_header(token_a),
    )
    assert create.status_code == 201

    response = await client.patch(
        f"/focus_session_tasks/{fst_id}",
        json={"disposition": "leave"},
        headers=auth_header(token_b),
    )
    assert response.status_code == 404


@pytest.mark.asyncio
async def test_delete_focus_session_task_then_repeat_is_404(client: AsyncClient) -> None:
    token = await register(client, "fst-delete@example.com")
    headers = auth_header(token)
    session_id = await _make_session(client, token)
    todo_id = await _make_todo(client, token)
    fst_id = str(uuid4())

    create = await client.post(
        "/focus_session_tasks/",
        json={"id": fst_id, "focus_session_id": session_id, "task_id": todo_id, "position": 0},
        headers=headers,
    )
    assert create.status_code == 201

    delete = await client.delete(f"/focus_session_tasks/{fst_id}", headers=headers)
    assert delete.status_code == 204

    repeat = await client.delete(f"/focus_session_tasks/{fst_id}", headers=headers)
    assert repeat.status_code == 404


# ── time_logs ─────────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_create_time_log_connector_shaped_payload(
    client: AsyncClient, db: AsyncSession
) -> None:
    token = await register(client, "tl-create@example.com")
    session_id = await _make_session(client, token)
    todo_id = await _make_todo(client, token)
    log_id = str(uuid4())

    create = await client.post(
        "/time_logs/",
        json={
            "id": log_id,
            "task_id": todo_id,
            "started_at": "2026-07-12T09:05:00.000 +05:30",
            "ended_at": None,
            "focus_session_id": session_id,
            "user_id": "spoofed-user-id",  # server-owned: must be ignored
        },
        headers=auth_header(token),
    )
    assert create.status_code == 201, create.text
    created = create.json()
    assert created["id"] == log_id
    assert created["task_id"] == todo_id
    assert created["focus_session_id"] == session_id
    _assert_instant(created["started_at"], "2026-07-12T09:05:00+05:30")
    assert created["ended_at"] is None

    row = (await db.execute(select(TimeLog).where(TimeLog.id == log_id))).scalar_one()
    assert row.user_id == await _user_id_from(token)
    assert row.user_id != "spoofed-user-id"


@pytest.mark.asyncio
async def test_create_time_log_replay_is_idempotent(client: AsyncClient, db: AsyncSession) -> None:
    token = await register(client, "tl-replay@example.com")
    todo_id = await _make_todo(client, token)
    payload = {
        "id": str(uuid4()),
        "task_id": todo_id,
        "started_at": "2026-07-12T09:05:00.000Z",
    }

    first = await client.post("/time_logs/", json=payload, headers=auth_header(token))
    assert first.status_code == 201

    retry = await client.post("/time_logs/", json=payload, headers=auth_header(token))
    assert retry.status_code == 201

    # Upsert-on-replay (ADR-0015): a consolidated replay carrying a newer
    # client-owned field (ended_at) converges the stored row.
    converge = await client.post(
        "/time_logs/",
        json={**payload, "ended_at": "2026-07-12T09:30:00.000Z"},
        headers=auth_header(token),
    )
    assert converge.status_code == 201
    _assert_instant(converge.json()["ended_at"], "2026-07-12T09:30:00Z")

    rows = (await db.execute(select(TimeLog).where(TimeLog.id == payload["id"]))).scalars().all()
    assert len(rows) == 1
    assert rows[0].ended_at is not None
    _assert_instant(rows[0].ended_at.isoformat(), "2026-07-12T09:30:00Z")


@pytest.mark.asyncio
async def test_create_time_log_unowned_parents_are_404(client: AsyncClient) -> None:
    token = await register(client, "tl-owner@example.com")
    other = await register(client, "tl-other@example.com")
    my_todo = await _make_todo(client, token)
    other_todo = await _make_todo(client, other)
    other_session = await _make_session(client, other)

    unknown_task = await client.post(
        "/time_logs/",
        json={"id": str(uuid4()), "task_id": str(uuid4()), "started_at": "2026-07-12T09:05:00Z"},
        headers=auth_header(token),
    )
    assert unknown_task.status_code == 404

    foreign_task = await client.post(
        "/time_logs/",
        json={"id": str(uuid4()), "task_id": other_todo, "started_at": "2026-07-12T09:05:00Z"},
        headers=auth_header(token),
    )
    assert foreign_task.status_code == 404

    foreign_session = await client.post(
        "/time_logs/",
        json={
            "id": str(uuid4()),
            "task_id": my_todo,
            "started_at": "2026-07-12T09:05:00Z",
            "focus_session_id": other_session,
        },
        headers=auth_header(token),
    )
    assert foreign_session.status_code == 404


@pytest.mark.asyncio
async def test_create_time_log_id_conflict_across_users_is_409(client: AsyncClient) -> None:
    # A cross-user id collision must return 409 (a genuine anomaly), even when
    # the replay also carries the other user's foreign parent id — the id check
    # runs before parent validation, so it wins over a would-be 404.
    token_a = await register(client, "tl-conflict-a@example.com")
    token_b = await register(client, "tl-conflict-b@example.com")
    a_todo = await _make_todo(client, token_a)
    log_id = str(uuid4())

    first = await client.post(
        "/time_logs/",
        json={"id": log_id, "task_id": a_todo, "started_at": "2026-07-12T09:05:00.000Z"},
        headers=auth_header(token_a),
    )
    assert first.status_code == 201

    # User B replays the same id carrying A's foreign task_id.
    conflict = await client.post(
        "/time_logs/",
        json={"id": log_id, "task_id": a_todo, "started_at": "2026-07-12T09:05:00.000Z"},
        headers=auth_header(token_b),
    )
    assert conflict.status_code == 409


@pytest.mark.asyncio
async def test_patch_time_log_close_stint_and_null_rejection(client: AsyncClient) -> None:
    token = await register(client, "tl-patch@example.com")
    headers = auth_header(token)
    todo_id = await _make_todo(client, token)
    log_id = str(uuid4())

    create = await client.post(
        "/time_logs/",
        json={"id": log_id, "task_id": todo_id, "started_at": "2026-07-12T09:05:00.000Z"},
        headers=headers,
    )
    assert create.status_code == 201

    close = await client.patch(
        f"/time_logs/{log_id}",
        json={"ended_at": "2026-07-12T09:30:00.000 +05:30"},
        headers=headers,
    )
    assert close.status_code == 200, close.text
    _assert_instant(close.json()["ended_at"], "2026-07-12T09:30:00+05:30")

    # started_at and task_id are NOT NULL: explicit null must 422.
    for field in ("started_at", "task_id"):
        null_patch = await client.patch(f"/time_logs/{log_id}", json={field: None}, headers=headers)
        assert null_patch.status_code == 422, field


@pytest.mark.asyncio
async def test_patch_time_log_other_user_is_404(client: AsyncClient) -> None:
    token_a = await register(client, "tl-priv-a@example.com")
    token_b = await register(client, "tl-priv-b@example.com")
    todo_id = await _make_todo(client, token_a)
    log_id = str(uuid4())

    create = await client.post(
        "/time_logs/",
        json={"id": log_id, "task_id": todo_id, "started_at": "2026-07-12T09:05:00.000Z"},
        headers=auth_header(token_a),
    )
    assert create.status_code == 201

    response = await client.patch(
        f"/time_logs/{log_id}",
        json={"ended_at": "2026-07-12T09:30:00.000Z"},
        headers=auth_header(token_b),
    )
    assert response.status_code == 404


@pytest.mark.asyncio
async def test_delete_time_log_then_repeat_is_404(client: AsyncClient) -> None:
    token = await register(client, "tl-delete@example.com")
    headers = auth_header(token)
    todo_id = await _make_todo(client, token)
    log_id = str(uuid4())

    create = await client.post(
        "/time_logs/",
        json={"id": log_id, "task_id": todo_id, "started_at": "2026-07-12T09:05:00.000Z"},
        headers=headers,
    )
    assert create.status_code == 201

    delete = await client.delete(f"/time_logs/{log_id}", headers=headers)
    assert delete.status_code == 204

    repeat = await client.delete(f"/time_logs/{log_id}", headers=headers)
    assert repeat.status_code == 404


# ── queue-order replay ────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_full_session_upload_replays_in_queue_order(client: AsyncClient) -> None:
    """AC: a queued focus-session mutation uploads without blocking sibling
    entries.  Replays the exact CRUD sequence a synced client queues for
    plan → focus → review (FocusSessionDao), interleaved with a sibling
    todos PATCH, and asserts every step succeeds — the true PowerSync queue
    is engine behaviour with no automated harness (docs/SYNC.md), so route
    permissiveness over the full sequence is what this locks in."""
    token = await register(client, "fs-queue@example.com")
    headers = auth_header(token)
    todo_a = await _make_todo(client, token, "Plan item A")
    todo_b = await _make_todo(client, token, "Plan item B")
    session_id = str(uuid4())
    fst_a = str(uuid4())
    fst_b = str(uuid4())
    log_id = str(uuid4())

    # openSession: session PUT, then one PUT per planned task.
    steps: list[tuple[str, str, dict[str, object]]] = [
        (
            "post",
            "/focus_sessions/",
            {"id": session_id, "started_at": "2026-07-12T09:00:00.000Z", "ended_at": None},
        ),
        (
            "post",
            "/focus_session_tasks/",
            {"id": fst_a, "focus_session_id": session_id, "task_id": todo_a, "position": 0},
        ),
        (
            "post",
            "/focus_session_tasks/",
            {"id": fst_b, "focus_session_id": session_id, "task_id": todo_b, "position": 1},
        ),
        # setCurrentTask: time-log PUT + session pointer PATCH.
        (
            "post",
            "/time_logs/",
            {
                "id": log_id,
                "task_id": todo_a,
                "started_at": "2026-07-12T09:01:00.000Z",
                "focus_session_id": session_id,
            },
        ),
        ("patch", f"/focus_sessions/{session_id}", {"current_task_id": todo_a}),
        # A sibling todos mutation queued mid-session must not be blocked.
        ("patch", f"/todos/{todo_a}", {"time_spent_minutes": 25}),
        # reviewAndCloseSession: dispositions, close the log, close the session.
        ("patch", f"/focus_session_tasks/{fst_a}", {"disposition": "rollover"}),
        ("patch", f"/focus_session_tasks/{fst_b}", {"disposition": "maybe"}),
        ("patch", f"/time_logs/{log_id}", {"ended_at": "2026-07-12T09:26:00.000Z"}),
        (
            "patch",
            f"/focus_sessions/{session_id}",
            {"ended_at": "2026-07-12T09:30:00.000Z", "current_task_id": None},
        ),
    ]
    for method, path, payload in steps:
        response = await getattr(client, method)(path, json=payload, headers=headers)
        assert response.status_code in (200, 201), (method, path, response.text)


# ── focus_session_dispositions (issue #418, ADR-0015) ─────────────────────────


async def _make_disposition(
    client: AsyncClient,
    token: str,
    session_id: str,
    task_id: str,
    fsd_id: str | None = None,
    disposition: str | None = "rollover",
) -> str:
    fsd_id = fsd_id or str(uuid4())
    resp = await client.post(
        "/focus_session_dispositions/",
        json={
            "id": fsd_id,
            "focus_session_id": session_id,
            "task_id": task_id,
            "disposition": disposition,
            "user_id": "spoofed-user-id",  # server-owned: must be ignored
        },
        headers=auth_header(token),
    )
    assert resp.status_code == 201, resp.text
    return fsd_id


@pytest.mark.asyncio
async def test_create_focus_session_disposition_connector_shaped_payload(
    client: AsyncClient, db: AsyncSession
) -> None:
    """The exact shape reviewAndCloseSession queues for an off-Plan Outcome:
    client id, composite (session, task) key, disposition, denormalized user_id
    (server-owned, ignored)."""
    token = await register(client, "fsd-create@example.com")
    session_id = await _make_session(client, token)
    todo_id = await _make_todo(client, token)
    fsd_id = str(uuid4())

    create = await client.post(
        "/focus_session_dispositions/",
        json={
            "id": fsd_id,
            "focus_session_id": session_id,
            "task_id": todo_id,
            "disposition": "rollover",
            "user_id": "spoofed-user-id",
        },
        headers=auth_header(token),
    )
    assert create.status_code == 201, create.text
    created = create.json()
    assert created["id"] == fsd_id
    assert created["focus_session_id"] == session_id
    assert created["task_id"] == todo_id
    assert created["disposition"] == "rollover"

    row = (
        await db.execute(
            select(FocusSessionDisposition).where(FocusSessionDisposition.id == fsd_id)
        )
    ).scalar_one()
    assert row.user_id == await _user_id_from(token)
    assert row.user_id != "spoofed-user-id"


@pytest.mark.asyncio
async def test_create_focus_session_disposition_replay_is_idempotent(
    client: AsyncClient, db: AsyncSession
) -> None:
    token = await register(client, "fsd-replay@example.com")
    session_id = await _make_session(client, token)
    todo_id = await _make_todo(client, token)
    payload = {
        "id": str(uuid4()),
        "focus_session_id": session_id,
        "task_id": todo_id,
        "disposition": "maybe",
    }

    first = await client.post(
        "/focus_session_dispositions/", json=payload, headers=auth_header(token)
    )
    assert first.status_code == 201
    retry = await client.post(
        "/focus_session_dispositions/", json=payload, headers=auth_header(token)
    )
    assert retry.status_code == 201

    rows = (
        (
            await db.execute(
                select(FocusSessionDisposition).where(
                    FocusSessionDisposition.focus_session_id == session_id,
                    FocusSessionDisposition.task_id == todo_id,
                )
            )
        )
        .scalars()
        .all()
    )
    assert len(rows) == 1


@pytest.mark.asyncio
async def test_create_focus_session_disposition_id_reuse_for_different_relation_is_409(
    client: AsyncClient,
) -> None:
    token = await register(client, "fsd-conflict@example.com")
    session_id = await _make_session(client, token)
    todo_a = await _make_todo(client, token, "A")
    todo_b = await _make_todo(client, token, "B")
    fsd_id = str(uuid4())

    first = await client.post(
        "/focus_session_dispositions/",
        json={"id": fsd_id, "focus_session_id": session_id, "task_id": todo_a},
        headers=auth_header(token),
    )
    assert first.status_code == 201

    conflict = await client.post(
        "/focus_session_dispositions/",
        json={"id": fsd_id, "focus_session_id": session_id, "task_id": todo_b},
        headers=auth_header(token),
    )
    assert conflict.status_code == 409


@pytest.mark.asyncio
async def test_create_focus_session_disposition_invalid_value_is_422(
    client: AsyncClient,
) -> None:
    """Garbage disposition must 422 at the schema, not trip the DB CHECK
    constraint (a 500 → infinite retry)."""
    token = await register(client, "fsd-check@example.com")
    session_id = await _make_session(client, token)
    todo_id = await _make_todo(client, token)

    resp = await client.post(
        "/focus_session_dispositions/",
        json={
            "id": str(uuid4()),
            "focus_session_id": session_id,
            "task_id": todo_id,
            "disposition": "shred",
        },
        headers=auth_header(token),
    )
    assert resp.status_code == 422


@pytest.mark.asyncio
async def test_create_focus_session_disposition_unowned_parents_are_404(
    client: AsyncClient,
) -> None:
    token = await register(client, "fsd-owner@example.com")
    other = await register(client, "fsd-other@example.com")
    my_session = await _make_session(client, token)
    my_todo = await _make_todo(client, token)
    other_session = await _make_session(client, other)
    other_todo = await _make_todo(client, other)

    for session_id, task_id in ((other_session, my_todo), (my_session, other_todo)):
        resp = await client.post(
            "/focus_session_dispositions/",
            json={
                "id": str(uuid4()),
                "focus_session_id": session_id,
                "task_id": task_id,
            },
            headers=auth_header(token),
        )
        assert resp.status_code == 404, (session_id, task_id)


@pytest.mark.asyncio
async def test_patch_focus_session_disposition_values(client: AsyncClient) -> None:
    token = await register(client, "fsd-patch@example.com")
    headers = auth_header(token)
    session_id = await _make_session(client, token)
    todo_id = await _make_todo(client, token)
    fsd_id = await _make_disposition(client, token, session_id, todo_id)

    for disposition in ("rollover", "leave", "maybe"):
        patch = await client.patch(
            f"/focus_session_dispositions/{fsd_id}",
            json={"disposition": disposition},
            headers=headers,
        )
        assert patch.status_code == 200, patch.text
        assert patch.json()["disposition"] == disposition

    garbage = await client.patch(
        f"/focus_session_dispositions/{fsd_id}",
        json={"disposition": "shred"},
        headers=headers,
    )
    assert garbage.status_code == 422


@pytest.mark.asyncio
async def test_patch_focus_session_disposition_other_user_is_404(
    client: AsyncClient,
) -> None:
    token_a = await register(client, "fsd-priv-a@example.com")
    token_b = await register(client, "fsd-priv-b@example.com")
    session_id = await _make_session(client, token_a)
    todo_id = await _make_todo(client, token_a)
    fsd_id = await _make_disposition(client, token_a, session_id, todo_id)

    resp = await client.patch(
        f"/focus_session_dispositions/{fsd_id}",
        json={"disposition": "leave"},
        headers=auth_header(token_b),
    )
    assert resp.status_code == 404


@pytest.mark.asyncio
async def test_delete_focus_session_disposition(client: AsyncClient) -> None:
    token = await register(client, "fsd-delete@example.com")
    headers = auth_header(token)
    session_id = await _make_session(client, token)
    todo_id = await _make_todo(client, token)
    fsd_id = await _make_disposition(client, token, session_id, todo_id)

    first = await client.delete(f"/focus_session_dispositions/{fsd_id}", headers=headers)
    assert first.status_code == 204
    # Idempotent delete: the row is already gone.
    second = await client.delete(f"/focus_session_dispositions/{fsd_id}", headers=headers)
    assert second.status_code == 404


@pytest.mark.asyncio
async def test_delete_focus_session_clears_disposition_children(
    client: AsyncClient, db: AsyncSession
) -> None:
    """DELETE /focus_sessions/{id} must clear focus_session_dispositions rows
    itself — the FK has no ON DELETE CASCADE, so a Postgres FK violation would
    500 and wedge the CRUD queue."""
    token = await register(client, "fsd-cascade@example.com")
    session_id = await _make_session(client, token)
    todo_id = await _make_todo(client, token)
    await _make_disposition(client, token, session_id, todo_id)

    resp = await client.delete(f"/focus_sessions/{session_id}", headers=auth_header(token))
    assert resp.status_code == 204

    rows = (
        (
            await db.execute(
                select(FocusSessionDisposition).where(
                    FocusSessionDisposition.focus_session_id == session_id
                )
            )
        )
        .scalars()
        .all()
    )
    assert rows == []
