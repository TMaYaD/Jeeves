"""SQLAlchemy ORM models for the todos feature.

PowerSync requires standard Postgres tables — no exotic types that would
break replication. UUIDs are stored as TEXT for maximum compatibility with
the PowerSync sync rules.
"""

import uuid
from datetime import UTC, datetime

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base

# ---------------------------------------------------------------------------
# Canonical constant sets — single source of truth shared with schemas.py
# ---------------------------------------------------------------------------

GTD_STATES = ("inbox", "next_action", "waiting_for", "someday_maybe", "done")
TAG_TYPES = ("context", "project", "area", "label")
ENERGY_LEVELS = ("low", "medium", "high")


def _uuid() -> str:
    return str(uuid.uuid4())


class Tag(Base):
    __tablename__ = "tags"
    __table_args__ = (
        Index("ix_tags_type", "type"),
        CheckConstraint("type IN ('context','project','area','label')", name="ck_tags_type"),
    )

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    name: Mapped[str] = mapped_column(String(100), nullable=False)
    color: Mapped[str | None] = mapped_column(String(20))
    type: Mapped[str] = mapped_column(String(20), nullable=False, default="context")
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True, nullable=False)

    todos: Mapped[list["Todo"]] = relationship("Todo", secondary="todo_tags", back_populates="tags")


class TodoTag(Base):
    __tablename__ = "todo_tags"

    # PowerSync-assigned UUID used by the upload handler to delete by entry.id.
    # NULL for server-side inserts; PostgreSQL fills this via the server default
    # added in migration 0006 (gen_random_uuid()).  SQLite test rows stay NULL.
    id: Mapped[str | None] = mapped_column(String, unique=True, nullable=True)
    todo_id: Mapped[str] = mapped_column(
        ForeignKey("todos.id", ondelete="CASCADE"), primary_key=True
    )
    tag_id: Mapped[str] = mapped_column(ForeignKey("tags.id", ondelete="CASCADE"), primary_key=True)
    # Denormalized from todos.user_id so PowerSync can filter junction rows
    # by bucket parameter (see migration 0008 and sync-config.yaml).  Set
    # explicitly at every write call site — we manage TodoTag rows directly
    # (not via the secondary-cascade on Todo.tags) so user_id is always set
    # in the same statement that creates the row.
    user_id: Mapped[str] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )


class Todo(Base):
    __tablename__ = "todos"
    __table_args__ = (
        Index("ix_todos_user_state", "user_id", "state"),
        CheckConstraint(
            "state IN ('inbox','next_action','waiting_for','someday_maybe','done')",
            name="ck_todos_state",
        ),
        CheckConstraint(
            "energy_level IS NULL OR energy_level IN ('low','medium','high')",
            name="ck_todos_energy_level",
        ),
        CheckConstraint(
            "time_spent_minutes >= 0",
            name="ck_todos_time_spent_minutes_nonnegative",
        ),
    )

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    title: Mapped[str] = mapped_column(String(500), nullable=False)
    notes: Mapped[str | None] = mapped_column(Text)
    completed: Mapped[bool] = mapped_column(Boolean, default=False)
    priority: Mapped[int | None] = mapped_column(Integer)
    due_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC)
    )
    updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    state: Mapped[str] = mapped_column(String(50), default="inbox")
    time_estimate: Mapped[int | None] = mapped_column(Integer)  # minutes
    energy_level: Mapped[str | None] = mapped_column(String(20))
    capture_source: Mapped[str | None] = mapped_column(String(50))

    location_id: Mapped[str | None] = mapped_column(ForeignKey("locations.id"))
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True, nullable=False)

    # Client-state columns replicated via PowerSync (migration 0007).
    waiting_for: Mapped[str | None] = mapped_column(Text)
    in_progress_since: Mapped[str | None] = mapped_column(Text)
    time_spent_minutes: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    selected_for_today: Mapped[bool | None] = mapped_column(Boolean)
    daily_selection_date: Mapped[str | None] = mapped_column(Text)

    tags: Mapped[list["Tag"]] = relationship("Tag", secondary="todo_tags", back_populates="todos")
    reminders: Mapped[list["Reminder"]] = relationship("Reminder", back_populates="todo")
    recurrence_rule: Mapped["RecurrenceRule | None"] = relationship(
        "RecurrenceRule", back_populates="todo", uselist=False
    )
    location: Mapped["Location | None"] = relationship("Location", back_populates="todos")


class Reminder(Base):
    __tablename__ = "reminders"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    todo_id: Mapped[str] = mapped_column(ForeignKey("todos.id"), nullable=False)
    type: Mapped[str] = mapped_column(String(20), nullable=False)  # "time" | "location"
    scheduled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    location_id: Mapped[str | None] = mapped_column(ForeignKey("locations.id"))
    on_arrival: Mapped[bool] = mapped_column(Boolean, default=False)
    on_departure: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC)
    )

    todo: Mapped[Todo] = relationship("Todo", back_populates="reminders")


class Location(Base):
    __tablename__ = "locations"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    radius_meters: Mapped[float] = mapped_column(Float, default=100.0)
    address: Mapped[str | None] = mapped_column(String(500))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC)
    )

    todos: Mapped[list[Todo]] = relationship("Todo", back_populates="location")


class RecurrenceRule(Base):
    __tablename__ = "recurrence_rules"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    todo_id: Mapped[str] = mapped_column(ForeignKey("todos.id"), unique=True, nullable=False)
    frequency: Mapped[str] = mapped_column(String(20), nullable=False)
    interval: Mapped[int] = mapped_column(Integer, default=1)
    by_day_of_week: Mapped[str | None] = mapped_column(String(50))  # JSON array as string
    by_day_of_month: Mapped[int | None] = mapped_column(Integer)
    until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    count: Mapped[int | None] = mapped_column(Integer)

    todo: Mapped[Todo] = relationship("Todo", back_populates="recurrence_rule")
