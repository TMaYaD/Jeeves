"""Import endpoint: POST /import/nirvana."""

from fastapi import APIRouter, Depends, Form, HTTPException, UploadFile, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.dependencies import get_current_user
from app.auth.models import User
from app.database import get_db
from app.import_nirvana.converter import convert_items
from app.import_nirvana.parser import ParseError, parse_csv, parse_json
from app.import_nirvana.schemas import ImportResult
from app.todos.models import Tag, Todo, TodoTag
from app.todos.utils import resolve_tags

router = APIRouter(prefix="/import", tags=["import"])

_BATCH_SIZE = 500


def _detect_format(filename: str, content: str) -> str:
    """Return 'json' or 'csv' based on filename extension, falling back to content sniff."""
    lower = (filename or "").lower()
    if lower.endswith(".json"):
        return "json"
    if lower.endswith(".csv"):
        return "csv"
    # Sniff: if the first non-whitespace character is '[' or '{', assume JSON
    stripped = content.lstrip()
    return "json" if stripped.startswith(("[", "{")) else "csv"


@router.post("/nirvana", response_model=ImportResult)
async def import_nirvana(
    file: UploadFile,
    format: str = Form(default="auto"),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ImportResult:
    """Import tasks and projects from a Nirvana CSV or JSON export.

    Accepts multipart/form-data with a `file` field (the export file) and an
    optional `format` field ("csv" | "json" | "auto").  When format is "auto"
    the format is detected from the filename extension or content.
    """
    if format not in ("csv", "json", "auto"):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="format must be 'csv', 'json', or 'auto'",
        )

    raw_bytes = await file.read()
    try:
        content = raw_bytes.decode("utf-8")
    except UnicodeDecodeError:
        content = raw_bytes.decode("latin-1")

    effective_format = format if format != "auto" else _detect_format(file.filename or "", content)

    try:
        if effective_format == "json":
            items, skipped = parse_json(content)
        else:
            items, skipped = parse_csv(content)
    except ParseError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=str(exc),
        ) from exc

    if not items:
        return ImportResult(imported_count=0, skipped_count=skipped, project_tags_created=0)

    # Fetch existing project tag names for this user to avoid re-counting upserts
    result = await db.execute(
        select(Tag.name).where(
            Tag.user_id == current_user.id,
            Tag.type == "project",
        )
    )
    existing_project_names: set[str] = set(result.scalars().all())

    new_project_names, todo_payloads = convert_items(items, existing_project_names)

    # Upsert new project tags: promote existing same-name tags or insert new ones
    project_tags_created = 0
    for project_name in new_project_names:
        existing_tag_row = await db.execute(
            select(Tag).where(
                Tag.user_id == current_user.id,
                Tag.name == project_name,
            )
        )
        existing_tag = existing_tag_row.scalar_one_or_none()
        if existing_tag is None:
            db.add(Tag(name=project_name, type="project", user_id=current_user.id))
            project_tags_created += 1
        elif existing_tag.type != "project":
            existing_tag.type = "project"
            project_tags_created += 1

    await db.flush()

    # Insert todos in batches.  TodoTag rows are inserted explicitly (not via
    # `todo.tags = tags`) so we can set `user_id` — the secondary-relationship
    # cascade bypasses TodoTag's mapper.  See app/todos/routes.py::create_todo.
    imported_count = 0
    for i in range(0, len(todo_payloads), _BATCH_SIZE):
        batch = todo_payloads[i : i + _BATCH_SIZE]
        pending: list[tuple[Todo, list[Tag]]] = []
        for payload in batch:
            tags = await resolve_tags(payload.tags, current_user.id, db)
            todo = Todo(
                title=payload.title,
                notes=payload.notes,
                state=payload.state,
                completed=payload.completed,
                priority=payload.priority,
                due_date=payload.due_date,
                time_estimate=payload.time_estimate,
                energy_level=payload.energy_level,
                waiting_for=payload.waiting_for,
                capture_source=payload.capture_source,
                user_id=current_user.id,
            )
            db.add(todo)
            pending.append((todo, tags))
            imported_count += 1
        # Flush so todo.id and any new tag IDs are assigned before inserting
        # junction rows.
        await db.flush()
        for todo, tags in pending:
            for tag in tags:
                db.add(TodoTag(todo_id=todo.id, tag_id=tag.id, user_id=current_user.id))
        await db.flush()

    await db.commit()

    return ImportResult(
        imported_count=imported_count,
        skipped_count=skipped,
        project_tags_created=project_tags_created,
    )
