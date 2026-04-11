"""Todo-related Pydantic schemas."""

from datetime import datetime

from pydantic import BaseModel


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
