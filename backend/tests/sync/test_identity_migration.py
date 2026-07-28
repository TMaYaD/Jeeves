"""Alembic 0032 (recovery escrow + identity columns) — issue #548.

Purely additive, so the interesting assertions are that it chains where it says
it does, that the tables and columns it creates match the ORM models the routes
write through, and that it adds nothing a pre-#548 row would have to be
backfilled into.  A schema that drifts from ``app.sync.models`` would pass every
route test (they run on ``Base.metadata.create_all``) and fail only in
production.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

import sqlalchemy as sa
from alembic.operations import Operations
from alembic.runtime.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy.pool import StaticPool

from app import migrate
from app.auth.models import RefreshToken
from app.sync.models import Member, RecoveryEscrow, RecoveryEscrowFetch

_VERSIONS = Path(__file__).resolve().parents[2] / "alembic" / "versions"


def _load(name: str, filename: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, _VERSIONS / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _run(engine: sa.engine.Engine, module: ModuleType, *, downgrade: bool = False) -> None:
    with engine.begin() as conn:
        ctx = MigrationContext.configure(conn)
        with Operations.context(ctx):
            (module.downgrade if downgrade else module.upgrade)()


def _engine_at_0031() -> sa.engine.Engine:
    """A database carrying everything 0032 builds on, and one row in each table."""
    engine = sa.create_engine("sqlite://", poolclass=StaticPool)
    with engine.begin() as conn:
        conn.execute(sa.text("CREATE TABLE users (id TEXT PRIMARY KEY)"))
        conn.execute(
            sa.text(
                "CREATE TABLE refresh_tokens ("
                "  id TEXT PRIMARY KEY,"
                "  user_id TEXT NOT NULL,"
                "  token_hash TEXT NOT NULL UNIQUE,"
                "  expires_at TIMESTAMP NOT NULL,"
                "  created_at TIMESTAMP NOT NULL,"
                "  revoked_at TIMESTAMP"
                ")"
            )
        )
        conn.execute(sa.text("INSERT INTO users (id) VALUES ('u1')"))
        conn.execute(
            sa.text(
                "INSERT INTO refresh_tokens "
                "(id, user_id, token_hash, expires_at, created_at) "
                "VALUES ('t1', 'u1', 'hash', '2030-01-01', '2026-01-01')"
            )
        )
    _run(engine, _load("migration_0031", "0031_add_sync_op_log.py"))
    with engine.begin() as conn:
        conn.execute(
            sa.text(
                "INSERT INTO members (member_id, user_id, sign_pk, key_id, created_at) "
                "VALUES ('m1', 'u1', X'00', X'00', '2026-01-01')"
            )
        )
    return engine


def _apply_0032(engine: sa.engine.Engine) -> None:
    _run(engine, _load("migration_0032", "0032_add_identity_root_escrow.py"))


def test_0032_chains_from_0031_and_is_the_current_head() -> None:
    module = _load("migration_0032", "0032_add_identity_root_escrow.py")
    assert module.revision == "0032"
    assert module.down_revision == "0031"
    script = ScriptDirectory.from_config(migrate._alembic_config())
    assert script.get_heads() == ["0032"]


def test_0032_matches_the_models_it_backs() -> None:
    engine = _engine_at_0031()
    _apply_0032(engine)

    with engine.connect() as conn:
        inspector = sa.inspect(conn)
        assert {"recovery_escrows", "recovery_escrow_fetches"} <= set(inspector.get_table_names())
        for table, model in (
            ("members", Member),
            ("refresh_tokens", RefreshToken),
            ("recovery_escrows", RecoveryEscrow),
            ("recovery_escrow_fetches", RecoveryEscrowFetch),
        ):
            migrated = {column["name"] for column in inspector.get_columns(table)}
            assert migrated == {column.name for column in model.__table__.columns}, table

        # The escrow slot is keyed per (workspace, user): one Root per User, and
        # a shape that survives shared Workspaces without another migration.
        assert inspector.get_pk_constraint("recovery_escrows")["constrained_columns"] == [
            "workspace_id",
            "user_id",
        ]


def test_0032_leaves_existing_rows_untouched_and_unbackfilled() -> None:
    """A pre-#548 Member genuinely has no KEX key and genuinely is not chained.

    Nullable-and-empty is the honest state; a default would assert something
    untrue about data that predates the Root chain.
    """
    engine = _engine_at_0031()
    _apply_0032(engine)

    with engine.connect() as conn:
        member = conn.execute(sa.text("SELECT kex_pk, chained_at FROM members")).one()
        assert member.kex_pk is None
        assert member.chained_at is None
        token = conn.execute(sa.text("SELECT id, member_id FROM refresh_tokens")).one()
        assert (token.id, token.member_id) == ("t1", None)
        assert conn.execute(sa.text("SELECT id FROM users")).scalars().all() == ["u1"]


def test_0032_downgrade_removes_only_what_it_added() -> None:
    engine = _engine_at_0031()
    _apply_0032(engine)
    _run(engine, _load("migration_0032", "0032_add_identity_root_escrow.py"), downgrade=True)

    with engine.connect() as conn:
        inspector = sa.inspect(conn)
        remaining = set(inspector.get_table_names())
        assert "recovery_escrows" not in remaining
        assert "recovery_escrow_fetches" not in remaining
        assert {"members", "ops", "refresh_tokens", "users"} <= remaining
        member_columns = {column["name"] for column in inspector.get_columns("members")}
        assert {"kex_pk", "chained_at"}.isdisjoint(member_columns)
        token_columns = {column["name"] for column in inspector.get_columns("refresh_tokens")}
        assert "member_id" not in token_columns
        assert conn.execute(sa.text("SELECT id FROM refresh_tokens")).scalars().all() == ["t1"]
