"""The canonical row serialiser against ``spec/converge_verify/``.

Cutover tooling — removed by #556.

The twin of ``app/test/cutover/canonical_row_test.dart``: both suites run every
vector in the same frozen file, which is the only thing keeping the two
implementations from drifting.  Neither suite regenerates it — see the spec's
README.

This file also holds the Python half of the anti-drift guard: the manifest must
match the live SQLAlchemy models, so a newly synced column fails the suite
instead of going quietly unverified.
"""

from __future__ import annotations

import hashlib
import json
from datetime import UTC, datetime, timedelta, timezone
from functools import cache
from pathlib import Path
from typing import Any

import pytest

from app.converge_verify.canonical import (
    CANONICAL_ROW_MANIFEST,
    EXCLUDED_COLUMNS_BY_TABLE,
    EXCLUDED_COLUMNS_EVERY_TABLE,
    canonical_row,
    encode_canonical_text,
    excluded_columns_report,
    parse_timestamp_utc_ms,
)
from app.converge_verify.routes import MODELS_BY_TABLE

SPEC_FILE = (
    Path(__file__).resolve().parents[2] / "spec" / "converge_verify" / "canonical_row_vectors.json"
)

#: Stated explicitly: the Dart suite parses these same bytes as UTF-8, so a
#: non-UTF-8 locale is the one way the two suites could disagree about a file
#: neither of them may regenerate.
SPEC_ENCODING = "utf-8"


@cache
def spec() -> dict[str, Any]:
    document: dict[str, Any] = json.loads(SPEC_FILE.read_text(encoding=SPEC_ENCODING))
    return document


def row_vectors() -> list[dict[str, Any]]:
    return [entry for entry in spec()["row_vectors"]]


def timestamp_vectors() -> list[dict[str, Any]]:
    return [entry for entry in spec()["timestamp_parsing"]["vectors"]]


# --- the manifest is the contract -------------------------------------------


def test_manifest_matches_the_frozen_spec() -> None:
    spec_manifest = {
        table: [tuple(pair) for pair in columns] for table, columns in spec()["manifest"].items()
    }
    ours = {table: list(columns) for table, columns in CANONICAL_ROW_MANIFEST.items()}
    assert ours == spec_manifest


def test_declared_exclusions_match_the_frozen_spec() -> None:
    assert excluded_columns_report() == spec()["excluded_columns"]


def test_manifest_matches_the_sqlalchemy_models() -> None:
    """A newly synced column fails here rather than going unverified.

    The manifest is every column of the model minus the declared exclusions.  The
    reverse direction matters just as much: a manifest column the model does not
    have would silently canonicalise to a ``missing_column`` sentinel on every
    row.
    """
    assert set(MODELS_BY_TABLE) == set(CANONICAL_ROW_MANIFEST)
    for table, model in MODELS_BY_TABLE.items():
        model_columns = {column.name for column in model.__table__.columns}
        excluded = set(EXCLUDED_COLUMNS_EVERY_TABLE) | set(EXCLUDED_COLUMNS_BY_TABLE.get(table, ()))
        assert excluded <= model_columns, f"{table}: exclusion names a column the model lacks"
        expected = model_columns - excluded
        assert {column for column, _ in CANONICAL_ROW_MANIFEST[table]} == expected, table


def test_manifest_columns_are_alphabetical_and_unique() -> None:
    for table, columns in CANONICAL_ROW_MANIFEST.items():
        names = [column for column, _ in columns]
        assert names == sorted(names), table
        assert len(set(names)) == len(names), table


def test_every_manifest_kind_is_declared() -> None:
    declared = set(spec()["column_kinds"])
    for table, columns in CANONICAL_ROW_MANIFEST.items():
        for column, kind in columns:
            assert kind in declared, f"{table}.{column}"


# --- timestamp parsing rules ------------------------------------------------


@pytest.mark.parametrize("vector", timestamp_vectors(), ids=lambda v: str(v["name"]))
def test_timestamp_vector(vector: dict[str, Any]) -> None:
    assert parse_timestamp_utc_ms(vector["raw"]) == vector["expected"]


def test_spec_carries_both_accepting_and_refusing_timestamp_vectors() -> None:
    expectations = [vector["expected"] for vector in timestamp_vectors()]
    assert any(value is None for value in expectations)
    assert any(value is not None for value in expectations)


def test_aware_datetime_matches_the_equivalent_string() -> None:
    """A Postgres ``timestamptz`` row and its ISO text canonicalise identically."""
    kolkata = timezone(timedelta(hours=5, minutes=30))
    moment = datetime(2026, 4, 30, 0, 0, 0, 0, tzinfo=kolkata)
    assert parse_timestamp_utc_ms(moment) == "2026-04-29T18:30:00.000Z"
    assert parse_timestamp_utc_ms(moment) == parse_timestamp_utc_ms(
        "2026-04-30T00:00:00.000 +05:30"
    )


def test_naive_datetime_is_assumed_utc() -> None:
    assert parse_timestamp_utc_ms(datetime(2026, 4, 30, 5, 30, 0)) == "2026-04-30T05:30:00.000Z"


def test_datetime_microseconds_truncate_rather_than_round() -> None:
    moment = datetime(2026, 4, 30, 5, 30, 0, 123_999, tzinfo=UTC)
    assert parse_timestamp_utc_ms(moment) == "2026-04-30T05:30:00.123Z"


def test_non_timestamp_types_are_refused_rather_than_guessed() -> None:
    # Epoch milliseconds are a plausible legacy shape and deliberately not
    # inferred: guessing seconds-vs-millis would invent convergence.
    assert parse_timestamp_utc_ms(1_714_435_200_000) is None
    assert parse_timestamp_utc_ms(True) is None
    assert parse_timestamp_utc_ms(None) is None


# --- row vectors -------------------------------------------------------------


@pytest.mark.parametrize("vector", row_vectors(), ids=lambda v: str(v["name"]))
def test_row_vector(vector: dict[str, Any]) -> None:
    result = canonical_row(vector["table"], vector["raw"])
    assert result.canonical == vector["canonical"]
    assert result.digest == vector["digest"]
    assert [anomaly.to_json() for anomaly in result.anomalies] == vector["anomalies"]


@pytest.mark.parametrize("vector", row_vectors(), ids=lambda v: str(v["name"]))
def test_pinned_digest_is_sha256_of_the_pinned_canonical_string(vector: dict[str, Any]) -> None:
    """The only computed field in the spec, re-derived rather than trusted."""
    expected = hashlib.sha256(str(vector["canonical"]).encode("utf-8")).hexdigest()
    assert vector["digest"] == expected


def test_every_table_has_at_least_one_row_vector() -> None:
    covered = {vector["table"] for vector in row_vectors()}
    assert covered == set(CANONICAL_ROW_MANIFEST)


def test_the_two_stores_shapes_agree_on_a_digest() -> None:
    """The point of the whole exercise: one logical row, two raw shapes, one digest.

    The local store holds Drift's space-before-offset text and SQLite integer
    booleans; Postgres holds ``timestamptz`` and real booleans.  A vector group
    names the same logical row in both shapes, and the digests must match — a
    mismatch here would report every row on the phone as divergent.
    """
    groups: dict[str, list[dict[str, Any]]] = {}
    for vector in row_vectors():
        group = vector.get("logical_row_group")
        if group is not None:
            groups.setdefault(str(group), []).append(vector)
    assert groups, "the spec declares no cross-shape group"
    for group, members in groups.items():
        assert len(members) > 1, f"{group} has one member, so it proves nothing"
        digests = {canonical_row(m["table"], m["raw"]).digest for m in members}
        assert len(digests) == 1, group


def test_excluded_columns_do_not_reach_the_digest() -> None:
    """Two rows differing only in an excluded column share a digest."""
    base = dict(row_vectors()[0]["raw"])
    other = dict(base, user_id="someone-else", time_spent_minutes=4321)
    assert canonical_row("todos", base).digest == canonical_row("todos", other).digest


def test_null_is_not_the_empty_string() -> None:
    base = {column: None for column, _ in CANONICAL_ROW_MANIFEST["tags"]}
    with_empty = dict(base, color="")
    assert canonical_row("tags", base).canonical == "[null,null,null,null]"
    assert canonical_row("tags", with_empty).canonical == '["",null,null,null]'
    assert canonical_row("tags", base).digest != canonical_row("tags", with_empty).digest


# --- the encoder's escape table ---------------------------------------------


def test_control_characters_use_lowercase_hex() -> None:
    assert encode_canonical_text("\x0b") == '"\\u000b"'
    assert encode_canonical_text("\x1f") == '"\\u001f"'


def test_short_escapes_win_over_the_hex_form() -> None:
    assert encode_canonical_text("\b\t\n\f\r") == '"\\b\\t\\n\\f\\r"'


def test_delete_and_non_ascii_are_emitted_literally() -> None:
    assert encode_canonical_text("\x7fcafé 🚀") == '"\x7fcafé 🚀"'


def test_quote_and_backslash_are_escaped() -> None:
    assert encode_canonical_text('a"b\\c') == '"a\\"b\\\\c"'


def test_the_canonical_string_is_parseable_json() -> None:
    for vector in row_vectors():
        json.loads(vector["canonical"])
