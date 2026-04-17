"""Todos CRUD API.

PowerSync handles real-time sync; these endpoints cover initial load,
auth-gated mutations, and operations that require server-side logic
(e.g. recurrence expansion, AI-assisted parsing).
"""

from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.auth.dependencies import get_current_user
from app.auth.models import User
from app.database import get_db
from app.todos.models import Tag, Todo, TodoTag
from app.todos.schemas import TodoCreate, TodoOut, TodoUpdate
from app.todos.utils import resolve_tags

router = APIRouter(prefix="/todos", tags=["todos"])


async def _get_todo_with_tags(todo_id: str, db: AsyncSession) -> Todo | None:
    """Fetch a single Todo with its tags eagerly loaded."""
    result = await db.execute(
        select(Todo).where(Todo.id == todo_id).options(selectinload(Todo.tags))
    )
    return result.scalar_one_or_none()


@router.get("/", response_model=list[TodoOut])
async def list_todos(
    state: str | None = Query(default=None, description="Filter by GTD state"),
    tag_type: str | None = Query(default=None, description="Filter by tag type"),
    tag_name: str | None = Query(default=None, description="Filter by tag name"),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[Todo]:
    query = select(Todo).where(Todo.user_id == current_user.id).options(selectinload(Todo.tags))

    if state is not None:
        query = query.where(Todo.state == state)

    if tag_type is not None or tag_name is not None:
        # Join through todo_tags → tags
        query = query.join(TodoTag, TodoTag.todo_id == Todo.id).join(Tag, Tag.id == TodoTag.tag_id)
        if tag_type is not None:
            query = query.where(Tag.type == tag_type)
        if tag_name is not None:
            query = query.where(Tag.name == tag_name)
        query = query.distinct()

    result = await db.execute(query)
    return list(result.scalars().all())


@router.post("/", response_model=TodoOut, status_code=status.HTTP_201_CREATED)
async def create_todo(
    body: TodoCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> Todo:
    tags = await resolve_tags(body.tags, current_user.id, db)
    due_date = datetime.fromisoformat(body.due_date) if body.due_date else None
    # Check for existing todo by client-provided id (idempotent retry support).
    if body.id is not None:
        existing = await _get_todo_with_tags(body.id, db)
        if existing and existing.user_id == current_user.id:
            return existing
    todo = Todo(
        **({"id": body.id} if body.id is not None else {}),
        title=body.title,
        notes=body.notes,
        completed=body.completed,
        state=body.state,
        priority=body.priority,
        due_date=due_date,
        time_estimate=body.time_estimate,
        energy_level=body.energy_level,
        capture_source=body.capture_source,
        waiting_for=body.waiting_for,
        in_progress_since=body.in_progress_since,
        time_spent_minutes=body.time_spent_minutes,
        blocked_by_todo_id=body.blocked_by_todo_id,
        selected_for_today=body.selected_for_today,
        daily_selection_date=body.daily_selection_date,
        user_id=current_user.id,
    )
    db.add(todo)
    # Flush so todo.id (and any new tag IDs from resolve_tags) are assigned
    # before we insert junction rows.  We manage TodoTag rows explicitly
    # rather than via `todo.tags = tags` because the secondary-relationship
    # cascade issues raw INSERTs that bypass TodoTag's mapper — we'd have no
    # call site to set user_id on.
    await db.flush()
    for tag in tags:
        db.add(TodoTag(todo_id=todo.id, tag_id=tag.id, user_id=current_user.id))
    await db.commit()
    # The session's in-memory `todo.tags` collection is still the stale
    # (empty) set the ORM tracked before we inserted junction rows directly.
    # Expire it so `_get_todo_with_tags` reloads via selectinload.
    db.expire(todo, ["tags"])
    loaded = await _get_todo_with_tags(todo.id, db)
    assert loaded is not None
    return loaded


@router.get("/{todo_id}", response_model=TodoOut)
async def get_todo(
    todo_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> Todo:
    todo = await _get_todo_with_tags(todo_id, db)
    if not todo or todo.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Todo not found")
    return todo


@router.patch("/{todo_id}", response_model=TodoOut)
async def update_todo(
    todo_id: str,
    body: TodoUpdate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> Todo:
    todo = await _get_todo_with_tags(todo_id, db)
    if not todo or todo.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Todo not found")

    update_data = body.model_dump(exclude_unset=True)

    if "tags" in update_data:
        # Use the validated model field (TagInput objects), not the serialised dict
        update_data.pop("tags")
        # Replace the tag set by deleting existing junction rows and inserting
        # new ones — explicit so we can populate user_id (see create_todo).
        new_tags = await resolve_tags(body.tags, current_user.id, db)  # type: ignore[arg-type]
        await db.execute(delete(TodoTag).where(TodoTag.todo_id == todo.id))
        for tag in new_tags:
            db.add(TodoTag(todo_id=todo.id, tag_id=tag.id, user_id=current_user.id))

    for field, value in update_data.items():
        setattr(todo, field, value)

    await db.commit()
    # Expire the in-memory tags collection; see create_todo for rationale.
    db.expire(todo, ["tags"])
    loaded = await _get_todo_with_tags(todo.id, db)
    assert loaded is not None
    return loaded


@router.delete("/{todo_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_todo(
    todo_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> None:
    todo = await db.get(Todo, todo_id)
    if not todo or todo.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Todo not found")
    await db.delete(todo)
    await db.commit()


# ── Sub-resources ─────────────────────────────────────────────────────────────


@router.get("/{todo_id}/suggestions")
async def get_suggestions(
    todo_id: str, _: User = Depends(get_current_user)
) -> dict[str, list[str]]:
    # TODO: fetch todo from DB, build prompt, return suggestions
    return {"suggestions": []}


@router.get("/tags/{tag_id}/summary")
async def summarize_tag(tag_id: str, _: User = Depends(get_current_user)) -> dict[str, str]:
    # TODO: fetch todos with this tag, summarize
    return {"summary": ""}
