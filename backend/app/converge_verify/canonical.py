"""Canonical row serialisation for the converge-verify check (#553 Phase 1).

Cutover tooling — removed by #556.

The twin of ``app/lib/cutover/converge_verify/canonical_row.dart``.  Neither is
the reference: both are measured against the frozen, hand-authored vectors in
``spec/converge_verify/canonical_row_vectors.json``, which also carry the column
manifest both sides hardcode.  A digest that depends on which side computed it
would make the whole check worthless, so the encoding is spelled out here rather
than delegated to ``json.dumps`` — the two languages' JSON writers disagree on
control-character escaping.

Nothing in this module raises on bad data.  A value a column kind refuses
degrades to a sentinel in the canonical string plus a :class:`RowAnomaly`, and
the caller surfaces it.  A throw would brick the report on the one device the
check exists to inspect.
"""

from __future__ import annotations

import hashlib
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

# --- column kinds -----------------------------------------------------------

VERBATIM_TEXT = "verbatim_text"
INTEGER = "integer"
BOOLEAN_AS_INT = "boolean_as_int"
TIMESTAMP_UTC_MS = "timestamp_utc_ms"

# --- anomaly kinds ----------------------------------------------------------

UNPARSEABLE_TIMESTAMP = "unparseable_timestamp"
INVALID_BOOLEAN = "invalid_boolean"
INVALID_INTEGER = "invalid_integer"
INVALID_TEXT = "invalid_text"
MISSING_COLUMN = "missing_column"

# --- declared exclusions ----------------------------------------------------

#: ``user_id`` is server-derived from the JWT on every table (docs/SYNC.md
#: ownership matrix), so the server side is JWT-scoped by construction and
#: comparing the column adds nothing.  The client deliberately reads its tables
#: *unfiltered* instead: a row stranded at ``user_id = 'local'`` then surfaces as
#: a local-only id, which is exactly the divergence Phase 1 must catch.
EXCLUDED_COLUMNS_EVERY_TABLE: tuple[str, ...] = ("user_id",)

#: ``todos.time_spent_minutes`` is a dead denormalized cache — never read or
#: written (docs/SYNC.md), never carried by the op log (ADR-0030), and already
#: excluded from the Phase-2 comparison (docs/TESTING.md).  Phase 1's definition
#: of "converged" matches what the reseed will actually preserve.  The report
#: names the exclusion so the reviewer sees the judgment call.
EXCLUDED_COLUMNS_BY_TABLE: Mapping[str, tuple[str, ...]] = {
    "todos": ("time_spent_minutes",),
}

# --- the manifest -----------------------------------------------------------

#: Ordered ``(column, kind)`` pairs per synced table.  Column order is
#: alphabetical so neither side's declaration order (Drift's vs SQLAlchemy's) can
#: silently become the contract.  ``spec/converge_verify`` carries the same
#: manifest and ``tests/test_converge_verify_canonical.py`` asserts both this map
#: and the live SQLAlchemy models against it.
CANONICAL_ROW_MANIFEST: Mapping[str, tuple[tuple[str, str], ...]] = {
    "todos": (
        ("capture_source", VERBATIM_TEXT),
        ("clarified", BOOLEAN_AS_INT),
        ("created_at", TIMESTAMP_UTC_MS),
        ("done_at", TIMESTAMP_UTC_MS),
        ("due_date", TIMESTAMP_UTC_MS),
        ("energy_level", VERBATIM_TEXT),
        ("id", VERBATIM_TEXT),
        ("intent", VERBATIM_TEXT),
        ("last_clarified_at", TIMESTAMP_UTC_MS),
        ("last_next_action_completion_at", TIMESTAMP_UTC_MS),
        ("location_id", VERBATIM_TEXT),
        ("notes", VERBATIM_TEXT),
        ("priority", INTEGER),
        ("time_estimate", INTEGER),
        ("title", VERBATIM_TEXT),
        ("updated_at", TIMESTAMP_UTC_MS),
    ),
    "tags": (
        ("color", VERBATIM_TEXT),
        ("id", VERBATIM_TEXT),
        ("name", VERBATIM_TEXT),
        ("type", VERBATIM_TEXT),
    ),
    "todo_tags": (
        ("id", VERBATIM_TEXT),
        ("tag_id", VERBATIM_TEXT),
        ("todo_id", VERBATIM_TEXT),
    ),
    "actions": (
        ("created_at", TIMESTAMP_UTC_MS),
        ("done_at", TIMESTAMP_UTC_MS),
        ("energy_level", VERBATIM_TEXT),
        ("id", VERBATIM_TEXT),
        ("outcome_id", VERBATIM_TEXT),
        ("position", INTEGER),
        ("role", VERBATIM_TEXT),
        ("text", VERBATIM_TEXT),
        ("time_estimate", INTEGER),
        ("updated_at", TIMESTAMP_UTC_MS),
    ),
    "focus_sessions": (
        ("current_task_id", VERBATIM_TEXT),
        ("ended_at", TIMESTAMP_UTC_MS),
        ("id", VERBATIM_TEXT),
        ("started_at", TIMESTAMP_UTC_MS),
    ),
    "time_logs": (
        ("action_id", VERBATIM_TEXT),
        ("ended_at", TIMESTAMP_UTC_MS),
        ("focus_session_id", VERBATIM_TEXT),
        ("id", VERBATIM_TEXT),
        ("started_at", TIMESTAMP_UTC_MS),
        ("task_id", VERBATIM_TEXT),
    ),
    "focus_session_tasks": (
        ("disposition", VERBATIM_TEXT),
        ("focus_session_id", VERBATIM_TEXT),
        ("id", VERBATIM_TEXT),
        ("position", INTEGER),
        ("task_id", VERBATIM_TEXT),
    ),
    "focus_session_dispositions": (
        ("disposition", VERBATIM_TEXT),
        ("focus_session_id", VERBATIM_TEXT),
        ("id", VERBATIM_TEXT),
        ("task_id", VERBATIM_TEXT),
    ),
    "user_preferences": (
        ("id", VERBATIM_TEXT),
        ("key", VERBATIM_TEXT),
        ("updated_at", TIMESTAMP_UTC_MS),
        ("value", VERBATIM_TEXT),
    ),
    "captures": (
        ("capture_source", VERBATIM_TEXT),
        ("clarified_at", TIMESTAMP_UTC_MS),
        ("created_at", TIMESTAMP_UTC_MS),
        ("id", VERBATIM_TEXT),
        ("notes", VERBATIM_TEXT),
        ("title", VERBATIM_TEXT),
        ("updated_at", TIMESTAMP_UTC_MS),
    ),
    "capture_outcomes": (
        ("capture_id", VERBATIM_TEXT),
        ("created_at", TIMESTAMP_UTC_MS),
        ("id", VERBATIM_TEXT),
        ("outcome_id", VERBATIM_TEXT),
    ),
    "capture_tags": (
        ("capture_id", VERBATIM_TEXT),
        ("id", VERBATIM_TEXT),
        ("tag_id", VERBATIM_TEXT),
    ),
}

#: The tables the check compares, in a stable order for the report.
CONVERGE_VERIFY_TABLES: tuple[str, ...] = tuple(CANONICAL_ROW_MANIFEST)


# --- results ----------------------------------------------------------------


@dataclass(frozen=True)
class RowAnomaly:
    """A value the manifest's kind refused, named so a reviewer can go look."""

    column: str
    kind: str
    raw: str | None

    def to_json(self) -> dict[str, str | None]:
        return {"column": self.column, "kind": self.kind, "raw": self.raw}


@dataclass(frozen=True)
class CanonicalRow:
    canonical: str
    digest: str
    anomalies: tuple[RowAnomaly, ...]


# --- the canonical encoder --------------------------------------------------

_TEXT_ESCAPES = {
    '"': '\\"',
    "\\": "\\\\",
    "\b": "\\b",
    "\t": "\\t",
    "\n": "\\n",
    "\f": "\\f",
    "\r": "\\r",
}


def encode_canonical_text(value: str) -> str:
    """A double-quoted JSON string under the spec's exact escape table.

    Hand-rolled rather than ``json.dumps``: Dart's encoder spells a C0 control
    that has no short escape with uppercase hex, Python's with lowercase, and the
    digest may not depend on which side computed it.
    """
    out = ['"']
    for character in value:
        escape = _TEXT_ESCAPES.get(character)
        if escape is not None:
            out.append(escape)
        elif character < " ":
            out.append(f"\\u{ord(character):04x}")
        else:
            out.append(character)
    out.append('"')
    return "".join(out)


def raw_as_text(value: object) -> str:
    """One shared spelling for a refused value (see the spec's ``raw_as_text``)."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, str):
        return value
    if isinstance(value, float):
        # Deliberately not formatted: shortest-round-trip float formatting is not
        # guaranteed identical across the two languages.
        return "<number>"
    return "<unknown>"


def _sentinel(kind: str, value: object) -> str:
    if kind == MISSING_COLUMN:
        return '{"missing_column":true}'
    return f"{{{encode_canonical_text(kind)}:{encode_canonical_text(raw_as_text(value))}}}"


# --- timestamps -------------------------------------------------------------

#: ``[ \t]`` rather than ``\s``: Python's and Dart's regex engines disagree about
#: which exotic code points ``\s`` covers, and a grammar the two sides read
#: differently is exactly the divergence the frozen spec exists to prevent.
_TIMESTAMP_PATTERN = re.compile(
    r"^[ \t]*(\d{4})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2})"
    r"(?::(\d{2})(?:\.(\d+))?)?[ \t]*(Z|z|[+-]\d{2}(?::?\d{2})?)?[ \t]*$"
)


def _offset_minutes(raw: str | None) -> int | None:
    """Signed minutes east of UTC, or ``None`` when the offset is out of range."""
    if raw is None or raw in ("Z", "z"):
        return 0
    sign = -1 if raw[0] == "-" else 1
    digits = raw[1:].replace(":", "")
    hours = int(digits[:2])
    minutes = int(digits[2:4]) if len(digits) > 2 else 0
    if hours > 23 or minutes > 59:
        return None
    return sign * (hours * 60 + minutes)


def _format_instant(moment: datetime) -> str | None:
    if not 1 <= moment.year <= 9999:
        return None
    return (
        f"{moment.year:04d}-{moment.month:02d}-{moment.day:02d}"
        f"T{moment.hour:02d}:{moment.minute:02d}:{moment.second:02d}"
        f".{moment.microsecond // 1000:03d}Z"
    )


def parse_timestamp_utc_ms(value: object) -> str | None:
    """``YYYY-MM-DDTHH:MM:SS.mmmZ``, or ``None`` when the rules refuse the value.

    Accepts a ``datetime`` (what a Postgres ``timestamptz`` row yields — naive is
    assumed UTC) or a string under the tolerant grammar frozen in the spec.  The
    instant truncates, never rounds, to millisecond precision: milliseconds are
    the client-authorship grain, and a server-minted microsecond value reaches
    the device carrying the same microseconds, so both sides truncate identically.
    """
    if isinstance(value, datetime):
        aware = value if value.tzinfo is not None else value.replace(tzinfo=UTC)
        return _format_instant(aware.astimezone(UTC))
    if not isinstance(value, str):
        return None

    match = _TIMESTAMP_PATTERN.match(value)
    if match is None:
        return None
    year, month, day = int(match[1]), int(match[2]), int(match[3])
    hour, minute = int(match[4]), int(match[5])
    second = int(match[6]) if match[6] is not None else 0
    fraction = match[7] or ""
    millis = int((fraction + "000")[:3]) if fraction else 0
    if hour > 23 or minute > 59 or second > 59:
        return None
    offset = _offset_minutes(match[8])
    if offset is None:
        return None
    try:
        naive = datetime(year, month, day, hour, minute, second, millis * 1000, tzinfo=UTC)
        instant = naive - timedelta(minutes=offset)
    except (ValueError, OverflowError):
        return None
    return _format_instant(instant)


# --- per-column encoding ----------------------------------------------------


def _encode_column(kind: str, value: object) -> tuple[str, str | None]:
    """``(encoded, refusal_kind)`` for one column value."""
    if value is None:
        return "null", None

    if kind == VERBATIM_TEXT:
        if isinstance(value, str):
            return encode_canonical_text(value), None
        return _sentinel(INVALID_TEXT, value), INVALID_TEXT

    if kind == INTEGER:
        if isinstance(value, bool):
            return _sentinel(INVALID_INTEGER, value), INVALID_INTEGER
        if isinstance(value, int):
            return str(value), None
        if isinstance(value, float) and value.is_integer():
            return str(int(value)), None
        return _sentinel(INVALID_INTEGER, value), INVALID_INTEGER

    if kind == BOOLEAN_AS_INT:
        if isinstance(value, bool):
            return ("1" if value else "0"), None
        if isinstance(value, int) and value in (0, 1):
            return str(value), None
        return _sentinel(INVALID_BOOLEAN, value), INVALID_BOOLEAN

    if kind == TIMESTAMP_UTC_MS:
        instant = parse_timestamp_utc_ms(value)
        if instant is not None:
            return encode_canonical_text(instant), None
        return _sentinel(UNPARSEABLE_TIMESTAMP, value), UNPARSEABLE_TIMESTAMP

    # Unreachable while the manifest and the kind constants agree, and the vector
    # suite asserts they do.  Degrade rather than raise, on principle and for
    # parity with the Dart twin's `default` case: a raise here would 500 the whole
    # report, which is the one failure mode this module is built to avoid.
    return _sentinel(INVALID_TEXT, value), INVALID_TEXT


_MISSING = object()


def canonical_row(table: str, values: Mapping[str, object]) -> CanonicalRow:
    """The canonical string, its SHA-256 digest, and any per-row anomalies."""
    manifest = CANONICAL_ROW_MANIFEST[table]
    encoded: list[str] = []
    anomalies: list[RowAnomaly] = []
    for column, kind in manifest:
        raw = values.get(column, _MISSING)
        if raw is _MISSING:
            encoded.append(_sentinel(MISSING_COLUMN, None))
            anomalies.append(RowAnomaly(column=column, kind=MISSING_COLUMN, raw=None))
            continue
        piece, refusal = _encode_column(kind, raw)
        encoded.append(piece)
        if refusal is not None:
            anomalies.append(RowAnomaly(column=column, kind=refusal, raw=raw_as_text(raw)))
    canonical = "[" + ",".join(encoded) + "]"
    return CanonicalRow(
        canonical=canonical,
        digest=hashlib.sha256(canonical.encode("utf-8")).hexdigest(),
        anomalies=tuple(anomalies),
    )


def excluded_columns_report() -> dict[str, list[str]]:
    """The declared exclusions, published in the report so a reviewer sees them."""
    report: dict[str, list[str]] = {"*": list(EXCLUDED_COLUMNS_EVERY_TABLE)}
    for table, columns in EXCLUDED_COLUMNS_BY_TABLE.items():
        report[table] = list(columns)
    return report


def manifest_columns(table: str) -> Sequence[str]:
    return [column for column, _ in CANONICAL_ROW_MANIFEST[table]]
