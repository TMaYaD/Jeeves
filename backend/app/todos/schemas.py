"""Todo-related Pydantic schemas."""

from datetime import datetime

from pydantic import BaseModel


class TodoCreate(BaseModel):
    title: str
    notes: str | None = None
    state: str = "inbox"
    tags: list[str] = []  # Tag names e.g. ["@office", "Project/Renovation"]
    due_date: str | None = None
    priority: int | None = None


class TodoUpdate(BaseModel):
    title: str | None = None
    notes: str | None = None
    completed: bool | None = None
    state: str | None = None
    tags: list[str] | None = None  # Full replacement of tag set when provided
    due_date: str | None = None
    priority: int | None = None


class TagOut(BaseModel):
    id: str
    name: str
    color: str | None

    model_config = {"from_attributes": True}


class TodoOut(BaseModel):
    id: str
    title: str
    notes: str | None
    completed: bool
    priority: int | None
    state: str
    tags: list[TagOut]
    due_date: datetime | None
    created_at: datetime

    model_config = {"from_attributes": True}
