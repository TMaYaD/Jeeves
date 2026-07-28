"""Alembic 0031 (add the op log and the Member registry) — issue #546.

The migration is purely additive, so the interesting assertions are that it
chains where it says it does and that the tables it creates match the ORM
models the routes write through.  A schema that drifts from ``app.sync.models``
would pass every route test (they run on ``Base.metadata.create_all``) and fail
only in production.
"""

from __future__ import annotations

import importlib.util
import uuid
from pathlib import Path
from types import ModuleType

import pytest
import sqlalchemy as sa
from alembic.operations import Operations
from alembic.runtime.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy import orm
from sqlalchemy.pool import StaticPool

from app import migrate
from app.sync.models import Member, Op

_MIGRATION_0031_PATH = (
    Path(__file__).resolve().parents[2] / "alembic" / "versions" / "0031_add_sync_op_log.py"
)


def _load_migration_0031() -> ModuleType:
    spec = importlib.util.spec_from_file_location("migration_0031", _MIGRATION_0031_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _apply_upgrade(engine: sa.engine.Engine) -> None:
    module = _load_migration_0031()
    with engine.begin() as conn:
        ctx = MigrationContext.configure(conn)
        with Operations.context(ctx):
            module.upgrade()


def _engine_with_users() -> sa.engine.Engine:
    engine = sa.create_engine("sqlite://", poolclass=StaticPool)
    with engine.begin() as conn:
        conn.execute(sa.text("CREATE TABLE users (id TEXT PRIMARY KEY)"))
    return engine


def test_0031_chains_from_0030_and_is_the_current_head() -> None:
    module = _load_migration_0031()
    assert module.revision == "0031"
    assert module.down_revision == "0030"
    script = ScriptDirectory.from_config(migrate._alembic_config())
    assert script.get_heads() == ["0031"]


def test_0031_creates_the_op_log_and_member_registry() -> None:
    engine = _engine_with_users()
    _apply_upgrade(engine)

    with engine.connect() as conn:
        inspector = sa.inspect(conn)
        assert {"ops", "members"} <= set(inspector.get_table_names())
        for table, model in (("ops", Op), ("members", Member)):
            migrated = {column["name"] for column in inspector.get_columns(table)}
            assert migrated == {column.name for column in model.__table__.columns}, table
        index_names = {index["name"] for index in inspector.get_indexes("ops")}
        assert "ix_ops_workspace_seq" in index_names

        # The uniqueness rules are the half of the schema that route tests
        # cannot notice going missing: `Base.metadata.create_all` builds them
        # from the model, so only this comparison catches a migration that
        # declares fewer than the model does.
        migrated_uniques = {
            constraint["name"]: list(constraint["column_names"])
            for constraint in inspector.get_unique_constraints("ops")
        }
        assert migrated_uniques == {
            constraint.name: [column.name for column in constraint.columns]
            for constraint in Op.metadata.tables["ops"].constraints
            if isinstance(constraint, sa.UniqueConstraint)
        }
        assert "uq_ops_workspace_author_seq" in migrated_uniques


def test_0031_uniques_the_author_chain() -> None:
    """One author cannot fill the same chain slot twice, whatever the op id.

    The route's gap check reads ``MAX(author_seq)`` and then inserts, so two
    concurrent batches can both believe they own the next slot.  This is the
    backstop, and it has to live in the schema: a forked chain cannot be
    repaired after the fact.
    """
    engine = _engine_with_users()
    _apply_upgrade(engine)

    workspace_id = uuid.uuid4()
    author_member_id = uuid.uuid4()

    # `seq` is spelled out because the migration declares it BIGINT, which
    # SQLite does not alias to rowid the way the model's Integer variant does.
    # Production is Postgres, where the same declaration is BIGSERIAL.
    def op(seq: int, *, author_seq: int, workspace: uuid.UUID = workspace_id) -> Op:
        return Op(
            seq=seq,
            workspace_id=workspace,
            envelope=b"opaque",
            op_class=1,
            key_epoch=0,
            op_id=uuid.uuid4(),  # a *different* op each time: only the slot clashes
            author_member_id=author_member_id,
            author_key_id=bytes(8),
            author_seq=author_seq,
        )

    with orm.Session(engine) as session:
        session.add(op(1, author_seq=1))
        session.commit()
        session.add(op(2, author_seq=1))
        with pytest.raises(sa.exc.IntegrityError):
            session.commit()
        session.rollback()

        # Same slot in another workspace is a different chain, and so is the
        # next slot in this one: the constraint is not over-broad.
        session.add(op(3, author_seq=1, workspace=uuid.uuid4()))
        session.add(op(4, author_seq=2))
        session.commit()

    with engine.connect() as conn:
        assert conn.execute(sa.text("SELECT count(*) FROM ops")).scalar() == 3


def test_0031_leaves_existing_tables_untouched() -> None:
    """Additive only: the walking skeleton runs alongside the old stack (#553
    cuts over), so nothing here may touch a PowerSync-mirrored table."""
    engine = _engine_with_users()
    with engine.begin() as conn:
        conn.execute(sa.text("INSERT INTO users (id) VALUES ('u1')"))
    _apply_upgrade(engine)
    with engine.connect() as conn:
        assert conn.execute(sa.text("SELECT id FROM users")).scalars().all() == ["u1"]


def test_0031_downgrade_removes_only_what_it_added() -> None:
    engine = _engine_with_users()
    _apply_upgrade(engine)
    module = _load_migration_0031()
    with engine.begin() as conn:
        ctx = MigrationContext.configure(conn)
        with Operations.context(ctx):
            module.downgrade()
    with engine.connect() as conn:
        remaining = set(sa.inspect(conn).get_table_names())
    assert "ops" not in remaining
    assert "members" not in remaining
    assert "users" in remaining
