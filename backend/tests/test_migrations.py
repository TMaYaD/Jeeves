"""Tests for schema/version drift resilience at startup (issue #382).

Two layers:

- Migration 0024 must be idempotent: re-running it against a schema that
  already contains its columns no-ops (letting ``alembic upgrade`` heal the
  version stamp) instead of raising DuplicateColumnError.
- The startup migration runner (``python -m app.migrate``) classifies drift
  into actionable failures instead of opaque crash-loop tracebacks.
"""

import importlib.util
from pathlib import Path
from types import ModuleType

import pytest
import sqlalchemy as sa
from alembic.config import Config
from alembic.operations import Operations
from alembic.runtime.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy.exc import ProgrammingError
from sqlalchemy.pool import StaticPool

from app import migrate

# --- Migration 0024 idempotency ---------------------------------------------

_MIGRATION_0024_PATH = (
    Path(__file__).resolve().parents[1] / "alembic" / "versions" / "0024_reclarify_surface.py"
)


def _load_migration_0024() -> ModuleType:
    spec = importlib.util.spec_from_file_location("migration_0024", _MIGRATION_0024_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _engine_with_todos(ddl: str) -> sa.engine.Engine:
    engine = sa.create_engine("sqlite://", poolclass=StaticPool)
    with engine.begin() as conn:
        conn.execute(sa.text(ddl))
    return engine


def _apply_0024(engine: sa.engine.Engine) -> None:
    module = _load_migration_0024()
    with engine.begin() as conn:
        ctx = MigrationContext.configure(conn)
        with Operations.context(ctx):
            module.upgrade()


def _todo_columns(engine: sa.engine.Engine) -> dict[str, dict[str, object]]:
    with engine.connect() as conn:
        return {col["name"]: dict(col) for col in sa.inspect(conn).get_columns("todos")}


def _assert_0024_columns(engine: sa.engine.Engine) -> None:
    cols = _todo_columns(engine)
    assert isinstance(cols["next_action_text"]["type"], sa.String)
    assert cols["next_action_text"]["nullable"]
    assert isinstance(cols["last_next_action_completion_at"]["type"], sa.DateTime)
    assert cols["last_next_action_completion_at"]["nullable"]


def test_0024_adds_both_columns_on_fresh_schema() -> None:
    engine = _engine_with_todos("CREATE TABLE todos (id TEXT PRIMARY KEY)")
    _apply_0024(engine)
    _assert_0024_columns(engine)


def test_0024_rerun_is_a_noop() -> None:
    # Drifted volume: schema already at 0024 while alembic_version says 0023.
    engine = _engine_with_todos("CREATE TABLE todos (id TEXT PRIMARY KEY)")
    _apply_0024(engine)
    _apply_0024(engine)
    _assert_0024_columns(engine)


def test_0024_half_applied_schema_adds_only_missing_column() -> None:
    engine = _engine_with_todos("CREATE TABLE todos (id TEXT PRIMARY KEY, next_action_text TEXT)")
    _apply_0024(engine)
    _assert_0024_columns(engine)


def test_0024_incompatible_existing_column_fails_loud() -> None:
    # A pre-existing column with a divergent definition must not be silently
    # accepted as "already applied" — that would stamp a broken schema.
    engine = _engine_with_todos(
        "CREATE TABLE todos (id TEXT PRIMARY KEY, next_action_text INTEGER NOT NULL)"
    )
    with pytest.raises(RuntimeError, match="next_action_text.*incompatible"):
        _apply_0024(engine)


# --- Startup migration runner ------------------------------------------------


class _UpgradeSpy:
    def __init__(self, exc: Exception | None = None) -> None:
        self.calls = 0
        self.exc = exc

    def __call__(self, config: Config) -> None:
        self.calls += 1
        if self.exc is not None:
            raise self.exc


class _FakeAsyncpgError(Exception):
    """Stand-in for asyncpg's exception carrying a PostgreSQL SQLSTATE."""

    def __init__(self, message: str, sqlstate: str) -> None:
        super().__init__(message)
        self.sqlstate = sqlstate


def _programming_error(sqlstate: str) -> ProgrammingError:
    return ProgrammingError(
        "ALTER TABLE todos ADD COLUMN next_action_text TEXT",
        None,
        _FakeAsyncpgError('column "next_action_text" of relation "todos" already exists', sqlstate),
    )


def _stub_db_state(
    monkeypatch: pytest.MonkeyPatch, current: str | None, schema_present: bool
) -> None:
    async def _state() -> tuple[str | None, bool]:
        return current, schema_present

    monkeypatch.setattr(migrate, "_db_state", _state)


def _head() -> str:
    head = ScriptDirectory.from_config(migrate._alembic_config()).get_current_head()
    assert head is not None
    return head


def test_clean_path_runs_upgrade(monkeypatch: pytest.MonkeyPatch) -> None:
    spy = _UpgradeSpy()
    monkeypatch.setattr(migrate, "_run_upgrade", spy)
    _stub_db_state(monkeypatch, "0023", schema_present=True)
    assert migrate.main() == 0
    assert spy.calls == 1


def test_fresh_database_runs_upgrade(monkeypatch: pytest.MonkeyPatch) -> None:
    spy = _UpgradeSpy()
    monkeypatch.setattr(migrate, "_run_upgrade", spy)
    _stub_db_state(monkeypatch, None, schema_present=False)
    assert migrate.main() == 0
    assert spy.calls == 1


def test_already_at_head_skips_upgrade(monkeypatch: pytest.MonkeyPatch) -> None:
    spy = _UpgradeSpy()
    monkeypatch.setattr(migrate, "_run_upgrade", spy)
    _stub_db_state(monkeypatch, _head(), schema_present=True)
    assert migrate.main() == 0
    assert spy.calls == 0


def test_unstamped_schema_fails_before_migrating(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    spy = _UpgradeSpy()
    monkeypatch.setattr(migrate, "_run_upgrade", spy)
    _stub_db_state(monkeypatch, None, schema_present=True)
    with pytest.raises(SystemExit) as excinfo:
        migrate.main()
    assert excinfo.value.code == 1
    assert spy.calls == 0  # fails before any migration runs
    err = capsys.readouterr().err
    assert "todos" in err
    assert "no revision stamp" in err
    assert "alembic stamp" in err
    assert "infra/README.md" in err


def test_unknown_revision_fails_actionably(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    spy = _UpgradeSpy()
    monkeypatch.setattr(migrate, "_run_upgrade", spy)
    _stub_db_state(monkeypatch, "deadbeef", schema_present=True)
    with pytest.raises(SystemExit) as excinfo:
        migrate.main()
    assert excinfo.value.code == 1
    assert spy.calls == 0
    err = capsys.readouterr().err
    assert "deadbeef" in err
    assert "alembic stamp" in err


def test_duplicate_column_failure_is_classified(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    spy = _UpgradeSpy(exc=_programming_error("42701"))
    monkeypatch.setattr(migrate, "_run_upgrade", spy)
    _stub_db_state(monkeypatch, "0023", schema_present=True)
    with pytest.raises(SystemExit) as excinfo:
        migrate.main()
    assert excinfo.value.code == 1
    err = capsys.readouterr().err
    assert "0023" in err  # current DB revision
    assert _head() in err  # head revision
    assert "0024" in err  # the pending/failing revision
    assert "already exists" in err  # the underlying database error
    assert "alembic stamp" in err
    assert "down -v" in err


def test_non_duplicate_programming_errors_reraise(monkeypatch: pytest.MonkeyPatch) -> None:
    # 42P01 undefined_table: a genuine migration bug, not drift — keep the traceback.
    spy = _UpgradeSpy(exc=_programming_error("42P01"))
    monkeypatch.setattr(migrate, "_run_upgrade", spy)
    _stub_db_state(monkeypatch, "0023", schema_present=True)
    with pytest.raises(ProgrammingError):
        migrate.main()
