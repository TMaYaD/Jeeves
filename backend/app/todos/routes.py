"""Todos CRUD API.

PowerSync handles real-time sync; these endpoints cover initial load,
auth-gated mutations, and operations that require server-side logic
(e.g. recurrence expansion, AI-assisted parsing).
"""

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.auth.dependencies import get_current_user
from app.auth.models import User
from app.database import get_db
from app.todos.models import Tag, Todo, TodoTag
from app.todos.schemas import TagInput, TodoCreate, TodoOut, TodoUpdate

router = APIRouter(prefix="/todos", tags=["todos"])


def _infer_tag_type(name: str) -> str:
    """Infer tag type from name convention.

    - '@' prefix  → 'context'  (GTD context: @office, @phone)
    - bare word   → 'label'    (general label)
    """
    return "context" if name.startswith("@") else "label"


async def _resolve_tags(
    tag_specs: list[str | TagInput],
    user_id: str,
    db: AsyncSession,
) -> list[Tag]:
    """Return Tag ORM objects for the given specs, creating any that don't exist yet.

    Each spec is either:
    - a plain string: type is inferred from name ('context' if '@' prefix, else 'label')
    - a TagInput: explicit name + type

    At most one tag of type='project' may be in the returned list.
    """
    if not tag_specs:
        return []

    # Normalise to (name, type) pairs
    pairs: list[tuple[str, str]] = []
    project_count = 0
    for spec in tag_specs:
        if isinstance(spec, str):
            tag_type = _infer_tag_type(spec)
            pairs.append((spec, tag_type))
        else:
            pairs.append((spec.name, spec.type.value))
        if pairs[-1][1] == "project":
            project_count += 1

    if project_count > 1:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="A todo may only have one project tag.",
        )

    names = [name for name, _ in pairs]
    result = await db.execute(select(Tag).where(Tag.user_id == user_id, Tag.name.in_(names)))
    existing: dict[str, Tag] = {tag.name: tag for tag in result.scalars().all()}

    tags: list[Tag] = []
    for name, tag_type in pairs:
        if name in existing:
            tag = existing[name]
            # Upgrade type if the caller is explicit about it (e.g. promoting a string
            # tag that was previously labelled 'label' to 'project').
            if tag.type != tag_type:
                tag.type = tag_type
            tags.append(tag)
        else:
            new_tag = Tag(name=name, type=tag_type, user_id=user_id)
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
    tags = await _resolve_tags(body.tags, current_user.id, db)
    todo = Todo(
        title=body.title,
        notes=body.notes,
        state=body.state,
        priority=body.priority,
        time_estimate=body.time_estimate,
        energy_level=body.energy_level,
        capture_source=body.capture_source,
        user_id=current_user.id,
        tags=tags,
    )
    db.add(todo)
    await db.commit()
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
        todo.tags = await _resolve_tags(body.tags, current_user.id, db)  # type: ignore[arg-type]

    for field, value in update_data.items():
        setattr(todo, field, value)

    await db.commit()
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
