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
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base

# ---------------------------------------------------------------------------
# Canonical constant sets — single source of truth shared with schemas.py
# ---------------------------------------------------------------------------

INTENT_VALUES = ("next", "maybe", "trash")
TAG_TYPES = ("context", "project", "area", "label", "person")
ENERGY_LEVELS = ("low", "medium", "high")
DISPOSITION_VALUES = ("rollover", "leave", "maybe")


def _uuid() -> str:
    return str(uuid.uuid4())


class Tag(Base):
    __tablename__ = "tags"
    __table_args__ = (
        Index("ix_tags_type", "type"),
        CheckConstraint(
            "type IN ('context','project','area','label','person')",
            name="ck_tags_type",
        ),
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
        Index("ix_todos_user_done_at", "user_id", "done_at"),
        CheckConstraint(
            "intent IN ('next','maybe','trash')",
            name="ck_todos_intent",
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
    done_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    priority: Mapped[int | None] = mapped_column(Integer)
    due_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC)
    )
    updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    clarified: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    intent: Mapped[str] = mapped_column(
        String(20),
        nullable=False,
        default="next",
        server_default="next",
    )
    time_estimate: Mapped[int | None] = mapped_column(Integer)  # minutes
    energy_level: Mapped[str | None] = mapped_column(String(20))
    capture_source: Mapped[str | None] = mapped_column(String(50))

    location_id: Mapped[str | None] = mapped_column(ForeignKey("locations.id"))
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True, nullable=False)

    # Client-state columns replicated via PowerSync (migrations 0007/0022/0024).
    last_clarified_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    time_spent_minutes: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    # The current next-action cursor; NULL = Actionless (migration 0024).
    next_action_text: Mapped[str | None] = mapped_column(Text, nullable=True)
    # When a focus session last closed with this task non-done (migration 0024).
    last_next_action_completion_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    tags: Mapped[list["Tag"]] = relationship("Tag", secondary="todo_tags", back_populates="todos")
    time_logs: Mapped[list["TimeLog"]] = relationship("TimeLog", back_populates="todo")
    reminders: Mapped[list["Reminder"]] = relationship("Reminder", back_populates="todo")
    recurrence_rule: Mapped["RecurrenceRule | None"] = relationship(
        "RecurrenceRule", back_populates="todo", uselist=False
    )
    location: Mapped["Location | None"] = relationship("Location", back_populates="todos")


class Capture(Base):
    """A raw Inbox capture, split out of the conflated todos table (ADR-0006).

    A Capture is an unclarified thought: ``clarified_at IS NULL`` means it is
    still in the Inbox.  Clarifying a capture stamps ``clarified_at`` and links
    it to one or more Outcomes (todos) via capture_outcomes.
    """

    __tablename__ = "captures"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    title: Mapped[str] = mapped_column(String(500), nullable=False)
    notes: Mapped[str | None] = mapped_column(Text)
    capture_source: Mapped[str | None] = mapped_column(String(50))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC)
    )
    # NULL = still in the Inbox (the whole point of the split).
    clarified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True, nullable=False)


class CaptureOutcome(Base):
    """Junction linking a Capture to an Outcome (todo) produced while clarifying.

    Mirrors the todo_tags junction pattern but carries a client-owned
    ``created_at`` provenance timestamp (when the link was made) that must
    round-trip through the connector.
    """

    __tablename__ = "capture_outcomes"

    # PowerSync-assigned UUID identifying the synced row.  NULL for server-side
    # inserts; PostgreSQL fills this via the server default added in migration
    # 0026 (gen_random_uuid()).  SQLite test rows stay NULL.
    id: Mapped[str | None] = mapped_column(String, unique=True, nullable=True)
    capture_id: Mapped[str] = mapped_column(
        ForeignKey("captures.id", ondelete="CASCADE"), primary_key=True
    )
    outcome_id: Mapped[str] = mapped_column(
        ForeignKey("todos.id", ondelete="CASCADE"), primary_key=True
    )
    # Provenance: when the link was made.  Client-owned, must round-trip.
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=lambda: datetime.now(UTC)
    )
    # Denormalized from captures.user_id so PowerSync can filter junction rows
    # by bucket parameter.  Set explicitly at every write call site.
    user_id: Mapped[str] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )


class CaptureTag(Base):
    """Junction linking a Capture to a Tag — mirrors todo_tags exactly."""

    __tablename__ = "capture_tags"

    # PowerSync-assigned UUID identifying the synced row.  NULL for server-side
    # inserts; PostgreSQL fills this via the server default added in migration
    # 0026 (gen_random_uuid()).  SQLite test rows stay NULL.
    id: Mapped[str | None] = mapped_column(String, unique=True, nullable=True)
    capture_id: Mapped[str] = mapped_column(
        ForeignKey("captures.id", ondelete="CASCADE"), primary_key=True
    )
    tag_id: Mapped[str] = mapped_column(ForeignKey("tags.id", ondelete="CASCADE"), primary_key=True)
    # Denormalized from captures.user_id so PowerSync can filter junction rows
    # by bucket parameter.  Set explicitly at every write call site.
    user_id: Mapped[str] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )


class FocusSession(Base):
    __tablename__ = "focus_sessions"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), nullable=False, index=True)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    current_task_id: Mapped[str | None] = mapped_column(ForeignKey("todos.id"), nullable=True)


class FocusSessionTask(Base):
    __tablename__ = "focus_session_tasks"
    __table_args__ = (
        CheckConstraint(
            "disposition IS NULL OR disposition IN ('rollover', 'leave', 'maybe')",
            name="ck_focus_session_tasks_disposition",
        ),
    )

    # PowerSync-assigned UUID identifying the synced row.  NULL for server-side
    # inserts; PostgreSQL fills this via the server default added in migration
    # 0025 (gen_random_uuid()).  SQLite test rows stay NULL.
    id: Mapped[str | None] = mapped_column(String, unique=True, nullable=True)
    focus_session_id: Mapped[str] = mapped_column(ForeignKey("focus_sessions.id"), primary_key=True)
    task_id: Mapped[str] = mapped_column(ForeignKey("todos.id"), primary_key=True)
    position: Mapped[int] = mapped_column(Integer, nullable=False)
    disposition: Mapped[str | None] = mapped_column(Text, nullable=True)
    # Denormalized from focus_sessions.user_id so PowerSync can filter junction
    # rows by bucket parameter (see migration 0025 and sync-config.yaml).  Set
    # explicitly at every write call site.
    user_id: Mapped[str] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )


class FocusSessionDisposition(Base):
    """Durable home for Review-phase Dispositions on off-Plan engaged Outcomes.

    Dispositions partition by membership class (ADR-0016): a Plan member's
    Disposition lives on ``focus_session_tasks.disposition``; an off-Plan
    engaged Outcome has no ``focus_session_tasks`` row (the Plan never
    auto-grows — ADR-0002), so its Disposition is recorded here, keyed by the
    (FocusSession, Outcome) pair.  Mirrors ``focus_session_tasks`` conventions:
    a PowerSync-managed ``id`` column, denormalized ``user_id`` for per-user
    bucketing, and the disposition CHECK constraint.
    """

    __tablename__ = "focus_session_dispositions"
    __table_args__ = (
        CheckConstraint(
            "disposition IS NULL OR disposition IN ('rollover', 'leave', 'maybe')",
            name="ck_focus_session_dispositions_disposition",
        ),
    )

    # PowerSync-assigned UUID identifying the synced row.  NULL for server-side
    # inserts; PostgreSQL fills this via the server default added in migration
    # 0027 (gen_random_uuid()).  SQLite test rows stay NULL.
    id: Mapped[str | None] = mapped_column(String, unique=True, nullable=True)
    focus_session_id: Mapped[str] = mapped_column(ForeignKey("focus_sessions.id"), primary_key=True)
    task_id: Mapped[str] = mapped_column(ForeignKey("todos.id"), primary_key=True)
    disposition: Mapped[str | None] = mapped_column(Text, nullable=True)
    # Denormalized from focus_sessions.user_id so PowerSync can filter junction
    # rows by bucket parameter (see migration 0027 and sync-config.yaml).  Set
    # explicitly at every write call site.
    user_id: Mapped[str] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )


class TimeLog(Base):
    __tablename__ = "time_logs"
    __table_args__ = (
        Index("ix_time_logs_user_id", "user_id"),
        Index("ix_time_logs_task_id", "task_id"),
    )

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    task_id: Mapped[str] = mapped_column(ForeignKey("todos.id", ondelete="CASCADE"), nullable=False)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    focus_session_id: Mapped[str | None] = mapped_column(
        ForeignKey("focus_sessions.id"), nullable=True
    )

    todo: Mapped["Todo"] = relationship("Todo", back_populates="time_logs")


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


class UserPreference(Base):
    """Cross-device synced key-value preference store (one row per key per user).

    `id` is a client-generated UUID. `UNIQUE(user_id, key)` enforces one value
    per key per user. `value` is nullable TEXT storing JSON-serialised scalars;
    NULL is a tombstone. `updated_at` drives LWW arbitration at sign-in.
    """

    __tablename__ = "user_preferences"
    __table_args__ = (UniqueConstraint("user_id", "key", name="uq_user_preferences_user_key"),)

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    user_id: Mapped[str] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    key: Mapped[str] = mapped_column(String(100), nullable=False)
    value: Mapped[str | None] = mapped_column(Text, nullable=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=lambda: datetime.now(UTC)
    )
