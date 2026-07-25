"""Add time_logs.action_id — TimeLog attribution at the Action grain (issue #476).

Revision ID: 0029
Revises: 0028
Create Date: 2026-07-25

ADR-0001 story 6: a TimeLog now records *which Action* was being engaged, not
only which Outcome (``task_id`` stays — an Outcome's total time is derived over
its Actions ∪ the legacy ``action_id IS NULL`` rows by ``task_id``).  This
migration is **additive** and re-runnable per ADR-0012:

- ``action_id`` is nullable with ``ON DELETE SET NULL``, not RESTRICT/CASCADE.
  TimeLogs are the user's time data and are never deleted (SYNC.md: "time logs
  are never deleted"; the ``focus_session_id`` detach precedent).  A RESTRICT
  would turn a legitimate Action-delete replay into a 500 → infinite connector
  retry; a CASCADE would destroy time data.  SET NULL keeps the row, falling
  back to its ``task_id`` (Outcome-grain) attribution.
- **No backfill**: which Action was current when a historical stint ran is
  unreconstructable, and #471's backfilled current Actions were minted from the
  *present* cursor text — pointing old logs at them would fabricate history.
  Legacy rows keep ``action_id`` NULL; correctness does not depend on a
  backfill because every time-spent total aggregates by ``task_id``.

The column-add is guarded against re-execution (schema/version drift, issue
#382; 0024 precedent) so ``alembic upgrade`` heals the stamp rather than
crash-looping on DuplicateColumnError.  The index is guarded independently of
the column so a partially-applied forward run still gets the index on re-run
(0028 precedent).  ``time_logs`` is already in the ``powersync`` publication, so
no ``ALTER PUBLICATION`` is needed, and ``by_user_time_logs`` is ``SELECT *`` so
the sync rules carry the new column without an edit (ADR-0017: CD publishes only
on a rules *change*, and there is none).
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0029"
down_revision: str | None = "0028"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    bind = op.get_bind()
    inspector = sa.inspect(bind)

    existing_columns = {col["name"] for col in inspector.get_columns("time_logs")}
    if "action_id" not in existing_columns:
        # Add the bare column first: SQLite (the migration test harness) cannot
        # ALTER TABLE ADD COLUMN with an inline foreign key, so the FK is
        # attached in a separate, Postgres-only step below. Ownership is
        # route-enforced (not DB-enforced) in tests, so the missing SQLite FK is
        # harmless there.
        op.add_column("time_logs", sa.Column("action_id", sa.String(), nullable=True))

    # ForeignKey with ondelete=SET NULL: a deleted Action detaches its logs
    # rather than deleting them (CASCADE) or blocking the delete (RESTRICT →
    # 500 → infinite connector retry). Guarded independently of the column and
    # Postgres-only, so a re-run and the SQLite path both stay safe.
    if bind.dialect.name == "postgresql":
        existing_fks = {fk["name"] for fk in sa.inspect(bind).get_foreign_keys("time_logs")}
        if "fk_time_logs_action_id_actions" not in existing_fks:
            op.create_foreign_key(
                "fk_time_logs_action_id_actions",
                "time_logs",
                "actions",
                ["action_id"],
                ["id"],
                ondelete="SET NULL",
            )

    existing_indexes = {index["name"] for index in sa.inspect(bind).get_indexes("time_logs")}
    if "ix_time_logs_action_id" not in existing_indexes:
        op.create_index("ix_time_logs_action_id", "time_logs", ["action_id"])


def downgrade() -> None:
    op.drop_index("ix_time_logs_action_id", table_name="time_logs")
    op.drop_column("time_logs", "action_id")
