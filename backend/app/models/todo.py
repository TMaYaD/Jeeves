"""SQLAlchemy ORM models.

Electric SQL requires standard Postgres tables — no exotic types that would
break replication. UUIDs are stored as TEXT for maximum compatibility with
the Electric client.
"""

import uuid
from datetime import UTC, datetime

from sqlalchemy import Boolean, DateTime, Float, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base


def _uuid() -> str:
    return str(uuid.uuid4())


class TodoList(Base):
    __tablename__ = "todo_lists"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    color: Mapped[str | None] = mapped_column(String(20))
    icon_name: Mapped[str | None] = mapped_column(String(100))
    is_archived: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(UTC))
    updated_at: Mapped[datetime | None] = mapped_column(DateTime)

    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True, nullable=False)

    todos: Mapped[list["Todo"]] = relationship("Todo", back_populates="list")


class Todo(Base):
    __tablename__ = "todos"

    id: Mapped[str] = mapped_column(String, primary_key=True, default=_uuid)
    title: Mapped[str] = mapped_column(String(500), nullable=False)
    notes: Mapped[str | None] = mapped_column(Text)
    completed: Mapped[bool] = mapped_column(Boolean, default=False)
    priority: Mapped[int | None] = mapped_column(Integer)
    due_date: Mapped[datetime | None] = mapped_column(DateTime)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(UTC))
    updated_at: Mapped[datetime | None] = mapped_column(DateTime)

    list_id: Mapped[str | None] = mapped_column(ForeignKey("todo_lists.id"))
    location_id: Mapped[str | None] = mapped_column(ForeignKey("locations.id"))
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True, nullable=False)

    list: Mapped[TodoList | None] = relationship("TodoList", back_populates="todos")
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
