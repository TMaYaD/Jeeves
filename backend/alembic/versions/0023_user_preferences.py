"""Add user_preferences table for cross-device synced key-value storage.

Revision ID: 0023
Revises: 0022
"""

import sqlalchemy as sa

from alembic import op

revision = "0023"
down_revision = "0022"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "user_preferences",
        sa.Column("id", sa.String, primary_key=True),
        sa.Column(
            "user_id",
            sa.String,
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("key", sa.String(100), nullable=False),
        sa.Column("value", sa.Text, nullable=True),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
    )
    op.create_unique_constraint(
        "uq_user_preferences_user_key", "user_preferences", ["user_id", "key"]
    )

    # Trigger to keep updated_at current on every UPDATE.
    op.execute("""
        CREATE OR REPLACE FUNCTION set_user_preferences_updated_at()
        RETURNS TRIGGER AS $$
        BEGIN
            NEW.updated_at = now();
            RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
    """)
    op.execute("""
        CREATE TRIGGER trg_user_preferences_set_updated_at
        BEFORE UPDATE ON user_preferences
        FOR EACH ROW EXECUTE FUNCTION set_user_preferences_updated_at();
    """)

    op.create_index("ix_user_preferences_user_id", "user_preferences", ["user_id"])

    # Add to PowerSync publication so changes are replicated to clients.
    op.execute("ALTER PUBLICATION powersync ADD TABLE user_preferences")


def downgrade() -> None:
    op.execute("ALTER PUBLICATION powersync DROP TABLE user_preferences")
    op.execute("DROP TRIGGER IF EXISTS trg_user_preferences_set_updated_at ON user_preferences")
    op.execute("DROP FUNCTION IF EXISTS set_user_preferences_updated_at()")
    op.drop_index("ix_user_preferences_user_id", table_name="user_preferences")
    op.drop_constraint("uq_user_preferences_user_key", "user_preferences", type_="unique")
    op.drop_table("user_preferences")
