"""Todos CRUD API.

Electric SQL handles real-time sync; these endpoints cover initial load,
auth-gated mutations, and operations that require server-side logic
(e.g. recurrence expansion, AI-assisted parsing).
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.auth.dependencies import get_current_user
from app.auth.models import User
from app.database import get_db
from app.todos.models import Tag, Todo
from app.todos.schemas import TodoCreate, TodoOut, TodoUpdate

router = APIRouter(prefix="/todos", tags=["todos"])


async def _resolve_tags(
    tag_names: list[str],
    user_id: str,
    db: AsyncSession,
) -> list[Tag]:
    """Return Tag ORM objects for the given names, creating any that don't exist yet."""
    if not tag_names:
        return []

    result = await db.execute(select(Tag).where(Tag.user_id == user_id, Tag.name.in_(tag_names)))
    existing = {tag.name: tag for tag in result.scalars().all()}

    tags: list[Tag] = []
    for name in tag_names:
        if name in existing:
            tags.append(existing[name])
        else:
            new_tag = Tag(name=name, user_id=user_id)
            db.add(new_tag)
            tags.append(new_tag)

    return tags


async def _get_todo_with_tags(todo_id: str, db: AsyncSession) -> Todo | None:
    """Fetch a single Todo with its tags eagerly loaded."""
    result = await db.execute(
        select(Todo).where(Todo.id == todo_id).options(selectinload(Todo.tags))
    )
    return result.scalar_one_or_none()


@router.get("/", response_model=list[TodoOut])
async def list_todos(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[Todo]:
    result = await db.execute(
        select(Todo).where(Todo.user_id == current_user.id).options(selectinload(Todo.tags))
    )
    return list(result.scalars().all())


@router.post("/", response_model=TodoOut, status_code=status.HTTP_201_CREATED)
async def create_todo(
    body: TodoCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> Todo:
    tags = await _resolve_tags(body.tags, current_user.id, db)
    todo = Todo(
        title=body.title,
        notes=body.notes,
        state=body.state,
        priority=body.priority,
        user_id=current_user.id,
        tags=tags,
    )
    db.add(todo)
    await db.commit()
    # Re-query to get eagerly loaded tags (refresh doesn't reload relationships)
    loaded = await _get_todo_with_tags(todo.id, db)
    assert loaded is not None  # just committed — must exist
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

    # Handle tags separately — replacing the full set
    if "tags" in update_data:
        todo.tags = await _resolve_tags(update_data.pop("tags"), current_user.id, db)

    for field, value in update_data.items():
        setattr(todo, field, value)

    await db.commit()
    loaded = await _get_todo_with_tags(todo.id, db)
    assert loaded is not None  # just committed — must exist
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
