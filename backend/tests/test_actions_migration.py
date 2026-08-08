"""Tests for Alembic 0028 (add_actions_table) — issue #471.

Two things this migration must get right, both verifiable on SQLite:

- The deterministic backfill id is a fixed cross-language constant (the golden
  vector), so the server backfill and the Dart client backfill converge on one
  row (ADR-0019). The same constant is asserted in the Dart suite
  (app/test/database/action_backfill_id_test.dart).
- The data backfill is idempotent: it mints one current Action per
  Outcome with a non-blank next_action_text, nothing for blank/whitespace/NULL,
  and a re-run is a no-op (the WHERE NOT EXISTS guard), never a duplicate.
"""

import importlib.util
from pathlib import Path
from types import ModuleType

import sqlalchemy as sa
from alembic.operations import Operations
from alembic.runtime.migration import MigrationContext
from sqlalchemy.pool import StaticPool

_MIGRATION_0028_PATH = (
    Path(__file__).resolve().parents[1] / "alembic" / "versions" / "0028_add_actions_table.py"
)

# Golden vector: uuid5(NAMESPACE_URL, "jeeves://action/backfill/<todo_id>") for
# the fixed todo id below. Mirrored byte-for-byte in the Dart suite.
_GOLDEN_TODO_ID = "00000000-0000-0000-0000-000000000001"
_GOLDEN_ACTION_ID = "dfe9f9e7-e548-54dc-bb19-e13213ec2405"


def _load_migration_0028() -> ModuleType:
    spec = importlib.util.spec_from_file_location("migration_0028", _MIGRATION_0028_PATH)
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
                "  next_action_text TEXT,"
                "  energy_level TEXT,"
                "  time_estimate INTEGER,"
                "  last_clarified_at TEXT,"
                "  created_at TEXT,"
                "  user_id TEXT"
                ")"
            )
        )
    return engine


def _seed_todo(engine: sa.engine.Engine, **cols: object) -> None:
    keys = ", ".join(cols)
    placeholders = ", ".join(f":{k}" for k in cols)
    with engine.begin() as conn:
        conn.execute(sa.text(f"INSERT INTO todos ({keys}) VALUES ({placeholders})"), cols)


def _apply_0028(engine: sa.engine.Engine) -> None:
    module = _load_migration_0028()
    with engine.begin() as conn:
        ctx = MigrationContext.configure(conn)
        with Operations.context(ctx):
            module.upgrade()


def _actions(engine: sa.engine.Engine) -> list[dict[str, object]]:
    with engine.connect() as conn:
        return [dict(r._mapping) for r in conn.execute(sa.text("SELECT * FROM actions"))]


# --- Golden vector -----------------------------------------------------------


def test_backfill_id_golden_vector() -> None:
    module = _load_migration_0028()
    assert module._backfill_action_id_for(_GOLDEN_TODO_ID) == _GOLDEN_ACTION_ID


# --- Backfill correctness ----------------------------------------------------


def test_backfill_mints_current_action_for_nonblank_cursor() -> None:
    engine = _engine_with_todos()
    _seed_todo(
        engine,
        id="t1",
        next_action_text="call the plumber",
        energy_level="low",
        time_estimate=15,
        last_clarified_at="2026-07-01T10:00:00.000Z",
        created_at="2026-06-01T09:00:00.000Z",
        user_id="u1",
    )
    _apply_0028(engine)

    rows = _actions(engine)
    assert len(rows) == 1
    row = rows[0]
    module = _load_migration_0028()
    assert row["id"] == module._backfill_action_id_for("t1")
    assert row["outcome_id"] == "t1"
    assert row["user_id"] == "u1"
    assert row["text"] == "call the plumber"
    assert row["role"] == "current"
    assert row["energy_level"] == "low"
    assert row["time_estimate"] == 15
    assert row["position"] is None
    assert row["updated_at"] is None
    assert row["done_at"] is None
    # created_at derives from last_clarified_at (the cursor-set proxy).
    assert row["created_at"] == "2026-07-01T10:00:00.000Z"


def test_backfill_created_at_falls_back_to_todo_created_at() -> None:
    engine = _engine_with_todos()
    _seed_todo(
        engine,
        id="t1",
        next_action_text="x",
        last_clarified_at=None,
        created_at="2026-06-01T09:00:00.000Z",
        user_id="u1",
    )
    _apply_0028(engine)
    assert _actions(engine)[0]["created_at"] == "2026-06-01T09:00:00.000Z"


def test_backfill_skips_blank_and_null_cursors() -> None:
    engine = _engine_with_todos()
    _seed_todo(engine, id="null", next_action_text=None, created_at="c", user_id="u1")
    _seed_todo(engine, id="empty", next_action_text="", created_at="c", user_id="u1")
    # Space-only: SQL TRIM reduces it to '' so it is Actionless. (Both the server
    # and client backfills use SQLite TRIM, which strips U+0020 only — the Dart
    # write path already coerces other-whitespace-only cursors to NULL upstream,
    # so a tab-only value never reaches storage.)
    _seed_todo(engine, id="ws", next_action_text="     ", created_at="c", user_id="u1")
    _seed_todo(engine, id="real", next_action_text="do it", created_at="c", user_id="u1")
    _apply_0028(engine)

    rows = _actions(engine)
    assert len(rows) == 1
    assert rows[0]["outcome_id"] == "real"


def test_backfill_rerun_is_a_noop() -> None:
    engine = _engine_with_todos()
    _seed_todo(engine, id="t1", next_action_text="x", created_at="c", user_id="u1")
    _apply_0028(engine)
    # Re-running the whole migration (schema guard + backfill) must not
    # duplicate the row (WHERE NOT EXISTS guard + has_table guard).
    _apply_0028(engine)
    assert len(_actions(engine)) == 1


def test_rerun_repairs_missing_indexes() -> None:
    engine = _engine_with_todos()
    _seed_todo(engine, id="t1", next_action_text="x", created_at="c", user_id="u1")
    _apply_0028(engine)
    # Simulate a partially-applied forward run: the table exists but its indexes
    # were never created (or drifted away). Because the index creation is guarded
    # independently of has_table, a re-run must repair both — the migration's
    # re-runnable recovery contract.
    with engine.begin() as conn:
        conn.execute(sa.text("DROP INDEX ix_actions_user_id"))
        conn.execute(sa.text("DROP INDEX ix_actions_outcome_id"))
    dropped = {ix["name"] for ix in sa.inspect(engine).get_indexes("actions")}
    assert "ix_actions_user_id" not in dropped
    assert "ix_actions_outcome_id" not in dropped

    _apply_0028(engine)

    repaired = {ix["name"] for ix in sa.inspect(engine).get_indexes("actions")}
    assert "ix_actions_user_id" in repaired
    assert "ix_actions_outcome_id" in repaired
    # Repair is index-only: it must not duplicate the backfilled row.
    assert len(_actions(engine)) == 1


def test_backfill_text_copied_verbatim_no_trim() -> None:
    engine = _engine_with_todos()
    _seed_todo(engine, id="t1", next_action_text="  keep spaces  ", created_at="c", user_id="u1")
    _apply_0028(engine)
    # Non-blank (has non-space chars) so it qualifies; text is copied verbatim.
    assert _actions(engine)[0]["text"] == "  keep spaces  "
