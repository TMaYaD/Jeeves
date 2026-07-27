"""Drop todos.next_action_text — the retired next-action cursor (issue #525).

Revision ID: 0030
Revises: 0029
Create Date: 2026-07-27

``actions`` has been the only next-action grain since #479 (ADR-0001 story 9,
ADR-0022).  ADR-0024 reverses ADR-0022's retention-by-abandonment and drops the
column outright; this migration is the Postgres half, and it ships in the same
change as the SQLAlchemy model, all three Pydantic schemas and the create route.
That atomicity is load-bearing: if the column disappeared while
``routes.py`` still passed ``next_action_text=`` to the ``Todo(...)``
constructor, every todo POST would raise ``TypeError`` → 500, PowerSync
classifies 5xx as retryable, and the upload queue would wedge permanently on
every device.

**This is a destructive migration**, and AGENTS.md § Data Persistence forbids
those by default.  ADR-0024 records the owner-authorised exception and scopes
it: Alembic 0028 already derived every non-blank cursor into an ``actions`` row
using the same uuid5 the client mints (ADR-0019), so what is discarded here is
duplicated text, not information.  Nothing should cite this migration as
precedent without an ADR of its own.

No sync-rules change accompanies it.  ``by_user_todos`` is
``SELECT * FROM todos WHERE user_id = bucket.user_id``, so no rule names the
column; ``infra/powersync/sync-config.yaml`` is unchanged and PowerSync never
restarts (ADR-0017 publishes only on a rules *change*).  The ``powersync``
publication is ``FOR TABLE todos, …`` with no column list, so it needs no
``ALTER PUBLICATION`` either.  PowerSync does not replicate DDL: rows already in
bucket storage keep the orphaned key and the column decays row-by-row as each
row is next updated.  No client declares the column any more, so that decay is
unobservable.

The drop is guarded against re-execution (schema/version drift, issue #382;
0024/0029 precedent) so ``alembic upgrade`` heals the stamp rather than
crash-looping on UndefinedColumnError.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0030"
down_revision: str | None = "0029"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    existing_columns = {col["name"] for col in sa.inspect(op.get_bind()).get_columns("todos")}
    if "next_action_text" in existing_columns:
        op.drop_column("todos", "next_action_text")


def downgrade() -> None:
    """Re-add the column, empty.

    **The cursor text is not recoverable.**  ``upgrade()`` destroys it and this
    function restores only the shape of the schema, never its contents — every
    row comes back NULL.  A downgrade is a way to run a pre-0030 binary against
    this database, not a way to undo the drop.  The next-action text itself
    lives in ``actions.text``; nothing reads it back onto ``todos``.
    """
    existing_columns = {col["name"] for col in sa.inspect(op.get_bind()).get_columns("todos")}
    if "next_action_text" not in existing_columns:
        op.add_column("todos", sa.Column("next_action_text", sa.Text(), nullable=True))
