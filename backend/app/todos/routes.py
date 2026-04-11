"""Todos CRUD API.

Electric SQL handles real-time sync; these endpoints cover initial load,
auth-gated mutations, and operations that require server-side logic
(e.g. recurrence expansion, AI-assisted parsing).
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.dependencies import get_current_user
from app.auth.models import User
from app.database import get_db
from app.todos.models import Todo
from app.todos.schemas import TodoCreate, TodoOut, TodoUpdate

router = APIRouter(prefix="/todos", tags=["todos"])


@router.get("/", response_model=list[TodoOut])
async def list_todos(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[Todo]:
    result = await db.execute(select(Todo).where(Todo.user_id == current_user.id))
    return list(result.scalars().all())


@router.post("/", response_model=TodoOut, status_code=status.HTTP_201_CREATED)
async def create_todo(
    body: TodoCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> Todo:
    todo = Todo(
        title=body.title,
        notes=body.notes,
        list_id=body.list_id,
        priority=body.priority,
        user_id=current_user.id,
    )
    db.add(todo)
    await db.commit()
    await db.refresh(todo)
    return todo


@router.get("/{todo_id}", response_model=TodoOut)
async def get_todo(
    todo_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> Todo:
    todo = await db.get(Todo, todo_id)
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
    todo = await db.get(Todo, todo_id)
    if not todo or todo.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Todo not found")
    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(todo, field, value)
    await db.commit()
    await db.refresh(todo)
    return todo


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


@router.get("/lists/{list_id}/summary")
async def summarize_list(list_id: str, _: User = Depends(get_current_user)) -> dict[str, str]:
    # TODO: fetch todos in list, summarize
    return {"summary": ""}
