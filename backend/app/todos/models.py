"""SQLAlchemy ORM models for the todos feature.

Electric SQL requires standard Postgres tables — no exotic types that would
break replication. UUIDs are stored as TEXT for maximum compatibility with
the Electric client.
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

GTD_STATES = ("inbox", "next_action", "waiting_for", "scheduled", "someday_maybe", "done")
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

    todo_id: Mapped[str] = mapped_column(
        ForeignKey("todos.id", ondelete="CASCADE"), primary_key=True
    )
    tag_id: Mapped[str] = mapped_column(ForeignKey("tags.id", ondelete="CASCADE"), primary_key=True)


class Todo(Base):
    __tablename__ = "todos"
    __table_args__ = (
        Index("ix_todos_user_state", "user_id", "state"),
        CheckConstraint(
            "state IN ('inbox','next_action','waiting_for','scheduled','someday_maybe','done')",
            name="ck_todos_state",
        ),
        CheckConstraint(
            "energy_level IS NULL OR energy_level IN ('low','medium','high')",
            name="ck_todos_energy_level",
        ),
    )

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    title: Mapped[str] = mapped_column(String(500), nullable=False)
    notes: Mapped[str | None] = mapped_column(Text)
    completed: Mapped[bool] = mapped_column(Boolean, default=False)
    priority: Mapped[int | None] = mapped_column(Integer)
    due_date: Mapped[datetime | None] = mapped_column(DateTime)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(UTC))
    updated_at: Mapped[datetime | None] = mapped_column(DateTime)

    state: Mapped[str] = mapped_column(String(50), default="inbox")
    time_estimate: Mapped[int | None] = mapped_column(Integer)  # minutes
    energy_level: Mapped[str | None] = mapped_column(String(20))
    capture_source: Mapped[str | None] = mapped_column(String(50))

    location_id: Mapped[str | None] = mapped_column(ForeignKey("locations.id"))
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True, nullable=False)

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
    scheduled_at: Mapped[datetime | None] = mapped_column(DateTime)
    location_id: Mapped[str | None] = mapped_column(ForeignKey("locations.id"))
    on_arrival: Mapped[bool] = mapped_column(Boolean, default=False)
    on_departure: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(UTC))

    todo: Mapped[Todo] = relationship("Todo", back_populates="reminders")


class Location(Base):
    __tablename__ = "locations"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    radius_meters: Mapped[float] = mapped_column(Float, default=100.0)
    address: Mapped[str | None] = mapped_column(String(500))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(UTC))

    todos: Mapped[list[Todo]] = relationship("Todo", back_populates="location")


class RecurrenceRule(Base):
    __tablename__ = "recurrence_rules"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    todo_id: Mapped[str] = mapped_column(ForeignKey("todos.id"), unique=True, nullable=False)
    frequency: Mapped[str] = mapped_column(String(20), nullable=False)
    interval: Mapped[int] = mapped_column(Integer, default=1)
    by_day_of_week: Mapped[str | None] = mapped_column(String(50))  # JSON array as string
    by_day_of_month: Mapped[int | None] = mapped_column(Integer)
    until: Mapped[datetime | None] = mapped_column(DateTime)
    count: Mapped[int | None] = mapped_column(Integer)

    todo: Mapped[Todo] = relationship("Todo", back_populates="recurrence_rule")
