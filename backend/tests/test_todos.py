import jwt
import pytest
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.todos.models import TodoTag
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
