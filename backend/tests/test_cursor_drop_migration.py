"""Tests for Alembic 0030 (drop todos.next_action_text) — issue #525, ADR-0024.

Four things this migration must get right, all verifiable on SQLite:

- The column is actually gone (the whole point).
- **Every other column's data survives.** This is the assertion that would catch
  a table-rebuild drop that lost or shifted data, which is what
  ``ALTER TABLE … DROP COLUMN`` is on the storage engines that do not support
  it natively.  The seeded row therefore carries non-NULL, non-default values
  everywhere — a row of NULLs would pass whether or not the drop preserved
  anything.
- A re-run no-ops (schema/version drift, issue #382; the 0024/0029 guard
  precedent), so ``alembic upgrade`` heals a mis-stamped version instead of
  crash-looping.
- ``downgrade()`` restores the *shape* and nothing else: the column comes back
  nullable and empty.  ADR-0024 accepts that the text is unrecoverable; this
  test pins that the downgrade does not pretend otherwise.

Plus one structural check: 0030 chains from 0029 and the revision graph stays
linear, so ``alembic upgrade head`` is unambiguous.
"""

import importlib.util
from pathlib import Path
from types import ModuleType

import pytest
import sqlalchemy as sa
from alembic.operations import Operations
from alembic.runtime.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy.exc import OperationalError
from sqlalchemy.pool import StaticPool

from app import migrate

_MIGRATION_0030_PATH = (
    Path(__file__).resolve().parents[1] / "alembic" / "versions" / "0030_drop_next_action_text.py"
)

# Non-default values in every surviving column: a NULL/zero seed would pass
# whether or not the drop preserved data.
_SEED = {
    "id": "t1",
    "title": "Fix the gate latch",
    "notes": "the top hinge is the loose one",
    "next_action_text": "call the hardware shop",
    "energy_level": "low",
    "time_estimate": 15,
    "time_spent_minutes": 40,
    "last_clarified_at": "2026-07-01T10:00:00.000Z",
    "last_next_action_completion_at": "2026-07-02T11:00:00.000Z",
    "created_at": "2026-06-01T09:00:00.000Z",
    "user_id": "u1",
}


def _load_migration_0030() -> ModuleType:
    spec = importlib.util.spec_from_file_location("migration_0030", _MIGRATION_0030_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _engine_with_todos() -> sa.engine.Engine:
    engine = sa.create_engine("sqlite://", poolclass=StaticPool)
    with engine.begin() as conn:
        conn.execute(
            sa.text(
                "CREATE TABLE todos ("
                "  id TEXT PRIMARY KEY,"
                "  title TEXT,"
                "  notes TEXT,"
                "  next_action_text TEXT,"
                "  energy_level TEXT,"
                "  time_estimate INTEGER,"
                "  time_spent_minutes INTEGER,"
                "  last_clarified_at TEXT,"
                "  last_next_action_completion_at TEXT,"
                "  created_at TEXT,"
                "  user_id TEXT"
                ")"
            )
        )
        keys = ", ".join(_SEED)
        placeholders = ", ".join(f":{k}" for k in _SEED)
        conn.execute(sa.text(f"INSERT INTO todos ({keys}) VALUES ({placeholders})"), _SEED)
    return engine


def _run(engine: sa.engine.Engine, direction: str) -> None:
    module = _load_migration_0030()
    with engine.begin() as conn:
        ctx = MigrationContext.configure(conn)
        with Operations.context(ctx):
            getattr(module, direction)()


def _todo_columns(engine: sa.engine.Engine) -> dict[str, dict[str, object]]:
    with engine.connect() as conn:
        return {col["name"]: dict(col) for col in sa.inspect(conn).get_columns("todos")}


def _todo_row(engine: sa.engine.Engine) -> dict[str, object]:
    # Raw SQL, no ORM: the model no longer declares the column, so an ORM read
    # could not tell a successful drop from a silently emptied table.
    with engine.connect() as conn:
        return dict(conn.execute(sa.text("SELECT * FROM todos")).one()._mapping)


# --- The drop ----------------------------------------------------------------


def test_upgrade_drops_the_cursor_column() -> None:
    engine = _engine_with_todos()
    _run(engine, "upgrade")
    assert "next_action_text" not in _todo_columns(engine)


def test_upgrade_preserves_every_other_column() -> None:
    engine = _engine_with_todos()
    _run(engine, "upgrade")
    row = _todo_row(engine)
    expected = {k: v for k, v in _SEED.items() if k != "next_action_text"}
    assert row == expected


def test_upgrade_rerun_is_a_noop() -> None:
    # Drifted volume: the schema is already at 0030 while alembic_version still
    # says 0029.  Re-running must heal the stamp, not raise "no such column".
    engine = _engine_with_todos()
    _run(engine, "upgrade")
    _run(engine, "upgrade")
    assert "next_action_text" not in _todo_columns(engine)
    assert _todo_row(engine)["title"] == "Fix the gate latch"


def test_upgrade_is_needed_for_the_rerun_test_to_mean_anything() -> None:
    # Proves the guard in upgrade() is what makes the re-run safe, rather than
    # SQLite quietly tolerating a duplicate drop.
    engine = _engine_with_todos()
    _run(engine, "upgrade")
    with engine.begin() as conn, pytest.raises(OperationalError):
        conn.execute(sa.text("ALTER TABLE todos DROP COLUMN next_action_text"))


# --- The downgrade -----------------------------------------------------------


def test_downgrade_restores_the_shape_but_not_the_text() -> None:
    engine = _engine_with_todos()
    _run(engine, "upgrade")
    _run(engine, "downgrade")
    cols = _todo_columns(engine)
    assert isinstance(cols["next_action_text"]["type"], sa.String)
    assert cols["next_action_text"]["nullable"]
    # The text is gone for good — ADR-0024's accepted loss, stated in the
    # downgrade docstring.  A downgrade that appeared to restore it would be
    # lying about what upgrade() destroyed.
    assert _todo_row(engine)["next_action_text"] is None
    assert _todo_row(engine)["title"] == "Fix the gate latch"


def test_downgrade_rerun_is_a_noop() -> None:
    engine = _engine_with_todos()
    _run(engine, "upgrade")
    _run(engine, "downgrade")
    _run(engine, "downgrade")
    assert "next_action_text" in _todo_columns(engine)


# --- Chain -------------------------------------------------------------------


def test_0030_chains_from_0029_and_the_graph_stays_linear() -> None:
    module = _load_migration_0030()
    assert module.revision == "0030"
    assert module.down_revision == "0029"
    # One head, whatever the latest revision happens to be: a branch would make
    # ``alembic upgrade head`` ambiguous, which is the failure worth catching.
    script = ScriptDirectory.from_config(migrate._alembic_config())
    assert len(script.get_heads()) == 1
