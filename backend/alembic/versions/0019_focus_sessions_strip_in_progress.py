"""Introduce focus_sessions + focus_session_tasks; retire in_progress state.

Creates the FocusSession and FocusSessionTask tables, wires time_logs to
focus_sessions, backfills open sessions from existing in_progress and
selected_for_today rows, then drops the three retired client-state columns
(in_progress_since, selected_for_today, daily_selection_date) and collapses
in_progress → next_action.

The "at most one in-progress task per user" invariant moves from an
application-level FSM guard to a partial unique index on focus_sessions:
  UNIQUE (user_id) WHERE ended_at IS NULL

Revision ID: 0019
Revises: 0018
"""

import sqlalchemy as sa

from alembic import op

revision = "0019"
down_revision = "0018"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 1. Create focus_sessions
    op.create_table(
        "focus_sessions",
        sa.Column("id", sa.String, primary_key=True),
        sa.Column("user_id", sa.String, nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "current_task_id",
            sa.String,
            sa.ForeignKey("todos.id"),
            nullable=True,
        ),
    )
    op.create_index(
        "focus_sessions_one_open_per_user",
        "focus_sessions",
        ["user_id"],
        unique=True,
        postgresql_where=sa.text("ended_at IS NULL"),
    )

    # 2. Create focus_session_tasks
    op.create_table(
        "focus_session_tasks",
        sa.Column(
            "focus_session_id",
            sa.String,
            sa.ForeignKey("focus_sessions.id"),
            nullable=False,
        ),
        sa.Column(
            "task_id",
            sa.String,
            sa.ForeignKey("todos.id"),
            nullable=False,
        ),
        sa.Column("position", sa.Integer, nullable=False),
        sa.PrimaryKeyConstraint("focus_session_id", "task_id"),
    )

    # 3. Wire time_logs to focus_sessions
    op.add_column(
        "time_logs",
        sa.Column(
            "focus_session_id",
            sa.String,
            sa.ForeignKey("focus_sessions.id"),
            nullable=True,
        ),
    )

    # 4. Backfill: one open FocusSession per user that has in_progress OR
    #    selected_for_today rows.  DISTINCT ON (user_id) with tiebreaker on
    #    updated_at DESC defends against pathological multi-in_progress data.
    op.execute(
        """
        INSERT INTO focus_sessions (id, user_id, started_at, ended_at, current_task_id)
        SELECT
            gen_random_uuid(),
            u.user_id,
            COALESCE(ip.started, sel.earliest, now()),
            NULL,
            ip.task_id
        FROM (
            SELECT DISTINCT user_id FROM todos
            WHERE state = 'in_progress' OR selected_for_today = true
        ) u
        LEFT JOIN (
            SELECT DISTINCT ON (user_id) user_id,
                   id AS task_id,
                   COALESCE(in_progress_since::timestamptz, now()) AS started
            FROM todos
            WHERE state = 'in_progress'
            ORDER BY user_id, updated_at DESC
        ) ip ON ip.user_id = u.user_id
        LEFT JOIN (
            SELECT user_id, MIN(updated_at) AS earliest
            FROM todos WHERE selected_for_today = true
            GROUP BY user_id
        ) sel ON sel.user_id = u.user_id
        """
    )

    # 5. Backfill focus_session_tasks: members are selected_for_today rows PLUS
    #    the current_task_id if it is not already selected_for_today.
    op.execute(
        """
        INSERT INTO focus_session_tasks (focus_session_id, task_id, position)
        SELECT fs.id, t.id,
               ROW_NUMBER() OVER (PARTITION BY fs.user_id ORDER BY t.updated_at)
        FROM focus_sessions fs
        JOIN todos t ON t.user_id = fs.user_id
            AND (
                t.selected_for_today = true
                OR (fs.current_task_id IS NOT NULL AND t.id = fs.current_task_id)
            )
            AND fs.ended_at IS NULL
        """
    )

    # 6. Backfill focus_session_id on open time_log rows
    op.execute(
        """
        UPDATE time_logs tl
        SET focus_session_id = fs.id
        FROM focus_sessions fs
        WHERE fs.user_id = tl.user_id
          AND fs.ended_at IS NULL
          AND tl.ended_at IS NULL
        """
    )

    # 7. Collapse in_progress → next_action (AFTER backfill; current_task_id set)
    op.execute("UPDATE todos SET state = 'next_action' WHERE state = 'in_progress'")

    # 8. Drop the retired columns
    op.drop_column("todos", "selected_for_today")
    op.drop_column("todos", "daily_selection_date")
    op.drop_column("todos", "in_progress_since")

    # 9. Shrink the CHECK constraint (drop 'in_progress')
    op.drop_constraint("ck_todos_state", "todos")
    op.create_check_constraint(
        "ck_todos_state",
        "todos",
        "state IN ('next_action')",
    )

    # 10. Add new tables to the PowerSync publication
    op.execute("ALTER PUBLICATION powersync ADD TABLE focus_sessions")
    op.execute("ALTER PUBLICATION powersync ADD TABLE focus_session_tasks")


def downgrade() -> None:
    raise NotImplementedError(
        "Migration 0019 is irreversible: retired columns and in_progress state "
        "cannot be safely reconstructed from focus_sessions data."
    )
