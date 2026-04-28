"""Todo-related Pydantic schemas."""

from datetime import datetime
from enum import StrEnum

from pydantic import BaseModel, Field, field_validator, model_validator

from app.todos.models import ENERGY_LEVELS, GTD_STATES, INTENT_VALUES, TAG_TYPES


def _normalise_drift_iso(value: object) -> object:
    """Strip the leading space Drift inserts before the timezone offset.

    When `storeDateTimeAsText` is enabled, Drift serialises non-UTC
    DateTimes as ``2026-04-30T00:00:00.000 +05:30`` — note the space.  That
    format is accepted by SQLite's date functions but rejected by Pydantic's
    ISO-8601 parser (and asyncpg's TIMESTAMPTZ encoder).  Removing the space
    yields a standard offset that Pydantic parses natively, while leaving
    already-clean strings (``…Z``, ``…+00:00``) untouched.
    """
    if isinstance(value, str):
        return value.replace(" +", "+").replace(" -", "-")
    return value


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


class TagCreate(BaseModel):
    id: str | None = None  # Client-side UUID for idempotency
    name: str
    type: TagType = TagType.context
    color: str | None = None

    @field_validator("type", mode="before")
    @classmethod
    def validate_type(cls, v: str) -> str:
        if v not in TAG_TYPES:
            raise ValueError(f"tag type must be one of {sorted(TAG_TYPES)}")
        return v


class TagUpdate(BaseModel):
    name: str | None = None
    type: str | None = None
    color: str | None = None

    @field_validator("type")
    @classmethod
    def validate_type(cls, v: str | None) -> str | None:
        if v is not None and v not in TAG_TYPES:
            raise ValueError(f"tag type must be one of {sorted(TAG_TYPES)}")
        return v


class TodoTagCreate(BaseModel):
    id: str | None = None  # Client-side UUID for idempotency
    todo_id: str
    tag_id: str


class TodoCreate(BaseModel):
    id: str | None = None  # Client-side UUID for idempotency (PowerSync offline-first)
    title: str
    notes: str | None = None
    completed: bool = False
    state: str = "inbox"
    intent: str = "next"
    # Each item is either a plain string ("@office") or a TagInput dict.
    # Plain strings: "@" prefix → context; bare word → label.
    tags: list[str | TagInput] = []
    due_date: datetime | None = None
    priority: int | None = None
    time_estimate: int | None = None  # minutes
    energy_level: str | None = None  # 'low' | 'medium' | 'high'
    capture_source: str | None = None  # 'manual' | 'share_sheet' | 'voice' | 'ai_parse'
    # Client-state columns (migration 0007)
    waiting_for: str | None = None  # who/what the task is waiting on
    in_progress_since: str | None = None
    time_spent_minutes: int = Field(default=0, ge=0)
    selected_for_today: bool | None = None
    daily_selection_date: str | None = None

    _normalise_due_date = field_validator("due_date", mode="before")(_normalise_drift_iso)

    @field_validator("state")
    @classmethod
    def validate_state(cls, v: str) -> str:
        if v not in GTD_STATES:
            raise ValueError(f"state must be one of {sorted(GTD_STATES)}")
        return v

    @field_validator("intent")
    @classmethod
    def validate_intent(cls, v: str) -> str:
        if v not in INTENT_VALUES:
            raise ValueError(f"intent must be one of {sorted(INTENT_VALUES)}")
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
    intent: str | None = None
    tags: list[str | TagInput] | None = None  # Full replacement of tag set when provided
    due_date: datetime | None = None
    priority: int | None = None
    time_estimate: int | None = None
    energy_level: str | None = None
    capture_source: str | None = None
    # Client-state columns (migration 0007)
    waiting_for: str | None = None
    in_progress_since: str | None = None
    time_spent_minutes: int | None = Field(default=None, ge=0)
    selected_for_today: bool | None = None
    daily_selection_date: str | None = None

    _normalise_due_date = field_validator("due_date", mode="before")(_normalise_drift_iso)

    @field_validator("state")
    @classmethod
    def validate_state(cls, v: str | None) -> str | None:
        if v is not None and v not in GTD_STATES:
            raise ValueError(f"state must be one of {sorted(GTD_STATES)}")
        return v

    @field_validator("intent")
    @classmethod
    def validate_intent(cls, v: str | None) -> str | None:
        if v is not None and v not in INTENT_VALUES:
            raise ValueError(f"intent must be one of {sorted(INTENT_VALUES)}")
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


class TimeLogOut(BaseModel):
    id: str
    user_id: str
    task_id: str
    started_at: datetime
    ended_at: datetime | None

    model_config = {"from_attributes": True}


class TodoOut(BaseModel):
    id: str
    title: str
    notes: str | None
    completed: bool
    priority: int | None
    state: str
    clarified: bool
    intent: str
    tags: list[TagOut]
    due_date: datetime | None
    created_at: datetime
    time_estimate: int | None
    energy_level: str | None
    capture_source: str | None
    # Client-state columns (migration 0007)
    waiting_for: str | None
    in_progress_since: str | None
    time_spent_minutes: int
    selected_for_today: bool | None
    daily_selection_date: str | None

    model_config = {"from_attributes": True}

    @model_validator(mode="after")
    def derive_inbox_state(self) -> "TodoOut":
        if not self.clarified:
            self.state = "inbox"
        return self
