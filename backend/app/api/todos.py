"""Todos CRUD API.

Electric SQL handles real-time sync; these endpoints cover initial load,
auth-gated mutations, and operations that require server-side logic
(e.g. recurrence expansion, AI-assisted parsing).
"""

from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.dependencies import get_current_user
from app.database import get_db
from app.models.todo import Todo
from app.models.user import User

router = APIRouter(prefix="/todos", tags=["todos"])


class TodoCreate(BaseModel):
    title: str
    notes: str | None = None
    list_id: str | None = None
    due_date: str | None = None
    priority: int | None = None


class TodoUpdate(BaseModel):
    title: str | None = None
    notes: str | None = None
    completed: bool | None = None
    due_date: str | None = None
    priority: int | None = None


class TodoOut(BaseModel):
    id: str
    title: str
    notes: str | None
    completed: bool
    priority: int | None
    list_id: str | None
    due_date: datetime | None
    created_at: datetime

    model_config = {"from_attributes": True}


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
