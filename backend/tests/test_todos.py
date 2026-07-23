from datetime import datetime
from uuid import uuid4

import jwt
import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.todos.models import Tag, Todo, TodoTag
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
async def test_create_replay_converges_client_state(client: AsyncClient, db: AsyncSession) -> None:
    """Upsert-on-replay (ADR-0015): a consolidated replay carrying newer
    client-owned values converges the server row instead of reverting the
    offline edit one checkpoint later.  Omitted fields stay untouched (the
    #380 guard), and tag-set convergence flows through todo_tags, not here."""
    token = await register(client, "replay-converge@example.com")
    headers = auth_header(token)
    todo_id = str(uuid4())

    first = await client.post(
        "/todos/",
        json={
            "id": todo_id,
            "title": "Inbox capture",
            "clarified": False,
            "notes": "original",
            "tags": ["@office"],
        },
        headers=headers,
    )
    assert first.status_code == 201
    assert {t["name"] for t in first.json()["tags"]} == {"@office"}

    # Replay carries newer client-owned scalars (title/clarified/energy_level)
    # but omits notes and tags — the omitted values must survive.
    replay = await client.post(
        "/todos/",
        json={
            "id": todo_id,
            "title": "Clarified capture",
            "clarified": True,
            "energy_level": "high",
        },
        headers=headers,
    )
    assert replay.status_code == 201
    body = replay.json()
    assert body["id"] == todo_id
    assert body["title"] == "Clarified capture"
    assert body["clarified"] is True
    assert body["energy_level"] == "high"
    # Omitted fields are left untouched.
    assert body["notes"] == "original"
    assert {t["name"] for t in body["tags"]} == {"@office"}

    # Assert the persisted row and junction rows converged — not just the
    # response payload.
    row = (await db.execute(select(Todo).where(Todo.id == todo_id))).scalar_one()
    assert row.title == "Clarified capture"
    assert row.clarified is True
    assert row.energy_level == "high"
    assert row.notes == "original"
    tag_ids = (
        (await db.execute(select(TodoTag.tag_id).where(TodoTag.todo_id == todo_id))).scalars().all()
    )
    assert set(tag_ids) == {tag["id"] for tag in first.json()["tags"]}


@pytest.mark.asyncio
async def test_create_tag_replay_converges_and_cross_user_conflicts(
    client: AsyncClient, db: AsyncSession
) -> None:
    """Upsert-on-replay (ADR-0015) for tags: a same-user id replay carrying a
    newer name/color converges the stored row; a cross-user id collision 409s."""
    token = await register(client, "tag-replay@example.com")
    headers = auth_header(token)
    tag_id = str(uuid4())

    first = await client.post(
        "/tags/",
        json={"id": tag_id, "name": "office", "type": "context", "color": "#111"},
        headers=headers,
    )
    assert first.status_code == 201

    replay = await client.post(
        "/tags/",
        json={"id": tag_id, "name": "workspace", "type": "context", "color": "#222"},
        headers=headers,
    )
    assert replay.status_code == 201
    assert replay.json()["name"] == "workspace"
    assert replay.json()["color"] == "#222"
    row = (await db.execute(select(Tag).where(Tag.id == tag_id))).scalar_one()
    assert row.name == "workspace"
    assert row.color == "#222"

    other = await register(client, "tag-replay-other@example.com")
    conflict = await client.post(
        "/tags/",
        json={"id": tag_id, "name": "theirs", "type": "context"},
        headers=auth_header(other),
    )
    assert conflict.status_code == 409


@pytest.mark.asyncio
async def test_create_todo_same_id_across_users_is_409(client: AsyncClient) -> None:
    """A same-id collision across users is a genuine anomaly, not a replay — the
    todo route 409s like the other create routes rather than falling through to
    a duplicate-PK insert (500 → infinite connector retry)."""
    token_a = await register(client, "todo-xuser-a@example.com")
    token_b = await register(client, "todo-xuser-b@example.com")
    todo_id = str(uuid4())
    body = {"id": todo_id, "title": "Mine"}
    first = await client.post("/todos/", json=body, headers=auth_header(token_a))
    assert first.status_code == 201
    conflict = await client.post("/todos/", json=body, headers=auth_header(token_b))
    assert conflict.status_code == 409


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
@pytest.mark.parametrize("field", ["title", "intent", "time_spent_minutes"])
async def test_patch_explicit_null_not_null_columns_is_422(client: AsyncClient, field: str) -> None:
    """title, intent, and time_spent_minutes are NOT NULL in the DB: an
    explicit null in the PATCH body must be rejected at validation (422),
    not surface as a commit-time IntegrityError (500).  Same shape as the
    clarified fix from #380; survey-and-fix tracked in #387."""
    token = await register(client, f"not-null-{field}@example.com")
    headers = auth_header(token)

    create = await client.post(
        "/todos/",
        json={"title": "Known title", "intent": "maybe", "time_spent_minutes": 5},
        headers=headers,
    )
    assert create.status_code == 201
    todo_id = create.json()["id"]

    null_patch = await client.patch(f"/todos/{todo_id}", json={field: None}, headers=headers)
    assert null_patch.status_code == 422

    fetched = (await client.get(f"/todos/{todo_id}", headers=headers)).json()
    assert fetched["title"] == "Known title"
    assert fetched["intent"] == "maybe"
    assert fetched["time_spent_minutes"] == 5


@pytest.mark.asyncio
async def test_patch_omitting_not_null_columns_leaves_them_unchanged(client: AsyncClient) -> None:
    """Omission must keep meaning "no update": the null-rejecting validators
    are mode="before", which Pydantic skips for unset fields, so a PATCH
    touching an unrelated field leaves every NOT NULL column intact."""
    token = await register(client, "not-null-omit@example.com")
    headers = auth_header(token)

    create = await client.post(
        "/todos/",
        json={
            "title": "Known title",
            "intent": "maybe",
            "time_spent_minutes": 5,
            "clarified": False,
        },
        headers=headers,
    )
    todo_id = create.json()["id"]

    patch = await client.patch(f"/todos/{todo_id}", json={"notes": "unrelated"}, headers=headers)
    assert patch.status_code == 200

    fetched = (await client.get(f"/todos/{todo_id}", headers=headers)).json()
    assert fetched["notes"] == "unrelated"
    assert fetched["title"] == "Known title"
    assert fetched["intent"] == "maybe"
    assert fetched["time_spent_minutes"] == 5
    assert fetched["clarified"] is False


@pytest.mark.asyncio
@pytest.mark.parametrize("field", ["name", "type"])
async def test_patch_tag_explicit_null_is_422(
    client: AsyncClient, db: AsyncSession, field: str
) -> None:
    """tags.name and tags.type are NOT NULL: explicit null on PATCH is a 422
    and leaves the row unchanged.  There is no GET /tags/{id} endpoint, so the
    row is checked directly via the session."""
    token = await register(client, f"tag-null-{field}@example.com")
    headers = auth_header(token)

    create = await client.post(
        "/tags/",
        json={"name": "errands", "type": "context", "color": "#ff0000"},
        headers=headers,
    )
    assert create.status_code == 201
    tag_id = create.json()["id"]

    null_patch = await client.patch(f"/tags/{tag_id}", json={field: None}, headers=headers)
    assert null_patch.status_code == 422

    tag = await db.get(Tag, tag_id)
    assert tag is not None
    assert tag.name == "errands"
    assert tag.type == "context"


@pytest.mark.asyncio
async def test_patch_tag_null_color_clears_it(client: AsyncClient) -> None:
    """tags.color is nullable: null on PATCH stays a legitimate "clear this
    value" and leaves the NOT NULL columns untouched."""
    token = await register(client, "tag-null-color@example.com")
    headers = auth_header(token)

    create = await client.post(
        "/tags/",
        json={"name": "errands", "type": "context", "color": "#ff0000"},
        headers=headers,
    )
    assert create.status_code == 201
    tag_id = create.json()["id"]

    clear_color = await client.patch(f"/tags/{tag_id}", json={"color": None}, headers=headers)
    assert clear_color.status_code == 200
    cleared = clear_color.json()
    assert cleared["color"] is None
    assert cleared["name"] == "errands"
    assert cleared["type"] == "context"


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
