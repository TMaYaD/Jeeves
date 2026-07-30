"""Drop the mirrored domain schema and the PowerSync publication (issue #556).

Revision ID: 0034
Revises: 0033
Create Date: 2026-07-30

The fifteen tables dropped here were a *cache* of client state, never a source
of truth.  ADR-0026 records the mirror as the thing the op log replaces, and
``docs/proposals/minimal-sync-server.md`` states the position outright: "The
client is the source of truth; the server's copy is a cache. There is no
server-side data migration."  #553 proved the claim rather than asserting it —
Phase 1's converge-verify report (archived on #553: all twelve synced tables
converged, 3,242 rows) and Phase 2's reseed verification together establish that
the op log is a superset of the mirror.  #591 made the op log the production
sync path, and the confidence window that followed it has been called closed.
Nothing that exists only in these tables is user data.

Dropped (the mirrored domain, children first so no FK is ever left dangling):
``todo_tags``, ``capture_tags``, ``capture_outcomes``,
``focus_session_dispositions``, ``focus_session_tasks``, ``time_logs``,
``reminders``, ``recurrence_rules``, ``actions``, ``focus_sessions``,
``captures``, ``todos``, ``tags``, ``locations``, ``user_preferences``.

Must NOT touch the server-owned tables — ``ops``, ``members``, ``workspaces``,
``grants``, ``recovery_escrows``, ``recovery_escrow_fetches`` (``app/sync``),
``users``, ``refresh_tokens`` (``app/auth``), or ``alembic_version``.  The op
log *is* the data now; the two ``time_logs``-shaped denormalizations that lived
only in the mirror retire with it rather than migrating anywhere.

The ``powersync`` publication goes with the tables it replicated.  Dropping it
first stops the logical-replication consumer reading a schema mid-teardown; the
drop is dialect-guarded because the migration chain is also exercised on SQLite
(same guard style as 0028), which has no publications.

Deploy mechanics: the Procfile's ``release: python -m app.migrate`` runs this
before the pruned application code boots, so the routes over these tables and
the tables themselves leave in a single atomic deploy.  The operator's one
belt-and-braces step is a ``dokku postgres:export`` taken immediately before
that deploy, and the orphaned replication slot must be dropped by hand after it
(destroying the PowerSync app does not drop its slot, and an orphaned slot
retains WAL forever).
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0034"
down_revision: str | None = "0033"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# FK-safe teardown order, derived from the foreign-key graph the dropped models
# declared: junction/child tables first, then the rows they pointed at.
# ``time_logs`` precedes ``actions`` and ``focus_sessions`` (it referenced both);
# ``focus_sessions`` precedes ``todos`` (``current_task_id``); ``todos``
# precedes ``locations``.  Listed explicitly rather than sorted at runtime so a
# future reader can check the order against the models in git history.
_MIRRORED_TABLES_CHILDREN_FIRST = (
    "todo_tags",
    "capture_tags",
    "capture_outcomes",
    "focus_session_dispositions",
    "focus_session_tasks",
    "time_logs",
    "reminders",
    "recurrence_rules",
    "actions",
    "focus_sessions",
    "captures",
    "todos",
    "tags",
    "locations",
    "user_preferences",
)


def upgrade() -> None:
    bind = op.get_bind()

    if bind.dialect.name == "postgresql":
        op.execute("DROP PUBLICATION IF EXISTS powersync")

    # ``if_exists`` keeps a partially-torn-down store (or the SQLite chain
    # harness, where an earlier revision may never have created a table) from
    # turning a teardown into a crash-loop.
    for table_name in _MIRRORED_TABLES_CHILDREN_FIRST:
        op.drop_table(table_name, if_exists=True)


def downgrade() -> None:
    # Irreversible, and fails before touching any schema.  Recreating fifteen
    # empty tables would restore the *shape* of a cache while restoring none of
    # its contents, and would silently re-establish a replication path that no
    # longer has a consumer — a downgrade that appears to succeed while leaving
    # the system in a state no code understands.  The sanction for the drop is
    # ADR-0026 plus docs/proposals/minimal-sync-server.md's Implementation
    # stance ("The client is the source of truth; the server's copy is a
    # cache. There is no server-side data migration."), evidenced by the #553
    # Phase-1 converge-verify and Phase-2 reseed verification reports archived
    # on that issue.  Recovery is restore-from-backup + ``alembic stamp``.
    raise RuntimeError(
        "Migration 0034 (drop_mirrored_domain_schema) is irreversible: the "
        "fifteen mirrored domain tables were a cache of client state (ADR-0026; "
        "docs/proposals/minimal-sync-server.md, Implementation stance), and the "
        "op log verified as their superset on #553 is now the only copy the "
        "server keeps. Recreating them empty would restore no data and would "
        "re-establish a replication path with no consumer. Restore from the "
        "pre-deploy `dokku postgres:export` backup and `alembic stamp` the "
        "target revision instead of running `alembic downgrade`."
    )
