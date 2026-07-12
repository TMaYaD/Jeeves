from datetime import datetime
from uuid import uuid4

import jwt
import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.todos.models import Todo, TodoTag
from tests.conftest import auth_header, register


@pytest.mark.asyncio
async def test_list_todos_requires_auth(client: AsyncClient) -> None:
    response = await client.get("/todos/")
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_create_todo_requires_auth(client: AsyncClient) -> None:
    response = await client.post("/todos/", json={"title": "Buy milk"})
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_create_and_list_todos_with_valid_token(client: AsyncClient) -> None:
    token = await register(client, "grace@example.com")
    create_response = await client.post(
        "/todos/", json={"title": "Buy milk"}, headers=auth_header(token)
    )
    assert create_response.status_code == 201

    list_response = await client.get("/todos/", headers=auth_header(token))
    assert list_response.status_code == 200
    todos = list_response.json()
    assert len(todos) == 1
    assert todos[0]["title"] == "Buy milk"


@pytest.mark.asyncio
async def test_user_cannot_access_another_users_todo(client: AsyncClient) -> None:
    token_a = await register(client, "henry@example.com")
    token_b = await register(client, "iris@example.com")

    create_response = await client.post(
        "/todos/", json={"title": "Henry's private todo"}, headers=auth_header(token_a)
    )
    todo_id = create_response.json()["id"]

    response = await client.get(f"/todos/{todo_id}", headers=auth_header(token_b))
    assert response.status_code == 404


# ── GTD integration tests ─────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_gtd_fields_roundtrip(client: AsyncClient) -> None:
    """time_estimate, energy_level, and capture_source survive create → update → get."""
    token = await register(client, "gtd-roundtrip@example.com")
    headers = auth_header(token)

    create = await client.post(
        "/todos/",
        json={
            "title": "Plan sprint",
            "state": "next_action",
            "energy_level": "high",
            "time_estimate": 60,
            "capture_source": "manual",
        },
        headers=headers,
    )
    assert create.status_code == 201
    todo = create.json()
    todo_id = todo["id"]
    assert todo["energy_level"] == "high"
    assert todo["time_estimate"] == 60
    assert todo["capture_source"] == "manual"
    assert todo["state"] == "next_action"

    # Update GTD fields
    patch = await client.patch(
        f"/todos/{todo_id}",
        json={"state": "next_action", "energy_level": "medium", "time_estimate": 30},
        headers=headers,
    )
    assert patch.status_code == 200
    updated = patch.json()
    assert updated["state"] == "next_action"
    assert updated["energy_level"] == "medium"
    assert updated["time_estimate"] == 30

    # Verify via GET
    get = await client.get(f"/todos/{todo_id}", headers=headers)
    assert get.status_code == 200
    fetched = get.json()
    assert fetched["energy_level"] == "medium"
    assert fetched["time_estimate"] == 30
    assert fetched["capture_source"] == "manual"


@pytest.mark.asyncio
async def test_tag_type_filter(client: AsyncClient) -> None:
    """GET /todos/?tag_type=context returns only todos with context tags."""
    token = await register(client, "tag-filter@example.com")
    headers = auth_header(token)

    # Create todo with a context tag
    ctx_todo = await client.post(
        "/todos/",
        json={"title": "Context todo", "tags": ["@office"]},
        headers=headers,
    )
    assert ctx_todo.status_code == 201
    ctx_id = ctx_todo.json()["id"]

    # Create todo with a project tag
    proj_todo = await client.post(
        "/todos/",
        json={
            "title": "Project todo",
            "tags": [{"name": "Renovation", "type": "project"}],
        },
        headers=headers,
    )
    assert proj_todo.status_code == 201

    # Create todo with no tags
    await client.post("/todos/", json={"title": "Untagged todo"}, headers=headers)

    # Filter by context
    ctx_resp = await client.get("/todos/?tag_type=context", headers=headers)
    assert ctx_resp.status_code == 200
    ctx_ids = [t["id"] for t in ctx_resp.json()]
    assert ctx_id in ctx_ids
    for t in ctx_resp.json():
        assert any(tag["type"] == "context" for tag in t["tags"])

    # Filter by project
    proj_resp = await client.get("/todos/?tag_type=project", headers=headers)
    assert proj_resp.status_code == 200
    proj_ids = [t["id"] for t in proj_resp.json()]
    assert ctx_id not in proj_ids
    for t in proj_resp.json():
        assert any(tag["type"] == "project" for tag in t["tags"])


@pytest.mark.asyncio
async def test_tag_type_in_response(client: AsyncClient) -> None:
    """Tags in TodoOut include the type field."""
    token = await register(client, "tag-type-out@example.com")
    headers = auth_header(token)

    create = await client.post(
        "/todos/",
        json={
            "title": "Tagged todo",
            "tags": [
                "@home",
                {"name": "Garden", "type": "project"},
                {"name": "Outdoors", "type": "area"},
                "urgent",
            ],
        },
        headers=headers,
    )
    assert create.status_code == 201
    tags = {t["name"]: t["type"] for t in create.json()["tags"]}
    assert tags["@home"] == "context"
    assert tags["Garden"] == "project"
    assert tags["Outdoors"] == "area"
    assert tags["urgent"] == "label"


@pytest.mark.asyncio
async def test_project_isolation(client: AsyncClient) -> None:
    """User A's project tags are not visible to user B."""
    token_a = await register(client, "proj-alice@example.com")
    token_b = await register(client, "proj-bob@example.com")

    await client.post(
        "/todos/",
        json={"title": "Alice task", "tags": [{"name": "AliceProject", "type": "project"}]},
        headers=auth_header(token_a),
    )

    # Bob queries by project tag — must see nothing
    bob_resp = await client.get(
        "/todos/?tag_type=project&tag_name=AliceProject",
        headers=auth_header(token_b),
    )
    assert bob_resp.status_code == 200
    assert bob_resp.json() == []


@pytest.mark.asyncio
async def test_invalid_state_returns_422(client: AsyncClient) -> None:
    token = await register(client, "invalid-state@example.com")
    resp = await client.post(
        "/todos/",
        json={"title": "Bad state", "state": "not_a_state"},
        headers=auth_header(token),
    )
    assert resp.status_code == 422


@pytest.mark.asyncio
async def test_invalid_energy_level_returns_422(client: AsyncClient) -> None:
    token = await register(client, "invalid-energy@example.com")
    resp = await client.post(
        "/todos/",
        json={"title": "Bad energy", "energy_level": "turbo"},
        headers=auth_header(token),
    )
    assert resp.status_code == 422


# ── todo_tags.user_id denormalization (migration 0008) ────────────────────────


@pytest.mark.asyncio
async def test_todo_tags_user_id_populated_on_all_write_paths(
    client: AsyncClient, db: AsyncSession
) -> None:
    """Every junction row must carry user_id regardless of which write path
    created it.  Covers the ORM-cascade path (POST /todos/ with tags, PATCH
    /todos/{id} with tags — both exercising the before_flush listener) and
    the explicit endpoint (POST /todo_tags/ which sets user_id directly)."""
    token = await register(client, "junction-user@example.com")
    payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
    user_id = payload["sub"]

    # Path 1: POST /todos/ with tags — ORM cascade.
    create = await client.post(
        "/todos/",
        json={"title": "Path 1", "tags": ["@home"]},
        headers=auth_header(token),
    )
    assert create.status_code == 201
    todo_id = create.json()["id"]

    # Path 2: PATCH /todos/{id} with replacement tags — ORM cascade again.
    patch = await client.patch(
        f"/todos/{todo_id}",
        json={"tags": ["@office", "urgent"]},
        headers=auth_header(token),
    )
    assert patch.status_code == 200

    # Path 3: POST /todo_tags/ — explicit endpoint.  First create a fresh tag
    # to attach so we're exercising the idempotency-free branch.
    tag_resp = await client.post(
        "/tags/",
        json={"name": "next", "type": "label"},
        headers=auth_header(token),
    )
    assert tag_resp.status_code == 201
    tag_id = tag_resp.json()["id"]
    attach = await client.post(
        "/todo_tags/",
        json={"todo_id": todo_id, "tag_id": tag_id},
        headers=auth_header(token),
    )
    assert attach.status_code == 201

    # Assert: every junction row on this todo has the correct user_id.
    rows = (await db.execute(select(TodoTag).where(TodoTag.todo_id == todo_id))).scalars().all()
    assert len(rows) >= 1  # PATCH replaced the original set; at least the new tag + the 2 patched
    for row in rows:
        assert row.user_id == user_id, f"junction row {row.todo_id},{row.tag_id} has wrong user_id"


# ── Sync fidelity: client-state columns round-trip (issue #380) ────────────────


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


@pytest.mark.asyncio
async def test_create_persists_clarified_false(client: AsyncClient) -> None:
    """POST /todos/ must persist a client-supplied clarified=false.  Before
    #380 the field was silently dropped, the model default (true) won, and
    the next sync checkpoint flipped the local row — the capture vanished
    from the Inbox while staying searchable."""
    token = await register(client, "clarified-false@example.com")
    headers = auth_header(token)

    create = await client.post(
        "/todos/",
        json={"title": "Inbox capture", "clarified": False},
        headers=headers,
    )
    assert create.status_code == 201, create.text
    assert create.json()["clarified"] is False

    get = await client.get(f"/todos/{create.json()['id']}", headers=headers)
    assert get.status_code == 200
    assert get.json()["clarified"] is False


@pytest.mark.asyncio
async def test_create_accepts_sqlite_integer_clarified(client: AsyncClient) -> None:
    """PowerSync opData carries booleans as SQLite integers (0/1) — the exact
    shape a connector PUT uploads.  The schema must coerce them, not 422 (a
    422 would poison the CRUD queue via the #305 fatal-drop path)."""
    token = await register(client, "clarified-int@example.com")
    headers = auth_header(token)

    create = await client.post(
        "/todos/",
        json={"title": "Integer-boolean capture", "clarified": 0},
        headers=headers,
    )
    assert create.status_code == 201, create.text
    assert create.json()["clarified"] is False


@pytest.mark.asyncio
async def test_create_defaults_clarified_true(client: AsyncClient) -> None:
    """Omitting clarified keeps REST semantics: an API-created todo is born
    clarified (Inbox membership is an explicit client decision)."""
    token = await register(client, "clarified-default@example.com")
    headers = auth_header(token)

    create = await client.post("/todos/", json={"title": "Plain REST"}, headers=headers)
    assert create.status_code == 201
    assert create.json()["clarified"] is True


@pytest.mark.asyncio
async def test_create_idempotent_retry_keeps_clarified(client: AsyncClient) -> None:
    """A retried POST with the same client id returns the existing row with
    its original clarified value.  The retry omits clarified entirely — if
    the server created a fresh row instead of deduplicating, the schema
    default (true) would leak through and fail the assertion."""
    token = await register(client, "clarified-retry@example.com")
    headers = auth_header(token)
    todo_id = str(uuid4())

    first = await client.post(
        "/todos/",
        json={"id": todo_id, "title": "Inbox capture", "clarified": False},
        headers=headers,
    )
    assert first.status_code == 201

    retry = await client.post(
        "/todos/", json={"id": todo_id, "title": "Inbox capture"}, headers=headers
    )
    assert retry.status_code == 201
    assert retry.json()["id"] == todo_id
    assert retry.json()["clarified"] is False


@pytest.mark.asyncio
async def test_patch_clarified_roundtrip(client: AsyncClient) -> None:
    """PATCH must persist clarified in both directions: false→true is the
    clarify flow; true→false is move-back-to-Inbox.  Dropping it on PATCH
    would be the inverse of #380 — a clarified task bouncing back into the
    Inbox on the next checkpoint."""
    token = await register(client, "clarified-patch@example.com")
    headers = auth_header(token)

    create = await client.post(
        "/todos/",
        json={"title": "Inbox capture", "clarified": False},
        headers=headers,
    )
    todo_id = create.json()["id"]

    clarify = await client.patch(f"/todos/{todo_id}", json={"clarified": True}, headers=headers)
    assert clarify.status_code == 200
    assert clarify.json()["clarified"] is True

    back_to_inbox = await client.patch(
        f"/todos/{todo_id}", json={"clarified": False}, headers=headers
    )
    assert back_to_inbox.status_code == 200
    assert back_to_inbox.json()["clarified"] is False

    get = await client.get(f"/todos/{todo_id}", headers=headers)
    assert get.json()["clarified"] is False


@pytest.mark.asyncio
async def test_patch_explicit_null_clarified_is_422(client: AsyncClient) -> None:
    """clarified is NOT NULL in the DB: PATCH {"clarified": null} must be
    rejected at validation (422), not surface as a commit-time
    IntegrityError.  Omitting the field entirely remains "no update"."""
    token = await register(client, "clarified-null@example.com")
    headers = auth_header(token)

    create = await client.post(
        "/todos/",
        json={"title": "Inbox capture", "clarified": False},
        headers=headers,
    )
    todo_id = create.json()["id"]

    null_patch = await client.patch(f"/todos/{todo_id}", json={"clarified": None}, headers=headers)
    assert null_patch.status_code == 422

    get = await client.get(f"/todos/{todo_id}", headers=headers)
    assert get.json()["clarified"] is False


@pytest.mark.asyncio
async def test_connector_shaped_payload_roundtrips_client_state(
    client: AsyncClient, db: AsyncSession
) -> None:
    """Standing tripwire for the #380 audit: a POST shaped exactly like a
    PowerSync connector PUT — every client-state column, SQLite integer
    booleans, Drift space-before-offset timestamps — must persist verbatim.
    Any column silently dropped here defaults on the server and gets
    replicated back over the local value on the next checkpoint download.
    When adding a column to the Drift Todos table, add it to TodoCreate,
    TodoUpdate, and this payload (see docs/SYNC.md § todos upload contract)."""
    token = await register(client, "connector-put@example.com")
    headers = auth_header(token)
    todo_id = str(uuid4())

    payload = {
        "id": todo_id,
        "title": "Connector-shaped capture",
        "notes": "raw note",
        "priority": 2,
        "due_date": "2026-07-20T00:00:00.000 +05:30",
        "created_at": "2026-07-10T09:15:00.000 +05:30",
        "updated_at": "2026-07-11T18:30:00.000Z",
        "done_at": None,
        "clarified": 0,
        "intent": "maybe",
        "time_estimate": 15,
        "energy_level": "low",
        "capture_source": "share_sheet",
        "location_id": None,
        "user_id": "spoofed-user-id",  # server-owned: must be ignored
        "last_clarified_at": "2026-07-11T18:30:00.000Z",
        "time_spent_minutes": 5,
        "next_action_text": "Sort into a project",
        "last_next_action_completion_at": "2026-07-09T12:00:00.000 +05:30",
    }
    create = await client.post("/todos/", json=payload, headers=headers)
    assert create.status_code == 201, create.text
    created = create.json()

    # A field silently dropped by the schema surfaces on the create response
    # as the server default.
    _assert_instant(created["due_date"], "2026-07-20T00:00:00+05:30")
    _assert_instant(created["created_at"], "2026-07-10T09:15:00+05:30")
    _assert_instant(created["updated_at"], "2026-07-11T18:30:00+00:00")
    _assert_instant(created["last_clarified_at"], "2026-07-11T18:30:00+00:00")
    _assert_instant(created["last_next_action_completion_at"], "2026-07-09T12:00:00+05:30")

    # Re-read via GET: all client state must survive a real DB round-trip.
    get = await client.get(f"/todos/{todo_id}", headers=headers)
    assert get.status_code == 200
    fetched = get.json()

    assert fetched["title"] == "Connector-shaped capture"
    assert fetched["notes"] == "raw note"
    assert fetched["priority"] == 2
    assert fetched["done_at"] is None
    assert fetched["clarified"] is False
    assert fetched["intent"] == "maybe"
    assert fetched["time_estimate"] == 15
    assert fetched["energy_level"] == "low"
    assert fetched["capture_source"] == "share_sheet"
    assert fetched["time_spent_minutes"] == 5
    assert fetched["next_action_text"] == "Sort into a project"
    _assert_instant(fetched["due_date"], "2026-07-20T00:00:00+05:30")
    _assert_instant(fetched["created_at"], "2026-07-10T09:15:00+05:30")
    _assert_instant(fetched["updated_at"], "2026-07-11T18:30:00+00:00")
    _assert_instant(fetched["last_clarified_at"], "2026-07-11T18:30:00+00:00")
    _assert_instant(fetched["last_next_action_completion_at"], "2026-07-09T12:00:00+05:30")

    # Ownership comes from the JWT, not the payload's spoofed user_id; the
    # unused location_id stays NULL.  Asserted straight off the DB row since
    # TodoOut exposes neither column.
    claims = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
    row = (await db.execute(select(Todo).where(Todo.id == todo_id))).scalar_one()
    assert row.user_id == claims["sub"]
    assert row.user_id != "spoofed-user-id"
    assert row.location_id is None
