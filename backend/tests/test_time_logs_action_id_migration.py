"""Tests for Alembic 0029 (time_logs.action_id) — issue #476.

The migration is additive and re-runnable: it adds a nullable
``action_id`` column plus its index to ``time_logs``, backfills nothing (legacy
rows keep NULL), and a re-run must no-op rather than crash on a duplicate
column/index.  All verifiable on SQLite.
"""

import importlib.util
from pathlib import Path
from types import ModuleType

import sqlalchemy as sa
from alembic.operations import Operations
from alembic.runtime.migration import MigrationContext
from sqlalchemy.pool import StaticPool

_MIGRATION_0029_PATH = (
    Path(__file__).resolve().parents[1] / "alembic" / "versions" / "0029_time_logs_action_id.py"
)


def _load_migration_0029() -> ModuleType:
    spec = importlib.util.spec_from_file_location("migration_0029", _MIGRATION_0029_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _engine_with_time_logs() -> sa.engine.Engine:
    engine = sa.create_engine("sqlite://", poolclass=StaticPool)
    with engine.begin() as conn:
        conn.execute(
            sa.text(
                "CREATE TABLE time_logs ("
                "  id TEXT PRIMARY KEY,"
                "  user_id TEXT,"
                "  task_id TEXT,"
                "  started_at TEXT,"
                "  ended_at TEXT,"
                "  focus_session_id TEXT"
                ")"
            )
        )
    return engine


def _seed_log(engine: sa.engine.Engine, **cols: object) -> None:
    keys = ", ".join(cols)
    placeholders = ", ".join(f":{k}" for k in cols)
    with engine.begin() as conn:
        conn.execute(sa.text(f"INSERT INTO time_logs ({keys}) VALUES ({placeholders})"), cols)


def _apply_0029(engine: sa.engine.Engine) -> None:
    module = _load_migration_0029()
    with engine.begin() as conn:
        ctx = MigrationContext.configure(conn)
        with Operations.context(ctx):
            module.upgrade()


def _columns(engine: sa.engine.Engine) -> set[str]:
    return {col["name"] for col in sa.inspect(engine).get_columns("time_logs")}


def _logs(engine: sa.engine.Engine) -> list[dict[str, object]]:
    with engine.connect() as conn:
        return [dict(r._mapping) for r in conn.execute(sa.text("SELECT * FROM time_logs"))]


def test_adds_nullable_action_id_column_and_index() -> None:
    engine = _engine_with_time_logs()
    assert "action_id" not in _columns(engine)

    _apply_0029(engine)

    assert "action_id" in _columns(engine)
    index_names = {ix["name"] for ix in sa.inspect(engine).get_indexes("time_logs")}
    assert "ix_time_logs_action_id" in index_names


def test_legacy_rows_keep_null_action_id_no_backfill() -> None:
    engine = _engine_with_time_logs()
    _seed_log(
        engine,
        id="log-1",
        user_id="u1",
        task_id="t1",
        started_at="2026-07-01T09:00:00.000Z",
        ended_at="2026-07-01T09:30:00.000Z",
        focus_session_id=None,
    )

    _apply_0029(engine)

    rows = _logs(engine)
    assert len(rows) == 1
    assert rows[0]["id"] == "log-1"
    assert rows[0]["task_id"] == "t1"
    # No backfill: a pre-Action-era row keeps action_id NULL.
    assert rows[0]["action_id"] is None


def test_rerun_is_a_noop() -> None:
    engine = _engine_with_time_logs()
    _seed_log(engine, id="log-1", user_id="u1", task_id="t1", started_at="s")

    _apply_0029(engine)
    # Re-running must no-op (column + index guards) rather than crash on a
    # duplicate column/index — the drift-healing recovery contract.
    _apply_0029(engine)

    assert "action_id" in _columns(engine)
    index_names = {ix["name"] for ix in sa.inspect(engine).get_indexes("time_logs")}
    assert "ix_time_logs_action_id" in index_names
    assert len(_logs(engine)) == 1
