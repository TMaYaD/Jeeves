"""End-to-end tests covering complete user journeys."""

from datetime import datetime

import pytest
from httpx import AsyncClient

from tests.conftest import auth_header


@pytest.mark.asyncio
async def test_full_user_journey(client: AsyncClient) -> None:
    """Register -> login -> create todos -> list -> update -> delete -> verify."""

    # 1. Register
    reg = await client.post("/user", json={"email": "journey@example.com", "password": "s3cret"})
    assert reg.status_code == 201
    token = reg.json()["access_token"]
    headers = auth_header(token)

    # 2. Login with same credentials
    login = await client.post(
        "/session", json={"email": "journey@example.com", "password": "s3cret"}
    )
    assert login.status_code == 200
    login_token = login.json()["access_token"]
    login_headers = auth_header(login_token)

    # 3. View profile using login token
    profile = await client.get("/user", headers=login_headers)
    assert profile.status_code == 200
    assert profile.json()["email"] == "journey@example.com"

    # 4. Create two todos
    todo1 = await client.post("/todos/", json={"title": "Buy groceries"}, headers=headers)
    assert todo1.status_code == 201
    todo1_id = todo1.json()["id"]

    todo2 = await client.post(
        "/todos/", json={"title": "Walk the dog", "priority": 1}, headers=headers
    )
    assert todo2.status_code == 201

    # 5. List todos — should see both
    listing = await client.get("/todos/", headers=headers)
    assert listing.status_code == 200
    assert len(listing.json()) == 2

    # 6. Update first todo as completed
    done_at_sent = "2026-01-01T00:00:00Z"
    update = await client.patch(
        f"/todos/{todo1_id}", json={"done_at": done_at_sent}, headers=headers
    )
    assert update.status_code == 200
    returned_done_at = update.json()["done_at"]
    assert datetime.fromisoformat(returned_done_at) == datetime.fromisoformat(done_at_sent)

    # 7. Delete second todo
    todo2_id = todo2.json()["id"]
    delete = await client.delete(f"/todos/{todo2_id}", headers=headers)
    assert delete.status_code == 204

    # 8. Verify only one todo remains
    remaining = await client.get("/todos/", headers=headers)
    assert len(remaining.json()) == 1
    assert remaining.json()[0]["id"] == todo1_id

    # 9. Logout
    logout = await client.delete("/session", headers=headers)
    assert logout.status_code == 200


@pytest.mark.asyncio
async def test_multi_user_isolation(client: AsyncClient) -> None:
    """Two users cannot see or modify each other's data."""

    # Register two users
    reg_a = await client.post(
        "/user", json={"email": "alice-e2e@example.com", "password": "secret"}
    )
    reg_b = await client.post("/user", json={"email": "bob-e2e@example.com", "password": "secret"})
    headers_a = auth_header(reg_a.json()["access_token"])
    headers_b = auth_header(reg_b.json()["access_token"])

    # Alice creates a todo
    todo = await client.post("/todos/", json={"title": "Alice only"}, headers=headers_a)
    todo_id = todo.json()["id"]

    # Bob cannot read it
    get_resp = await client.get(f"/todos/{todo_id}", headers=headers_b)
    assert get_resp.status_code == 404

    # Bob cannot update it
    patch_resp = await client.patch(
        f"/todos/{todo_id}", json={"title": "Hacked"}, headers=headers_b
    )
    assert patch_resp.status_code == 404

    # Bob cannot delete it
    del_resp = await client.delete(f"/todos/{todo_id}", headers=headers_b)
    assert del_resp.status_code == 404

    # Bob's todo list is empty
    bob_list = await client.get("/todos/", headers=headers_b)
    assert bob_list.json() == []

    # Alice still sees her todo
    alice_list = await client.get("/todos/", headers=headers_a)
    assert len(alice_list.json()) == 1


# ── GTD E2E tests ─────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_gtd_inbox_capture_and_process(client: AsyncClient) -> None:
    """Capture a todo into inbox, enrich it, attach a project tag, then process it."""
    reg = await client.post("/user", json={"email": "gtd-inbox@example.com", "password": "secret"})
    headers = auth_header(reg.json()["access_token"])

    # 1. Capture as next_action (inbox is Flutter-only via clarified column)
    create = await client.post(
        "/todos/",
        json={"title": "Buy paint", "state": "next_action", "capture_source": "manual"},
        headers=headers,
    )
    assert create.status_code == 201
    todo = create.json()
    todo_id = todo["id"]
    assert todo["state"] == "next_action"
    assert todo["capture_source"] == "manual"
    assert todo["energy_level"] is None
    assert todo["time_estimate"] is None

    # 2. Enrich with GTD fields
    patch = await client.patch(
        f"/todos/{todo_id}",
        json={
            "energy_level": "medium",
            "time_estimate": 30,
            "state": "next_action",
            "tags": [{"name": "HomeReno", "type": "project"}],
        },
        headers=headers,
    )
    assert patch.status_code == 200
    enriched = patch.json()
    assert enriched["state"] == "next_action"
    assert enriched["energy_level"] == "medium"
    assert enriched["time_estimate"] == 30

    project_tags = [t for t in enriched["tags"] if t["type"] == "project"]
    assert len(project_tags) == 1
    assert project_tags[0]["name"] == "HomeReno"

    # 3. Verify via GET
    get = await client.get(f"/todos/{todo_id}", headers=headers)
    assert get.status_code == 200
    fetched = get.json()
    assert fetched["capture_source"] == "manual"
    assert fetched["state"] == "next_action"
    assert any(t["name"] == "HomeReno" and t["type"] == "project" for t in fetched["tags"])


@pytest.mark.asyncio
async def test_project_tag_single_assignment(client: AsyncClient) -> None:
    """Assigning two project tags to the same todo is rejected with 422."""
    reg = await client.post(
        "/user", json={"email": "single-proj@example.com", "password": "secret"}
    )
    headers = auth_header(reg.json()["access_token"])

    resp = await client.post(
        "/todos/",
        json={
            "title": "Ambiguous task",
            "tags": [
                {"name": "ProjectAlpha", "type": "project"},
                {"name": "ProjectBeta", "type": "project"},
            ],
        },
        headers=headers,
    )
    assert resp.status_code == 422
    assert "project" in resp.json()["detail"].lower()


@pytest.mark.asyncio
async def test_gtd_tag_types(client: AsyncClient) -> None:
    """A todo can have tags of all four types; GET returns each with correct type."""
    reg = await client.post(
        "/user", json={"email": "all-tag-types@example.com", "password": "secret"}
    )
    headers = auth_header(reg.json()["access_token"])

    create = await client.post(
        "/todos/",
        json={
            "title": "Multi-type task",
            "tags": [
                "@office",
                {"name": "Renovation", "type": "project"},
                {"name": "Home", "type": "area"},
                "urgent",
            ],
        },
        headers=headers,
    )
    assert create.status_code == 201
    tags_by_name = {t["name"]: t["type"] for t in create.json()["tags"]}

    assert tags_by_name["@office"] == "context"
    assert tags_by_name["Renovation"] == "project"
    assert tags_by_name["Home"] == "area"
    assert tags_by_name["urgent"] == "label"

    # Verify via separate GET
    get = await client.get(f"/todos/{create.json()['id']}", headers=headers)
    assert get.status_code == 200
    fetched_tags = {t["name"]: t["type"] for t in get.json()["tags"]}
    assert fetched_tags == tags_by_name


@pytest.mark.asyncio
async def test_capture_source_tracking(client: AsyncClient) -> None:
    """Todos created with different capture sources are stored and returned correctly."""
    reg = await client.post(
        "/user", json={"email": "capture-src@example.com", "password": "secret"}
    )
    headers = auth_header(reg.json()["access_token"])

    sources = ["manual", "share_sheet", "voice", "ai_parse"]
    created_ids: list[str] = []
    for source in sources:
        resp = await client.post(
            "/todos/",
            json={"title": f"Task via {source}", "capture_source": source},
            headers=headers,
        )
        assert resp.status_code == 201
        assert resp.json()["capture_source"] == source
        created_ids.append(resp.json()["id"])

    # All appear in the list
    listing = await client.get("/todos/", headers=headers)
    assert listing.status_code == 200
    listed_sources = {t["id"]: t["capture_source"] for t in listing.json()}
    for todo_id, source in zip(created_ids, sources, strict=False):
        assert listed_sources[todo_id] == source


@pytest.mark.asyncio
async def test_due_date_accepts_drift_local_tz_format(client: AsyncClient) -> None:
    """PowerSync uploads due_date in Drift's local-tz format with a space
    before the offset (e.g. '2026-04-30T00:00:00.000 +05:30').  That format
    is non-standard ISO 8601 but is what Drift produces when
    `storeDateTimeAsText` is enabled and the DateTime is local.  We must
    accept it — otherwise PowerSync's CRUD queue gets stuck retrying a
    poisoned PATCH and the sync indicator goes red."""
    reg = await client.post("/user", json={"email": "due-date@example.com", "password": "s3cret"})
    headers = auth_header(reg.json()["access_token"])

    create = await client.post("/todos/", json={"title": "Reschedule me"}, headers=headers)
    todo_id = create.json()["id"]

    drift_format = "2026-04-30T00:00:00.000 +05:30"
    expected_instant = datetime.fromisoformat("2026-04-30T00:00:00+05:30")
    patch = await client.patch(
        f"/todos/{todo_id}", json={"due_date": drift_format}, headers=headers
    )
    assert patch.status_code == 200, patch.text
    assert datetime.fromisoformat(patch.json()["due_date"]) == expected_instant

    # POST should also accept it.
    posted = await client.post(
        "/todos/", json={"title": "Plan now", "due_date": drift_format}, headers=headers
    )
    assert posted.status_code == 201, posted.text
    assert datetime.fromisoformat(posted.json()["due_date"]) == expected_instant
