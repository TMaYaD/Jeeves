"""Read-only converge-verify report over the legacy mirrored Postgres tables.

Cutover tooling for #553 Phase 1 (issue #582) — **removed by #556**.

Two SELECT-only routes, both scoped to the caller's own rows by
``Depends(get_current_user)``:

* ``GET /converge-verify/report`` — per synced table, the row count and the full
  ``id -> row_digest`` map.  Returning the whole map in one call rather than a
  digest-first / rows-on-mismatch handshake keeps the tool one round-trip and
  stateless; at one-user scale the payload is ~100 B per row.
* ``GET /converge-verify/rows`` — the canonical strings behind named ids, which
  is what turns an opaque digest mismatch into a column-level diff on the
  device.  Without it a reviewer cannot tell real divergence from a bug in the
  normaliser itself.

Nothing here writes, and nothing here raises on bad row data: a value the
manifest refuses becomes an anomaly in the report (see ``canonical.py``).
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.dependencies import get_current_user
from app.auth.models import User
from app.config import settings
from app.converge_verify.canonical import (
    CONVERGE_VERIFY_TABLES,
    canonical_row,
    excluded_columns_report,
    manifest_columns,
    parse_timestamp_utc_ms,
)
from app.database import get_db
from app.todos import models as todo_models

#: The SQLAlchemy model behind each synced table.  Written out rather than
#: derived from the metadata so a table leaving the synced set has to be removed
#: here deliberately; ``tests/test_converge_verify_canonical.py`` asserts this map
#: covers exactly the manifest's tables and that each model's columns match.
MODELS_BY_TABLE: dict[str, Any] = {
    "todos": todo_models.Todo,
    "tags": todo_models.Tag,
    "todo_tags": todo_models.TodoTag,
    "actions": todo_models.Action,
    "focus_sessions": todo_models.FocusSession,
    "time_logs": todo_models.TimeLog,
    "focus_session_tasks": todo_models.FocusSessionTask,
    "focus_session_dispositions": todo_models.FocusSessionDisposition,
    "user_preferences": todo_models.UserPreference,
    "captures": todo_models.Capture,
    "capture_outcomes": todo_models.CaptureOutcome,
    "capture_tags": todo_models.CaptureTag,
}

#: Ceiling on ``?ids=`` for the detail route.  Not configurable: the caller is a
#: review screen showing a human one table's mismatches at a time, and a request
#: for more ids than that is a client bug, not a workload to accommodate.  It is
#: a refusal rather than a silent truncation so a differ that outgrows it says so.
MAX_ROW_DETAIL_IDS = 200

router = APIRouter(prefix="/converge-verify", tags=["converge_verify"])


class RowAnomalyOut(BaseModel):
    """A value the manifest's column kind refused, named for the reviewer."""

    row_id: str | None
    column: str
    kind: str
    raw: str | None


class TableReportOut(BaseModel):
    count: int
    #: Junction ``id`` is nullable on the server (``gen_random_uuid()`` is only a
    #: default).  A NULL-id row has no row identity to match against the device,
    #: so it is counted here and left out of ``rows`` — and per the plan review it
    #: forces a non-converged verdict for the table rather than being a footnote.
    null_id_row_count: int
    rows: dict[str, str]
    anomalies: list[RowAnomalyOut]


class ConvergeVerifyReportOut(BaseModel):
    spec_version: int
    server_version: str
    generated_at: str
    excluded_columns: dict[str, list[str]]
    tables: dict[str, TableReportOut]


class RowDetailOut(BaseModel):
    table: str
    rows: dict[str, str]
    #: Ids the caller asked about that this user has no row for — the server-side
    #: half of a "only local" finding, confirmed rather than inferred.
    missing_ids: list[str]


#: Bumped only alongside a change to ``spec/converge_verify/``; the client refuses
#: to diff a report whose spec version it does not implement.
CONVERGE_VERIFY_SPEC_VERSION = 1


async def _rows_for_table(
    db: AsyncSession,
    table: str,
    user_id: str,
    ids: list[str] | None = None,
) -> list[dict[str, object]]:
    """SELECT the manifest's columns for this user's rows in [table]."""
    model = MODELS_BY_TABLE[table]
    columns = manifest_columns(table)
    statement = select(*[getattr(model, column) for column in columns]).where(
        model.user_id == user_id
    )
    if ids is not None:
        statement = statement.where(model.id.in_(ids))
    result = await db.execute(statement)
    return [dict(zip(columns, row, strict=True)) for row in result.all()]


@router.get("/report", response_model=ConvergeVerifyReportOut)
async def converge_verify_report(
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> ConvergeVerifyReportOut:
    tables: dict[str, TableReportOut] = {}
    for table in CONVERGE_VERIFY_TABLES:
        rows = await _rows_for_table(db, table, current_user.id)
        digests: dict[str, str] = {}
        anomalies: list[RowAnomalyOut] = []
        null_id_row_count = 0
        for values in rows:
            row_id = values.get("id")
            canonical = canonical_row(table, values)
            if not isinstance(row_id, str):
                null_id_row_count += 1
            else:
                digests[row_id] = canonical.digest
            for anomaly in canonical.anomalies:
                anomalies.append(
                    RowAnomalyOut(
                        row_id=row_id if isinstance(row_id, str) else None,
                        column=anomaly.column,
                        kind=anomaly.kind,
                        raw=anomaly.raw,
                    )
                )
        tables[table] = TableReportOut(
            count=len(rows),
            null_id_row_count=null_id_row_count,
            # Sorted so two consecutive calls are byte-identical: repeatability is
            # an acceptance criterion, and dict order is what the JSON carries.
            rows=dict(sorted(digests.items())),
            anomalies=sorted(anomalies, key=lambda a: (a.row_id or "", a.column)),
        )

    now = datetime.now(UTC)
    # Reuses the spec's own instant format so the report's timestamp reads the same
    # way as every timestamp inside it.
    generated_at = parse_timestamp_utc_ms(now) or now.isoformat()
    return ConvergeVerifyReportOut(
        spec_version=CONVERGE_VERIFY_SPEC_VERSION,
        server_version=settings.server_version,
        generated_at=generated_at,
        excluded_columns=excluded_columns_report(),
        tables=tables,
    )


@router.get("/rows", response_model=RowDetailOut)
async def converge_verify_rows(
    table: str = Query(...),
    # Repeated ``?ids=`` parameters rather than one comma-joined value: an id is
    # opaque data out of the legacy store, and a comma inside one would split into
    # two ids the server has no rows for — which the screen would then read as
    # "only on this device".  Values are taken verbatim for the same reason: a
    # stripped id is a different id.
    ids: Annotated[list[str] | None, Query()] = None,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> RowDetailOut:
    if table not in MODELS_BY_TABLE:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"{table!r} is not a converge-verify table",
        )
    requested = [piece for piece in (ids or []) if piece]
    if len(requested) > MAX_ROW_DETAIL_IDS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"at most {MAX_ROW_DETAIL_IDS} ids per request",
        )
    if not requested:
        return RowDetailOut(table=table, rows={}, missing_ids=[])

    rows = await _rows_for_table(db, table, current_user.id, ids=requested)
    canonical_by_id: dict[str, str] = {}
    for values in rows:
        row_id = values.get("id")
        if isinstance(row_id, str):
            canonical_by_id[row_id] = canonical_row(table, values).canonical
    return RowDetailOut(
        table=table,
        rows=dict(sorted(canonical_by_id.items())),
        missing_ids=sorted(set(requested) - set(canonical_by_id)),
    )
