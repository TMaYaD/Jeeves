"""Add next_action_text and last_next_action_completion_at to todos.

This migration adds two columns supporting the re-clarification surface (issue #237):

- next_action_text: the current next-action cursor; NULL = Actionless (no action defined).
- last_next_action_completion_at: timestamped when a focus session closes with this task
  non-done; used to detect staleness (task was worked on since last clarification).

Both columns are nullable with no default and no backfill. Existing rows start NULL.
Tasks with next_action_text = NULL will surface as Actionless on the first planning
session after the migration — this is intentional, prompting a one-time clarification pass.

Revision ID: 0024
Revises: 0023
"""

from typing import Any

import sqlalchemy as sa

from alembic import op

revision = "0024"
down_revision = "0023"
branch_labels = None
depends_on = None


def _add_or_verify_column(
    existing: dict[str, Any],
    column: sa.Column[Any],
    compatible: type[sa.types.TypeEngine[Any]],
) -> None:
    info = existing.get(column.name)
    if info is None:
        op.add_column("todos", column)
        return
    # Pre-existing column (drift healing): accept only a compatible definition —
    # a name match alone could stamp a genuinely divergent schema as migrated.
    # The timezone flag is deliberately not compared: SQLite (tests) cannot
    # represent it, and a column this migration itself created carries the
    # right flag on PostgreSQL anyway.
    if not isinstance(info["type"], compatible) or not info["nullable"]:
        raise RuntimeError(
            f"Schema/version drift on todos.{column.name}: the column already "
            f"exists with an incompatible definition (type={info['type']}, "
            f"nullable={info['nullable']}); expected a nullable "
            f"{compatible.__name__}. Refusing to treat migration 0024 as "
            "applied — reconcile the column manually, then re-run migrations. "
            'See infra/README.md, "Recovering from schema/version drift".'
        )


def upgrade() -> None:
    # Guarded against re-execution: a dev volume can hold this schema while
    # alembic_version is still stamped 0023 (schema/version drift, issue #382).
    # Re-running must no-op so `alembic upgrade` heals the stamp instead of
    # crash-looping on DuplicateColumnError. Concurrent runners are serialized
    # by the advisory lock in alembic/env.py.
    existing = {col["name"]: col for col in sa.inspect(op.get_bind()).get_columns("todos")}
    _add_or_verify_column(
        existing,
        sa.Column("next_action_text", sa.Text(), nullable=True),
        compatible=sa.String,
    )
    _add_or_verify_column(
        existing,
        sa.Column(
            "last_next_action_completion_at",
            sa.DateTime(timezone=True),
            nullable=True,
        ),
        compatible=sa.DateTime,
    )


def downgrade() -> None:
    op.drop_column("todos", "last_next_action_completion_at")
    op.drop_column("todos", "next_action_text")
