"""Alembic 0033 (workspaces + grants indexes, members.member_kind) — issue #549.

Purely additive, so the interesting assertions are that it chains where it says
it does, that the tables and columns it creates match the ORM models the routes
write through, and that it adds nothing a pre-#549 row would have to be
backfilled into.  A schema that drifts from ``app.sync.models`` would pass every
route test (they run on ``Base.metadata.create_all``) and fail only in
production.
"""

from __future__ import annotations

import pytest
import sqlalchemy as sa
from sqlalchemy.pool import StaticPool

from app.sync.models import Grant, Member, Workspace
from tests.sync.helpers import load_migration, run_migration


def _engine_at_0032() -> sa.engine.Engine:
    """A database carrying everything 0033 builds on, and one Member row."""
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
    run_migration(engine, load_migration("migration_0031", "0031_add_sync_op_log.py"))
    run_migration(engine, load_migration("migration_0032", "0032_add_identity_root_escrow.py"))
    with engine.begin() as conn:
        conn.execute(
            sa.text(
                "INSERT INTO members (member_id, user_id, sign_pk, key_id, created_at) "
                "VALUES ('m1', 'u1', X'00', X'00', '2026-01-01')"
            )
        )
    return engine


def _apply_0033(engine: sa.engine.Engine) -> None:
    run_migration(engine, load_migration("migration_0033", "0033_add_workspaces_and_grants.py"))


def test_0033_chains_from_0032() -> None:
    # Head moved to 0034 (#556); that assertion lives with the revision that
    # owns it, in tests/test_mirror_drop_migration.py.
    module = load_migration("migration_0033", "0033_add_workspaces_and_grants.py")
    assert module.revision == "0033"
    assert module.down_revision == "0032"


def test_0033_matches_the_models_it_backs() -> None:
    engine = _engine_at_0032()
    _apply_0033(engine)

    with engine.connect() as conn:
        inspector = sa.inspect(conn)
        assert {"workspaces", "grants"} <= set(inspector.get_table_names())
        for table, model in (
            ("members", Member),
            ("workspaces", Workspace),
            ("grants", Grant),
        ):
            migrated = {column["name"] for column in inspector.get_columns(table)}
            assert migrated == {column.name for column in model.__table__.columns}, table

        # Grants are keyed per (workspace, grant_id): revocation is
        # grant-granular, so the grant id has to be addressable on its own rather
        # than reachable only through the member holding it.
        assert inspector.get_pk_constraint("grants")["constrained_columns"] == [
            "workspace_id",
            "grant_id",
        ]
        assert "ix_grants_workspace_member" in {
            index["name"] for index in inspector.get_indexes("grants")
        }


def test_0033_leaves_existing_rows_untouched_and_unbackfilled() -> None:
    """A pre-#549 Member's kind is a *signed* fact nothing has yet asserted.

    Nullable-and-empty is the honest state: a shell row created by
    ``POST /members`` has no certificate behind it, so a ``device`` default would
    claim something no signature says.
    """
    engine = _engine_at_0032()
    _apply_0033(engine)

    with engine.connect() as conn:
        member = conn.execute(sa.text("SELECT member_id, member_kind FROM members")).one()
        assert (member.member_id, member.member_kind) == ("m1", None)
        assert conn.execute(sa.text("SELECT id FROM users")).scalars().all() == ["u1"]


def test_0033_refuses_to_downgrade_and_keeps_the_authorization_index() -> None:
    """``workspaces`` and ``grants`` cannot be rebuilt from the op log server-side.

    Same contract as 0031's refusal: the downgrade raises *before* touching any
    schema, and the assertion is that everything it would have dropped is still
    there — a refusal that had already dropped a table would be no better than
    the drop.
    """
    engine = _engine_at_0032()
    _apply_0033(engine)
    with pytest.raises(RuntimeError, match="irreversible"):
        run_migration(
            engine,
            load_migration("migration_0033", "0033_add_workspaces_and_grants.py"),
            downgrade=True,
        )

    with engine.connect() as conn:
        inspector = sa.inspect(conn)
        remaining = set(inspector.get_table_names())
        assert {
            "workspaces",
            "grants",
            "members",
            "ops",
            "recovery_escrows",
            "refresh_tokens",
            "users",
        } <= remaining
        member_columns = {column["name"] for column in inspector.get_columns("members")}
        assert "member_kind" in member_columns
        assert conn.execute(sa.text("SELECT member_id FROM members")).scalars().all() == ["m1"]
