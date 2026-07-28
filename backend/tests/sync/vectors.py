"""Loader for the frozen golden vectors in ``spec/sync/``.

The same two files are loaded by ``app/test/sync/`` on the Dart side.  Neither
suite regenerates them: a codec change that is not a deliberate protocol change
must fail here rather than move the goalposts.
"""

from __future__ import annotations

import json
import re
from functools import cache
from pathlib import Path
from typing import Any

SPEC_SYNC_DIR = Path(__file__).resolve().parents[3] / "spec" / "sync"

#: Stated explicitly rather than left to the platform default.  The Dart suite
#: parses these same bytes as UTF-8, so a non-UTF-8 locale is the one way the two
#: suites could disagree about a file neither of them is allowed to regenerate.
SPEC_ENCODING = "utf-8"

MERGE_STRATEGY_DART = (
    Path(__file__).resolve().parents[3] / "app" / "lib" / "sync" / "merge_strategy.dart"
)

_MERGE_STRATEGIES_BY_NAME = re.compile(r"mergeStrategiesByName\s*=\s*\{(?P<body>[^}]*)\}")
_STRATEGY_NAME = re.compile(r"'(?P<name>[^']+)'\s*:")


@cache
def envelope_vectors() -> dict[str, Any]:
    document: dict[str, Any] = json.loads(
        (SPEC_SYNC_DIR / "envelope_v1_vectors.json").read_text(encoding=SPEC_ENCODING)
    )
    return document


@cache
def reducer_vectors() -> dict[str, Any]:
    document: dict[str, Any] = json.loads(
        (SPEC_SYNC_DIR / "reducer_v1_vectors.json").read_text(encoding=SPEC_ENCODING)
    )
    return document


@cache
def dart_merge_strategy_names() -> frozenset[str]:
    """The strategy names a vector case may name, read off the Dart runner.

    ``mergeStrategiesByName`` in ``app/lib/sync/merge_strategy.dart`` is what the
    Dart vector runner resolves ``strategy_overrides`` through, so it — not a
    second list here — decides which names are known.  A copy in this suite
    would go stale the first time a strategy is registered on the Dart side.
    """
    source = MERGE_STRATEGY_DART.read_text(encoding="utf-8")
    body = _MERGE_STRATEGIES_BY_NAME.search(source)
    assert body is not None, f"no mergeStrategiesByName map in {MERGE_STRATEGY_DART}"
    names = frozenset(match["name"] for match in _STRATEGY_NAME.finditer(body["body"]))
    assert names, f"mergeStrategiesByName in {MERGE_STRATEGY_DART} names no strategies"
    return names
