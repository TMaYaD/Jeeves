"""Unit tests for GTD field validators and business logic."""

import pytest
from pydantic import ValidationError

from app.todos.schemas import TagInput, TagType, TodoCreate, TodoUpdate
from app.todos.utils import _infer_tag_type

# ── State validator ───────────────────────────────────────────────────────────


class TestTodoStateValidator:
    def test_valid_states_are_accepted(self) -> None:
        valid = ["inbox", "next_action", "waiting_for", "done"]
        for state in valid:
            t = TodoCreate(title="x", state=state)
            assert t.state == state

    def test_someday_maybe_is_rejected(self) -> None:
        with pytest.raises(ValidationError, match="state must be one of"):
            TodoCreate(title="x", state="someday_maybe")

    def test_invalid_state_raises(self) -> None:
        with pytest.raises(ValidationError, match="state must be one of"):
            TodoCreate(title="x", state="active")

    def test_update_invalid_state_raises(self) -> None:
        with pytest.raises(ValidationError, match="state must be one of"):
            TodoUpdate(state="done_and_dusted")

    def test_update_none_state_allowed(self) -> None:
        t = TodoUpdate(state=None)
        assert t.state is None


class TestTodoIntentValidator:
    def test_valid_intents_are_accepted(self) -> None:
        for intent in ["next", "maybe", "trash"]:
            t = TodoCreate(title="x", intent=intent)
            assert t.intent == intent

    def test_default_intent_is_next(self) -> None:
        t = TodoCreate(title="x")
        assert t.intent == "next"

    def test_invalid_intent_raises(self) -> None:
        with pytest.raises(ValidationError, match="intent must be one of"):
            TodoCreate(title="x", intent="someday")

    def test_update_intent_accepted(self) -> None:
        t = TodoUpdate(intent="maybe")
        assert t.intent == "maybe"

    def test_update_none_intent_allowed(self) -> None:
        t = TodoUpdate(intent=None)
        assert t.intent is None


# ── Energy level validator ────────────────────────────────────────────────────


class TestEnergyLevelValidator:
    def test_valid_energy_levels_accepted(self) -> None:
        for level in ["low", "medium", "high"]:
            t = TodoCreate(title="x", energy_level=level)
            assert t.energy_level == level

    def test_invalid_energy_level_raises(self) -> None:
        with pytest.raises(ValidationError, match="energy_level must be one of"):
            TodoCreate(title="x", energy_level="extreme")

    def test_none_energy_level_allowed(self) -> None:
        t = TodoCreate(title="x", energy_level=None)
        assert t.energy_level is None


# ── Tag type validator ────────────────────────────────────────────────────────


class TestTagTypeValidator:
    def test_valid_tag_types_accepted(self) -> None:
        for t in ["context", "project", "area", "label"]:
            tag = TagInput(name="x", type=t)  # type: ignore[arg-type]
            assert tag.type.value == t

    def test_invalid_tag_type_raises(self) -> None:
        with pytest.raises(ValidationError, match="tag type must be one of"):
            TagInput(name="x", type="bucket")  # type: ignore[arg-type]

    def test_default_tag_type_is_context(self) -> None:
        tag = TagInput(name="@office")
        assert tag.type == TagType.context


# ── Tag type inference ────────────────────────────────────────────────────────


class TestResolveTagsAssignsType:
    def test_at_prefix_infers_context(self) -> None:
        assert _infer_tag_type("@office") == "context"
        assert _infer_tag_type("@home") == "context"

    def test_bare_word_infers_label(self) -> None:
        assert _infer_tag_type("urgent") == "label"
        assert _infer_tag_type("Renovation") == "label"

    def test_explicit_type_in_tag_input(self) -> None:
        tag = TagInput(name="Renovation", type=TagType.project)
        assert tag.type == TagType.project
        assert tag.name == "Renovation"


# ── Single-project enforcement (schema level) ─────────────────────────────────


class TestSingleProjectEnforcementSchema:
    def test_two_project_tags_in_create_are_invalid(self) -> None:
        """_resolve_tags (in the route) enforces this; schema passes multiple tags through."""
        # Schema itself doesn't block it — the route layer enforces the invariant.
        # Here we just verify that TagInput correctly marks items as 'project'.
        t = TodoCreate(
            title="x",
            tags=[
                TagInput(name="ProjectA", type=TagType.project),
                TagInput(name="ProjectB", type=TagType.project),
            ],
        )
        project_tags = [
            tag for tag in t.tags if isinstance(tag, TagInput) and tag.type == TagType.project
        ]
        assert len(project_tags) == 2  # schema passes; route raises 422
