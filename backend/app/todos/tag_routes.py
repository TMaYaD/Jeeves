"""Standalone CRUD for tags and todo_tags.

These endpoints are called by the PowerSync BackendConnector to upload
offline mutations for the `tags` and `todo_tags` sync shapes.
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.dependencies import get_current_user
from app.auth.models import User
from app.database import get_db
from app.todos.models import Tag, Todo, TodoTag
from app.todos.schemas import TagCreate, TagOut, TagUpdate, TodoTagCreate

router = APIRouter()


# ── Tags ──────────────────────────────────────────────────────────────────────


@router.post("/tags/", response_model=TagOut, status_code=status.HTTP_201_CREATED)
async def create_tag(
    body: TagCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> Tag:
    # Idempotency: return existing tag if the client-side id already exists.
    if body.id is not None:
        existing = await db.get(Tag, body.id)
        if existing:
            if existing.user_id == current_user.id:
                return existing
            raise HTTPException(status_code=409, detail="Tag id already exists")
    tag = Tag(
        **({"id": body.id} if body.id is not None else {}),
        name=body.name,
        type=body.type,
        color=body.color,
        user_id=current_user.id,
    )
    db.add(tag)
    await db.commit()
    await db.refresh(tag)
    return tag


@router.patch("/tags/{tag_id}", response_model=TagOut)
async def update_tag(
    tag_id: str,
    body: TagUpdate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> Tag:
    tag = await db.get(Tag, tag_id)
    if not tag or tag.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Tag not found")
    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(tag, field, value)
    await db.commit()
    await db.refresh(tag)
    return tag


@router.delete("/tags/{tag_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_tag(
    tag_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> None:
    tag = await db.get(Tag, tag_id)
    if not tag or tag.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Tag not found")
    await db.delete(tag)
    await db.commit()


# ── TodoTags ──────────────────────────────────────────────────────────────────


@router.post("/todo_tags/", status_code=status.HTTP_201_CREATED)
async def create_todo_tag(
    body: TodoTagCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict[str, str]:
    # Verify the todo belongs to the current user.
    todo = await db.get(Todo, body.todo_id)
    if not todo or todo.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Todo not found")

    # Verify the tag exists and belongs to the current user.
    tag = await db.get(Tag, body.tag_id)
    if not tag or tag.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Tag not found")

    # Idempotency: return if already exists by id, but only when the stored
    # relation matches exactly; a mismatched relation is a conflict.
    if body.id is not None:
        result = await db.execute(select(TodoTag).where(TodoTag.id == body.id))
        existing_by_id = result.scalar_one_or_none()
        if existing_by_id is not None:
            if existing_by_id.todo_id == body.todo_id and existing_by_id.tag_id == body.tag_id:
                return {"todo_id": body.todo_id, "tag_id": body.tag_id}
            raise HTTPException(
                status_code=409,
                detail="TodoTag id already used for a different relation",
            )

    # Idempotency: return if (todo_id, tag_id) pair already exists.
    result = await db.execute(
        select(TodoTag).where(TodoTag.todo_id == body.todo_id, TodoTag.tag_id == body.tag_id)
    )
    if result.scalar_one_or_none() is not None:
        return {"todo_id": body.todo_id, "tag_id": body.tag_id}

    todo_tag = TodoTag(
        **({"id": body.id} if body.id is not None else {}),
        todo_id=body.todo_id,
        tag_id=body.tag_id,
        user_id=current_user.id,
    )
    db.add(todo_tag)
    await db.commit()
    return {"todo_id": body.todo_id, "tag_id": body.tag_id}


@router.delete("/todo_tags/{todo_tag_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_todo_tag(
    todo_tag_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> None:
    result = await db.execute(select(TodoTag).where(TodoTag.id == todo_tag_id))
    todo_tag = result.scalar_one_or_none()
    if todo_tag is None:
        raise HTTPException(status_code=404, detail="TodoTag not found")
    # Verify ownership via the parent todo.
    todo = await db.get(Todo, todo_tag.todo_id)
    if not todo or todo.user_id != current_user.id:
        raise HTTPException(status_code=403, detail="Forbidden")
    await db.delete(todo_tag)
    await db.commit()
