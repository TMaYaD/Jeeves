"""Alembic 0034 (drop the mirrored domain schema) — issue #556.

The drop's *behaviour over real rows and real foreign keys* is pinned by
``test_migration_chain_postgres.py``, which walks the whole chain against a
Postgres scratch database: only Postgres refuses a parent dropped before its
child, and only Postgres has the publication the migration also removes.

What is left for this module is what SQLite can answer faster and more
directly: that the revision chains where it says it does and is head, that the
fifteen table names it drops are exactly the mirrored set, that it leaves the
server-owned tables alone, that it is dialect-guarded well enough to run at all
on SQLite (the migration-chain harness elsewhere in this suite depends on that),
and that its downgrade refuses before touching schema.
"""

from __future__ import annotations

from types import ModuleType

import pytest
import sqlalchemy as sa
from sqlalchemy.pool import StaticPool

from tests.sync.helpers import load_migration, run_migration

_MIGRATION_FILENAME = "0034_drop_mirrored_domain_schema.py"

# The mirror, as ``app/todos/models.py`` declared it before this revision: the
# twelve actively synced shapes plus the three vestigial 0001-era tables that
# never had routes.  Listed here independently of the migration's own tuple so a
# name quietly added to or dropped from that tuple fails this test.
_MIRRORED_TABLES = frozenset(
    {
        "todos",
        "tags",
        "todo_tags",
        "actions",
        "captures",
        "capture_outcomes",
        "capture_tags",
        "focus_sessions",
        "focus_session_tasks",
        "focus_session_dispositions",
        "time_logs",
        "user_preferences",
        "reminders",
        "locations",
        "recurrence_rules",
    }
)

# Stand-ins for the server-owned tables.  Real ones are asserted on Postgres;
# here they only have to prove the migration drops by name rather than by
# "everything that is not the op log".
_SERVER_OWNED_TABLES = frozenset({"ops", "members", "users", "workspaces"})


def _load() -> ModuleType:
    return load_migration("migration_0034", _MIGRATION_FILENAME)


def _engine_with_stand_in_tables() -> sa.engine.Engine:
    """A SQLite database holding one trivial table per name, mirrored and kept.

    The columns are irrelevant — this revision drops whole tables — so a single
    ``id`` keeps the fixture from implying the migration cares about shape.
    """
    engine = sa.create_engine("sqlite://", poolclass=StaticPool)
    with engine.begin() as conn:
        for table_name in sorted(_MIRRORED_TABLES | _SERVER_OWNED_TABLES):
            conn.execute(sa.text(f"CREATE TABLE {table_name} (id TEXT PRIMARY KEY)"))
    return engine


def _table_names(engine: sa.engine.Engine) -> set[str]:
    with engine.connect() as conn:
        return set(sa.inspect(conn).get_table_names())


def test_0034_chains_from_0033() -> None:
    # Its link, not its position at the head.  "Which revision is the head" is
    # asserted once, by the newest migration's own test — 0035 (keywraps) now
    # owns that claim in tests/sync/test_keywraps_migration.py.
    module = _load()
    assert module.revision == "0034"
    assert module.down_revision == "0033"


def test_0034_drops_exactly_the_mirrored_tables() -> None:
    engine = _engine_with_stand_in_tables()

    run_migration(engine, _load())

    assert _table_names(engine) == set(_SERVER_OWNED_TABLES)


def test_0034_is_a_noop_when_the_mirror_is_already_gone() -> None:
    """Re-running the release phase against a pruned database must not crash-loop.

    ADR-0012's re-runnable contract: ``alembic upgrade head`` runs on every
    deploy, and the *second* one meets a database with none of these tables.
    """
    engine = sa.create_engine("sqlite://", poolclass=StaticPool)
    with engine.begin() as conn:
        conn.execute(sa.text("CREATE TABLE ops (id TEXT PRIMARY KEY)"))

    run_migration(engine, _load())

    assert _table_names(engine) == {"ops"}


def test_0034_downgrade_refuses_before_touching_schema() -> None:
    engine = _engine_with_stand_in_tables()
    before = _table_names(engine)

    with pytest.raises(RuntimeError, match="irreversible"):
        run_migration(engine, _load(), downgrade=True)

    assert _table_names(engine) == before
