"""Tests for the Nirvana import pipeline."""

from pathlib import Path

import pytest
from httpx import AsyncClient

from app.import_nirvana.parser import parse_csv, parse_json
from tests.conftest import auth_header, register

FIXTURES = Path(__file__).parent / "fixtures"


# ---------------------------------------------------------------------------
# Parser unit tests — no DB required
# ---------------------------------------------------------------------------


def _csv_fixture() -> str:
    return (FIXTURES / "nirvana_sample.csv").read_text()


def _json_fixture() -> str:
    return (FIXTURES / "nirvana_sample.json").read_text()


def test_parse_csv_tasks():
    items, _ = parse_csv(_csv_fixture())
    tasks = [i for i in items if i.type == "task"]
    assert len(tasks) == 4
    titles = {t.name for t in tasks}
    assert "On a computer? click the note →" in titles
    assert "Read the Book" in titles
    assert "Read our Quick Guide" in titles


def test_parse_csv_projects_become_tags():
    items, _ = parse_csv(_csv_fixture())
    projects = [i for i in items if i.type == "project"]
    assert len(projects) == 1
    assert projects[0].name == "Brush up on GTD®"


def test_parse_csv_completed_state():
    items, _ = parse_csv(_csv_fixture())
    completed = [i for i in items if i.completed]
    assert len(completed) == 2
    for item in completed:
        assert item.state == "done"


def test_parse_csv_next_state():
    items, _ = parse_csv(_csv_fixture())
    next_actions = [i for i in items if i.state == "next_action"]
    assert len(next_actions) == 2
    titles = {t.name for t in next_actions}
    assert "Read the Book" in titles
    assert "Read our Quick Guide" in titles


def test_parse_csv_tags_split_correctly():
    items, _ = parse_csv(_csv_fixture())
    mobile_task = next(i for i in items if i.name == "On mobile? try these gestures")
    assert "Personal" in mobile_task.tags
    assert "anywhere" in mobile_task.tags


def test_parse_csv_energy_mapping():
    items, _ = parse_csv(_csv_fixture())
    book_task = next(i for i in items if i.name == "Read the Book")
    assert book_task.energy_level == "medium"
    guide_task = next(i for i in items if i.name == "Read our Quick Guide")
    assert guide_task.energy_level == "low"


def test_parse_csv_time_estimate():
    items, _ = parse_csv(_csv_fixture())
    book_task = next(i for i in items if i.name == "Read the Book")
    assert book_task.time_estimate == 240
    guide_task = next(i for i in items if i.name == "Read our Quick Guide")
    assert guide_task.time_estimate == 15


def test_parse_csv_parent_name():
    items, _ = parse_csv(_csv_fixture())
    book_task = next(i for i in items if i.name == "Read the Book")
    assert book_task.parent_name == "Brush up on GTD®"


def test_parse_csv_standalone_has_no_parent():
    items, _ = parse_csv(_csv_fixture())
    computer_task = next(i for i in items if "computer" in i.name.lower())
    assert computer_task.parent_name is None


def test_parse_json_tasks():
    items, skipped = parse_json(_json_fixture())
    tasks = [i for i in items if i.type == "task"]
    assert len(tasks) == 4
    assert skipped == 2  # cancelled + deleted


def test_parse_json_filters_cancelled():
    items, skipped = parse_json(_json_fixture())
    names = {i.name for i in items}
    assert "This should be skipped (cancelled)" not in names
    assert skipped >= 1


def test_parse_json_filters_deleted():
    items, skipped = parse_json(_json_fixture())
    names = {i.name for i in items}
    assert "This should be skipped (deleted)" not in names
    assert skipped >= 1


def test_parse_json_energy_numeric_mapping():
    items, _ = parse_json(_json_fixture())
    book = next(i for i in items if i.name == "Read the Book")
    assert book.energy_level == "medium"  # energy=2
    guide = next(i for i in items if i.name == "Read our Quick Guide")
    assert guide.energy_level == "low"  # energy=1


def test_parse_json_tags_strip_commas():
    items, _ = parse_json(_json_fixture())
    computer_task = next(i for i in items if "computer" in i.name.lower())
    assert "computer" in computer_task.tags
    assert "" not in computer_task.tags


def test_parse_json_project_type():
    items, _ = parse_json(_json_fixture())
    projects = [i for i in items if i.type == "project"]
    assert len(projects) == 1
    assert projects[0].name == "Brush up on GTD®"


def test_parse_json_parent_id_resolved():
    items, _ = parse_json(_json_fixture())
    book = next(i for i in items if i.name == "Read the Book")
    assert book.parent_id == "540503BC-6CBA-4104-9FA7-6AD4414C6724"


def test_parse_json_completed_state():
    items, _ = parse_json(_json_fixture())
    completed = [i for i in items if i.completed]
    assert len(completed) == 2
    for item in completed:
        assert item.state == "done"


def test_parse_json_time_estimate():
    items, _ = parse_json(_json_fixture())
    book = next(i for i in items if i.name == "Read the Book")
    assert book.time_estimate == 240


# ---------------------------------------------------------------------------
# Integration tests — require the full app stack (in-memory SQLite)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_import_endpoint_requires_auth(client: AsyncClient) -> None:
    response = await client.post(
        "/import/nirvana",
        files={"file": ("test.csv", b"data", "text/csv")},
    )
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_import_endpoint_rejects_bad_format(client: AsyncClient) -> None:
    token = await register(client, "bad-format@example.com")
    response = await client.post(
        "/import/nirvana",
        data={"format": "xml"},
        files={"file": ("test.csv", b"data", "text/csv")},
        headers=auth_header(token),
    )
    assert response.status_code == 422


@pytest.mark.asyncio
async def test_import_endpoint_csv_creates_todos(client: AsyncClient) -> None:
    token = await register(client, "csv-import@example.com")
    csv_content = (FIXTURES / "nirvana_sample.csv").read_bytes()
    response = await client.post(
        "/import/nirvana",
        data={"format": "csv"},
        files={"file": ("export.csv", csv_content, "text/csv")},
        headers=auth_header(token),
    )
    assert response.status_code == 200
    result = response.json()
    assert result["imported_count"] == 4  # 4 tasks (project becomes tag)
    assert result["skipped_count"] == 0

    # Verify todos are in DB
    todos_resp = await client.get("/todos/", headers=auth_header(token))
    assert todos_resp.status_code == 200
    todos = todos_resp.json()
    assert len(todos) == 4
    titles = {t["title"] for t in todos}
    assert "Read the Book" in titles


@pytest.mark.asyncio
async def test_import_endpoint_json_creates_todos(client: AsyncClient) -> None:
    token = await register(client, "json-import@example.com")
    json_content = (FIXTURES / "nirvana_sample.json").read_bytes()
    response = await client.post(
        "/import/nirvana",
        data={"format": "json"},
        files={"file": ("export.json", json_content, "application/json")},
        headers=auth_header(token),
    )
    assert response.status_code == 200
    result = response.json()
    assert result["imported_count"] == 4
    assert result["skipped_count"] == 2  # cancelled + deleted


@pytest.mark.asyncio
async def test_import_endpoint_creates_project_tags(client: AsyncClient) -> None:
    token = await register(client, "project-tags@example.com")
    csv_content = (FIXTURES / "nirvana_sample.csv").read_bytes()
    response = await client.post(
        "/import/nirvana",
        data={"format": "csv"},
        files={"file": ("export.csv", csv_content, "text/csv")},
        headers=auth_header(token),
    )
    assert response.status_code == 200
    result = response.json()
    assert result["project_tags_created"] == 1

    # Tasks under the project should have a project tag attached
    todos_resp = await client.get("/todos/", headers=auth_header(token))
    todos = todos_resp.json()
    book = next(t for t in todos if t["title"] == "Read the Book")
    project_tags = [tag for tag in book["tags"] if tag["type"] == "project"]
    assert len(project_tags) == 1
    assert project_tags[0]["name"] == "Brush up on GTD®"


@pytest.mark.asyncio
async def test_import_endpoint_deduplicates_existing_tags(client: AsyncClient) -> None:
    token = await register(client, "dedup-tags@example.com")

    # Pre-create the project tag
    await client.post(
        "/todos/",
        json={"title": "dummy", "tags": [{"name": "Brush up on GTD®", "type": "project"}]},
        headers=auth_header(token),
    )

    csv_content = (FIXTURES / "nirvana_sample.csv").read_bytes()
    response = await client.post(
        "/import/nirvana",
        data={"format": "csv"},
        files={"file": ("export.csv", csv_content, "text/csv")},
        headers=auth_header(token),
    )
    assert response.status_code == 200
    result = response.json()
    # Tag already existed → should not count as newly created
    assert result["project_tags_created"] == 0


@pytest.mark.asyncio
async def test_import_endpoint_returns_summary_counts(client: AsyncClient) -> None:
    token = await register(client, "summary@example.com")
    json_content = (FIXTURES / "nirvana_sample.json").read_bytes()
    response = await client.post(
        "/import/nirvana",
        data={"format": "json"},
        files={"file": ("export.json", json_content, "application/json")},
        headers=auth_header(token),
    )
    assert response.status_code == 200
    result = response.json()
    assert "imported_count" in result
    assert "skipped_count" in result
    assert "project_tags_created" in result


@pytest.mark.asyncio
async def test_import_endpoint_auto_detects_json(client: AsyncClient) -> None:
    token = await register(client, "auto-json@example.com")
    json_content = (FIXTURES / "nirvana_sample.json").read_bytes()
    response = await client.post(
        "/import/nirvana",
        # No format field → defaults to "auto"
        files={"file": ("export.json", json_content, "application/json")},
        headers=auth_header(token),
    )
    assert response.status_code == 200
    assert response.json()["imported_count"] == 4


@pytest.mark.asyncio
async def test_import_endpoint_auto_detects_csv(client: AsyncClient) -> None:
    token = await register(client, "auto-csv@example.com")
    csv_content = (FIXTURES / "nirvana_sample.csv").read_bytes()
    response = await client.post(
        "/import/nirvana",
        files={"file": ("export.csv", csv_content, "text/csv")},
        headers=auth_header(token),
    )
    assert response.status_code == 200
    assert response.json()["imported_count"] == 4


@pytest.mark.asyncio
async def test_import_endpoint_done_todos_are_completed(client: AsyncClient) -> None:
    token = await register(client, "done-todos@example.com")
    csv_content = (FIXTURES / "nirvana_sample.csv").read_bytes()
    await client.post(
        "/import/nirvana",
        data={"format": "csv"},
        files={"file": ("export.csv", csv_content, "text/csv")},
        headers=auth_header(token),
    )
    todos_resp = await client.get("/todos/", headers=auth_header(token))
    todos = todos_resp.json()
    done_todos = [t for t in todos if t["state"] == "done"]
    assert len(done_todos) == 2
    for todo in done_todos:
        assert todo["completed"] is True
