"""Todo-related Pydantic schemas."""

from datetime import datetime
from enum import StrEnum

from pydantic import BaseModel, field_validator

from app.todos.models import ENERGY_LEVELS, GTD_STATES, TAG_TYPES


class TagType(StrEnum):
    context = "context"
    project = "project"
    area = "area"
    label = "label"


class TagInput(BaseModel):
    """Explicit tag specification with a type discriminator."""

    name: str
    type: TagType = TagType.context

    @field_validator("type", mode="before")
    @classmethod
    def validate_type(cls, v: str) -> str:
        if v not in TAG_TYPES:
            raise ValueError(f"tag type must be one of {sorted(TAG_TYPES)}")
        return v


class TodoCreate(BaseModel):
    title: str
    notes: str | None = None
    state: str = "inbox"
    # Each item is either a plain string ("@office") or a TagInput dict.
    # Plain strings: "@" prefix → context; bare word → label.
    tags: list[str | TagInput] = []
    due_date: str | None = None
    priority: int | None = None
    time_estimate: int | None = None  # minutes
    energy_level: str | None = None  # 'low' | 'medium' | 'high'
    capture_source: str | None = None  # 'manual' | 'share_sheet' | 'voice' | 'ai_parse'

    @field_validator("state")
    @classmethod
    def validate_state(cls, v: str) -> str:
        if v not in GTD_STATES:
            raise ValueError(f"state must be one of {sorted(GTD_STATES)}")
        return v

    @field_validator("energy_level")
    @classmethod
    def validate_energy_level(cls, v: str | None) -> str | None:
        if v is not None and v not in ENERGY_LEVELS:
            raise ValueError(f"energy_level must be one of {sorted(ENERGY_LEVELS)}")
        return v


class TodoUpdate(BaseModel):
    title: str | None = None
    notes: str | None = None
    completed: bool | None = None
    state: str | None = None
    tags: list[str | TagInput] | None = None  # Full replacement of tag set when provided
    due_date: str | None = None
    priority: int | None = None
    time_estimate: int | None = None
    energy_level: str | None = None
    capture_source: str | None = None

    @field_validator("state")
    @classmethod
    def validate_state(cls, v: str | None) -> str | None:
        if v is not None and v not in GTD_STATES:
            raise ValueError(f"state must be one of {sorted(GTD_STATES)}")
        return v

    @field_validator("energy_level")
    @classmethod
    def validate_energy_level(cls, v: str | None) -> str | None:
        if v is not None and v not in ENERGY_LEVELS:
            raise ValueError(f"energy_level must be one of {sorted(ENERGY_LEVELS)}")
        return v


class TagOut(BaseModel):
    id: str
    name: str
    color: str | None
    type: str

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
    time_estimate: int | None
    energy_level: str | None
    capture_source: str | None

    model_config = {"from_attributes": True}
