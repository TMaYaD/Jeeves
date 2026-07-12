"""Todo-related Pydantic schemas."""

from datetime import datetime
from enum import StrEnum

from pydantic import BaseModel, Field, field_validator

from app.todos.models import ENERGY_LEVELS, INTENT_VALUES, TAG_TYPES

STATE_VALUES = ("next_action",)

# Datetime fields shared by TodoCreate and TodoUpdate that may arrive in
# Drift's space-before-offset format and need normalisation before parsing.
# TodoCreate additionally normalises created_at (create-only field).
_CLIENT_STATE_DATETIME_FIELDS = (
    "due_date",
    "done_at",
    "last_clarified_at",
    "last_next_action_completion_at",
    "updated_at",
)


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
    person = "person"


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
    done_at: datetime | None = None
    # false = still in the Inbox.  Defaults to true so plain REST creates are
    # born clarified; connector PUTs always send the client's value (#380).
    clarified: bool = True
    intent: str = "next"
    # Each item is either a plain string ("@office") or a TagInput dict.
    # Plain strings: "@" prefix → context; bare word → label.
    tags: list[str | TagInput] = []
    due_date: datetime | None = None
    priority: int | None = None
    time_estimate: int | None = None  # minutes
    energy_level: str | None = None  # 'low' | 'medium' | 'high'
    capture_source: str | None = None  # 'manual' | 'share_sheet' | 'voice' | 'ai_parse'
    # Client-state columns (migrations 0007/0022/0024) — must round-trip
    # verbatim or the next checkpoint download wipes the local value
    # (docs/SYNC.md § The todos upload contract).
    time_spent_minutes: int = Field(default=0, ge=0)
    last_clarified_at: datetime | None = None
    next_action_text: str | None = None
    last_next_action_completion_at: datetime | None = None
    # Client-stamped write timestamps.  The server never writes updated_at;
    # created_at falls back to the server default only when omitted, so
    # offline captures keep their true capture time.
    created_at: datetime | None = None
    updated_at: datetime | None = None
    # Legacy compatibility field — only "next_action" is accepted; ignored by the DB layer.
    state: str | None = None

    _normalise_datetimes = field_validator(
        *_CLIENT_STATE_DATETIME_FIELDS, "created_at", mode="before"
    )(_normalise_drift_iso)

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

    @field_validator("state")
    @classmethod
    def validate_state(cls, v: str | None) -> str | None:
        if v is not None and v not in STATE_VALUES:
            raise ValueError(f"state must be one of {sorted(STATE_VALUES)}")
        return v


class TodoUpdate(BaseModel):
    title: str | None = None
    notes: str | None = None
    done_at: datetime | None = None
    # false→true is the clarify flow; true→false is move-back-to-Inbox.
    # Dropping it here would be the inverse of #380: a locally-clarified task
    # bouncing back into the Inbox on the next checkpoint.
    clarified: bool | None = None
    intent: str | None = None
    tags: list[str | TagInput] | None = None  # Full replacement of tag set when provided
    due_date: datetime | None = None
    priority: int | None = None
    time_estimate: int | None = None
    energy_level: str | None = None
    capture_source: str | None = None
    # Client-state columns (migrations 0007/0022/0024) — must round-trip
    # verbatim (docs/SYNC.md § The todos upload contract).
    time_spent_minutes: int | None = Field(default=None, ge=0)
    last_clarified_at: datetime | None = None
    next_action_text: str | None = None
    last_next_action_completion_at: datetime | None = None
    updated_at: datetime | None = None
    # Legacy compatibility field — only "next_action" is accepted; ignored by the DB layer.
    state: str | None = None

    _normalise_datetimes = field_validator(*_CLIENT_STATE_DATETIME_FIELDS, mode="before")(
        _normalise_drift_iso
    )

    @field_validator("clarified", mode="before")
    @classmethod
    def reject_null_clarified(cls, v: object) -> object:
        # clarified is NOT NULL in the DB, so an explicit null in the PATCH
        # body would surface as a commit-time IntegrityError (500) instead of
        # a 422.  Omission never reaches this validator — Pydantic skips
        # before-validators for defaulted fields — so exclude_unset semantics
        # ("field absent = no update") are preserved.
        if v is None:
            raise ValueError("clarified cannot be null; omit the field to leave it unchanged")
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

    @field_validator("state")
    @classmethod
    def validate_state(cls, v: str | None) -> str | None:
        if v is not None and v not in STATE_VALUES:
            raise ValueError(f"state must be one of {sorted(STATE_VALUES)}")
        return v


class TagOut(BaseModel):
    id: str
    name: str
    color: str | None
    type: str

    model_config = {"from_attributes": True}


class UserPreferenceCreate(BaseModel):
    id: str | None = None  # Client-side UUID for idempotency
    key: str
    value: str | None = None
    updated_at: datetime

    _normalise_updated_at = field_validator("updated_at", mode="before")(_normalise_drift_iso)


class UserPreferenceUpdate(BaseModel):
    # Both fields are optional in the schema but the connector always sends
    # `updated_at` alongside any `value` change so LWW arbitration has a
    # truthful timestamp.
    value: str | None = None
    updated_at: datetime | None = None

    _normalise_updated_at = field_validator("updated_at", mode="before")(_normalise_drift_iso)


class UserPreferenceOut(BaseModel):
    id: str
    key: str
    value: str | None
    updated_at: datetime

    model_config = {"from_attributes": True}


class TimeLogOut(BaseModel):
    id: str
    user_id: str
    task_id: str
    started_at: datetime
    ended_at: datetime | None
    focus_session_id: str | None

    model_config = {"from_attributes": True}


class FocusSessionOut(BaseModel):
    id: str
    user_id: str
    started_at: datetime
    ended_at: datetime | None
    current_task_id: str | None

    model_config = {"from_attributes": True}


class FocusSessionTaskOut(BaseModel):
    focus_session_id: str
    task_id: str
    position: int
    disposition: str | None = None

    model_config = {"from_attributes": True}


class TodoOut(BaseModel):
    id: str
    title: str
    notes: str | None
    done_at: datetime | None
    priority: int | None
    clarified: bool
    intent: str
    tags: list[TagOut]
    due_date: datetime | None
    created_at: datetime
    updated_at: datetime | None
    time_estimate: int | None
    energy_level: str | None
    capture_source: str | None
    # Client-state columns (migrations 0007/0022/0024)
    last_clarified_at: datetime | None
    time_spent_minutes: int
    next_action_text: str | None
    last_next_action_completion_at: datetime | None
    # Legacy compatibility: state column was dropped in migration 0020; always "next_action".
    state: str = "next_action"

    model_config = {"from_attributes": True}
