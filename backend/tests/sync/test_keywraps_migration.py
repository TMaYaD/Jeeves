"""Alembic 0035 (keywraps + workspace_epochs) — issue #554.

Purely additive, so the interesting assertions are that it chains where it says it
does, that the tables match the ORM models the routes write through, and — the one
that matters most here — that it leaves a pre-#554 database able to keep serving
``plaintext_v1`` clients unchanged.  A schema that drifted from ``app.sync.models``
would pass every route test (they run on ``Base.metadata.create_all``) and fail only
in production.
"""

from __future__ import annotations

import pytest
import sqlalchemy as sa
from alembic.script import ScriptDirectory
from sqlalchemy.pool import StaticPool

from app import migrate
from app.sync.models import KeyWrap, WorkspaceEpoch
from tests.sync.helpers import load_migration, run_migration


def _engine_at_0034() -> sa.engine.Engine:
    """A database carrying everything 0035 builds on, plus one Member and one op."""
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
    for name, filename in (
        ("migration_0031", "0031_add_sync_op_log.py"),
        ("migration_0032", "0032_add_identity_root_escrow.py"),
        ("migration_0033", "0033_add_workspaces_and_grants.py"),
        ("migration_0034", "0034_drop_mirrored_domain_schema.py"),
    ):
        run_migration(engine, load_migration(name, filename))
    with engine.begin() as conn:
        conn.execute(
            sa.text(
                "INSERT INTO members (member_id, user_id, sign_pk, key_id, created_at) "
                "VALUES ('m1', 'u1', X'00', X'00', '2026-01-01')"
            )
        )
        # A plaintext_v1 op at epoch 0 — the history this migration must leave
        # readable, and the reason turn-on mints K_{w,1} rather than K_{w,0}.
        conn.execute(
            sa.text(
                "INSERT INTO ops (workspace_id, envelope, op_class, key_epoch, op_id, "
                "  author_member_id, author_key_id, author_seq, received_at) "
                "VALUES ('w1', X'00', 1, 0, 'o1', 'm1', X'00', 1, '2026-01-01')"
            )
        )
    return engine


def _apply_0035(engine: sa.engine.Engine) -> None:
    run_migration(engine, load_migration("migration_0035", "0035_add_keywraps_and_epochs.py"))


def test_0035_chains_from_0034_and_is_the_current_head() -> None:
    module = load_migration("migration_0035", "0035_add_keywraps_and_epochs.py")
    assert module.revision == "0035"
    assert module.down_revision == "0034"
    script = ScriptDirectory.from_config(migrate._alembic_config())
    assert script.get_heads() == ["0035"]


def test_0035_matches_the_models_it_backs() -> None:
    engine = _engine_at_0034()
    _apply_0035(engine)

    with engine.connect() as conn:
        inspector = sa.inspect(conn)
        assert {"keywraps", "workspace_epochs"} <= set(inspector.get_table_names())
        for table, model in (("keywraps", KeyWrap), ("workspace_epochs", WorkspaceEpoch)):
            migrated = {column["name"] for column in inspector.get_columns(table)}
            assert migrated == {column.name for column in model.__table__.columns}, table

        # One wrap per member per epoch: a rotation *adds* rows rather than replacing
        # them, because historical epoch keys are kept for ever — soft-delete
        # retention means content authored at any past epoch may still be read.
        assert inspector.get_pk_constraint("keywraps")["constrained_columns"] == [
            "workspace_id",
            "member_id",
            "epoch",
        ]
        assert inspector.get_pk_constraint("workspace_epochs")["constrained_columns"] == [
            "workspace_id",
            "epoch",
        ]


def test_0035_leaves_a_plaintext_workspace_untouched_and_unkeyed() -> None:
    """The property that makes turn-on a ceremony rather than a deploy.

    After this migration a Workspace has *no* epoch rows, so ``_current_key_epoch``
    reads None, nothing is stale, and a ``plaintext_v1`` client at epoch 0 keeps
    working byte for byte.  Minting an epoch 0 row here would be the opposite: it
    would key epoch 0 retroactively and make every existing plaintext op a
    ``plaintext_at_encrypted_epoch`` refusal on every device.
    """
    engine = _engine_at_0034()
    _apply_0035(engine)

    with engine.connect() as conn:
        assert conn.execute(sa.text("SELECT COUNT(*) FROM workspace_epochs")).scalar() == 0
        assert conn.execute(sa.text("SELECT COUNT(*) FROM keywraps")).scalar() == 0
        op = conn.execute(sa.text("SELECT op_id, key_epoch FROM ops")).one()
        assert (op.op_id, op.key_epoch) == ("o1", 0)
        assert conn.execute(sa.text("SELECT member_id FROM members")).scalars().all() == ["m1"]


def test_0035_refuses_to_downgrade_and_keeps_every_epoch_key() -> None:
    """Dropping these tables destroys the user's data, not merely an index.

    ``workspaces``/``grants`` can at least be re-derived by a human reading the log;
    a Workspace content key is random, never derived, and exists nowhere else on the
    server.  Dropping ``keywraps`` and ``workspace_epochs`` makes every ``aead_v1``
    op permanently unreadable to any device enrolling afterwards.  The refusal has to
    fire *before* touching any schema — one that had already dropped a table would be
    no better than the drop.
    """
    engine = _engine_at_0034()
    _apply_0035(engine)
    with engine.begin() as conn:
        conn.execute(
            sa.text(
                "INSERT INTO workspace_epochs "
                "  (workspace_id, epoch, keywrap_digest, escrow_wrap, rotate_seq, created_at) "
                "VALUES ('w1', 1, X'11', X'22', 7, '2026-01-01')"
            )
        )
        conn.execute(
            sa.text(
                "INSERT INTO keywraps "
                "  (workspace_id, member_id, epoch, kex_key_id, wrap, created_at) "
                "VALUES ('w1', 'm1', 1, X'33', X'44', '2026-01-01')"
            )
        )

    with pytest.raises(RuntimeError, match="irreversible"):
        run_migration(
            engine,
            load_migration("migration_0035", "0035_add_keywraps_and_epochs.py"),
            downgrade=True,
        )

    with engine.connect() as conn:
        assert {"keywraps", "workspace_epochs"} <= set(sa.inspect(conn).get_table_names())
        assert conn.execute(sa.text("SELECT epoch FROM workspace_epochs")).scalars().all() == [1]
        assert conn.execute(sa.text("SELECT wrap FROM keywraps")).scalars().all() == [b"\x44"]
