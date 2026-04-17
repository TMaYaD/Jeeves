"""CSV and JSON parsers that produce NirvanaItem lists."""

import csv
import datetime as _datetime
import io
import json
import uuid as _uuid

from app.import_nirvana.schemas import NirvanaItem


class ParseError(Exception):
    """Raised when the uploaded file is structurally invalid."""


# ---------------------------------------------------------------------------
# State mapping helpers
# ---------------------------------------------------------------------------

_CSV_STATE_MAP: dict[str, str] = {
    "inbox": "inbox",
    "next": "next_action",
    "active": "inbox",
    "logbook": "done",
    "waiting": "waiting_for",
    "someday": "someday_maybe",
    "later": "someday_maybe",
    "focus": "next_action",
    "scheduled": "scheduled",
    "reference": "someday_maybe",
}

_JSON_STATE_MAP: dict[int, str] = {
    0: "inbox",
    1: "next_action",
    3: "scheduled",
    5: "someday_maybe",
    7: "done",
    9: "waiting_for",
    11: "inbox",
    13: "inbox",
}

_JSON_ENERGY_MAP: dict[int, str | None] = {
    0: None,
    1: "low",
    2: "medium",
    3: "high",
}


def _json_str(row: dict[str, object], field: str) -> str:
    """Return a string value from a JSON row, raising ParseError for non-string types."""
    value = row.get(field)
    if value is None:
        return ""
    if not isinstance(value, str):
        got = type(value).__name__
        raise ParseError(f"Invalid JSON field '{field}': expected string, got {got}")
    return value


def _normalise_csv_state(raw: str) -> str:
    return _CSV_STATE_MAP.get(raw.strip().lower(), "inbox")


def _parse_csv_tags(raw: str) -> list[str]:
    return [t.strip() for t in raw.split(",") if t.strip()]


def _parse_csv_date(raw: str) -> str | None:
    """Convert Nirvana CSV date strings (e.g. '2024-4-3') to 'YYYY-MM-DD'."""
    raw = raw.strip()
    if not raw:
        return None
    try:
        parts = [int(p) for p in raw.split("-")]
        if len(parts) == 3:
            year, month, day = parts
            _datetime.date(year, month, day)  # validates calendar ranges
            return f"{year:04d}-{month:02d}-{day:02d}"
    except (ValueError, TypeError):
        pass
    return None


def _parse_int(raw: str | int) -> int | None:
    try:
        v = int(raw)
        return v if v > 0 else None
    except (ValueError, TypeError):
        return None


# ---------------------------------------------------------------------------
# Public parsers
# ---------------------------------------------------------------------------


def parse_csv(content: str) -> tuple[list[NirvanaItem], int]:
    """Parse a Nirvana CSV export.

    Returns (items, skipped_count).  Skipped rows are those with an empty NAME
    or an unrecognised TYPE.
    """
    items: list[NirvanaItem] = []
    skipped = 0

    # Nirvana CSV exports sometimes end columns with a trailing comma which
    # produces an extra empty-string key in DictReader; we just ignore it.
    reader = csv.DictReader(io.StringIO(content))

    try:
        rows = list(reader)
    except csv.Error as exc:
        raise ParseError(f"Invalid CSV content: {exc}") from exc

    for row in rows:
        name = (row.get("NAME") or "").strip()
        if not name:
            skipped += 1
            continue

        raw_type = (row.get("TYPE") or "").strip().lower()
        if raw_type == "task":
            item_type: str = "task"
        elif raw_type == "project":
            item_type = "project"
        else:
            skipped += 1
            continue

        raw_state = (row.get("STATE") or "").strip()
        raw_completed = (row.get("COMPLETED") or "").strip()
        completed = bool(raw_completed)

        if completed and raw_state.lower() not in ("logbook",):
            state = "done"
        else:
            state = _normalise_csv_state(raw_state)

        parent_raw = (row.get("PARENT") or "").strip()
        parent_name = None if parent_raw.lower() in ("", "standalone") else parent_raw

        energy_raw = (row.get("ENERGY") or "").strip().lower()
        energy_level: str | None = energy_raw if energy_raw in ("low", "medium", "high") else None

        items.append(
            NirvanaItem(
                id=str(_uuid.uuid4()),
                name=name,
                type=item_type,  # type: ignore[arg-type]
                state=state,
                completed=completed,
                notes=(row.get("NOTES") or "").strip() or None,
                tags=_parse_csv_tags(row.get("TAGS") or ""),
                energy_level=energy_level,
                time_estimate=_parse_int(row.get("TIME") or ""),
                due_date=_parse_csv_date(row.get("DUEDATE") or ""),
                parent_id=None,
                parent_name=parent_name,
                waiting_for=(row.get("WAITINGFOR") or "").strip() or None,
            )
        )

    return items, skipped


def parse_json(content: str) -> tuple[list[NirvanaItem], int]:
    """Parse a Nirvana JSON export.

    Returns (items, skipped_count).  Filters out deleted and cancelled rows.
    """
    try:
        data = json.loads(content)
    except json.JSONDecodeError as exc:
        raise ParseError(f"Invalid JSON: {exc}") from exc

    if not isinstance(data, list):
        raise ParseError("JSON export must be a list of items")

    items: list[NirvanaItem] = []
    skipped = 0

    for row in data:
        if not isinstance(row, dict):
            skipped += 1
            continue

        if row.get("cancelled") or row.get("deleted"):
            skipped += 1
            continue

        name = _json_str(row, "name").strip()
        if not name:
            skipped += 1
            continue

        raw_type = row.get("type", 0)
        if raw_type == 1:
            item_type: str = "project"
        elif raw_type == 0:
            item_type = "task"
        else:
            skipped += 1
            continue

        raw_state = row.get("state", 0)
        state = _JSON_STATE_MAP.get(raw_state, "inbox")

        completed_ts = row.get("completed", 0)
        completed = bool(completed_ts)
        if completed:
            state = "done"

        # Tags: Nirvana stores as ",tag1,tag2," — strip leading/trailing commas
        raw_tags = _json_str(row, "tags")
        tags = [t.strip() for t in raw_tags.strip(",").split(",") if t.strip()]

        energy_raw = row.get("energy", 0)
        energy_level = _JSON_ENERGY_MAP.get(energy_raw)

        etime = row.get("etime", 0)
        time_estimate = etime if isinstance(etime, int) and etime > 0 else None

        duedate_raw = _json_str(row, "duedate")
        due_date = _parse_csv_date(duedate_raw) if duedate_raw.strip() else None

        parent_id = row.get("parentid") or None
        if parent_id == "":
            parent_id = None

        items.append(
            NirvanaItem(
                id=row.get("id") or str(_uuid.uuid4()),
                name=name,
                type=item_type,  # type: ignore[arg-type]
                state=state,
                completed=completed,
                notes=_json_str(row, "note").strip() or None,
                tags=tags,
                energy_level=energy_level,
                time_estimate=time_estimate,
                due_date=due_date,
                parent_id=parent_id,
                parent_name=None,
                waiting_for=_json_str(row, "waitingfor").strip() or None,
            )
        )

    return items, skipped
