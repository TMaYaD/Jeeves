"""Pydantic schemas for the Nirvana import pipeline."""

from typing import Literal

from pydantic import BaseModel


class NirvanaItem(BaseModel):
    """Format-agnostic intermediate representation of a single Nirvana row."""

    id: str
    name: str
    type: Literal["task", "project"]
    state: str  # normalised GTD state: "inbox", "next_action", "done", etc.
    completed: bool
    notes: str | None
    tags: list[str]
    energy_level: str | None  # "low" | "medium" | "high" | None
    time_estimate: int | None  # minutes; None when zero/absent
    due_date: str | None  # ISO-8601 date string or None
    parent_id: str | None  # UUID reference (JSON format)
    parent_name: str | None  # project name reference (CSV format)
    waiting_for: str | None


class ImportResult(BaseModel):
    imported_count: int
    skipped_count: int
    project_tags_created: int
