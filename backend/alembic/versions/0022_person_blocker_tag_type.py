"""Add person tag type; migrate waiting_for to person-Tags; add last_clarified_at.

This migration:
A. Expands the Tag.type CHECK to include 'person'.
B. Replaces the (user_id, name) unique constraint on tags with (user_id, type, name),
   allowing the same name to exist under different tag types.
C. Adds last_clarified_at column to todos (nullable; no backfill — first consumer).
D. Backfills: for each distinct (user_id, waiting_for) pair, creates a person-typed Tag
   and links each todo to its person-Tag via TodoTag.
E. Drops the waiting_for column.

Downgrade restores the schema columns and constraints but cannot recover migrated data.

Revision ID: 0022
Revises: 0021
"""

import sqlalchemy as sa

from alembic import op

revision = "0022"
down_revision = "0021"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # A – Expand the Tag.type CHECK constraint to include 'person'.
    op.drop_constraint("ck_tags_type", "tags", type_="check")
    op.create_check_constraint(
        "ck_tags_type",
        "tags",
        "type IN ('context','project','area','label','person')",
    )

    # B – Replace (user_id, name) unique constraint with (user_id, type, name).
    #     The narrower constraint prevented two tags with the same name but different
    #     types (e.g. "Bob" as a context tag and "Bob" as a person tag).
    op.drop_constraint("uq_tags_user_name", "tags", type_="unique")
    op.create_unique_constraint("uq_tags_user_type_name", "tags", ["user_id", "type", "name"])

    # C – Add last_clarified_at to todos (nullable; starts NULL for all existing rows).
    op.add_column(
        "todos",
        sa.Column("last_clarified_at", sa.DateTime(timezone=True), nullable=True),
    )

    # D – Backfill: create person-Tags for each distinct (user_id, waiting_for) pair,
    #     then link each todo to its corresponding person-Tag via TodoTag.
    #
    #     Step 1: insert person-Tags.  ON CONFLICT targets the new (user_id, type, name)
    #     index created above so pre-existing person tags with the same name are reused.
    op.execute(
        """
        INSERT INTO tags (id, name, type, color, user_id)
        SELECT
            gen_random_uuid()::text,
            TRIM(waiting_for),
            'person',
            NULL,
            user_id
        FROM (
            SELECT DISTINCT user_id, TRIM(waiting_for) AS waiting_for
            FROM todos
            WHERE waiting_for IS NOT NULL
              AND TRIM(waiting_for) <> ''
        ) AS unique_persons
        ON CONFLICT (user_id, type, name) DO NOTHING
        """
    )

    # Step 2: insert TodoTag junction rows linking each todo to its person-Tag.
    op.execute(
        """
        INSERT INTO todo_tags (id, todo_id, tag_id, user_id)
        SELECT
            gen_random_uuid()::text,
            t.id,
            tg.id,
            t.user_id
        FROM todos t
        JOIN tags tg
             ON tg.user_id = t.user_id
            AND tg.type    = 'person'
            AND tg.name    = TRIM(t.waiting_for)
        WHERE t.waiting_for IS NOT NULL
          AND TRIM(t.waiting_for) <> ''
        ON CONFLICT (todo_id, tag_id) DO NOTHING
        """
    )

    # E – Drop the now-redundant waiting_for column.
    op.drop_column("todos", "waiting_for")


def downgrade() -> None:
    # Re-add the column (data is lost — no downgrade path for the migration).
    op.add_column(
        "todos",
        sa.Column("waiting_for", sa.Text(), nullable=True),
    )

    # Remove person tags and their associations before reverting the unique
    # constraint: after upgrade, the same name may exist under multiple types
    # (e.g. "Bob" as context and "Bob" as person), which would violate the
    # narrower (user_id, name) unique index.
    op.execute("DELETE FROM todo_tags WHERE tag_id IN (SELECT id FROM tags WHERE type = 'person')")
    op.execute("DELETE FROM tags WHERE type = 'person'")

    # Revert constraints.
    op.drop_constraint("uq_tags_user_type_name", "tags", type_="unique")
    op.create_unique_constraint("uq_tags_user_name", "tags", ["user_id", "name"])
    op.drop_constraint("ck_tags_type", "tags", type_="check")
    op.create_check_constraint(
        "ck_tags_type",
        "tags",
        "type IN ('context','project','area','label')",
    )
    op.drop_column("todos", "last_clarified_at")
