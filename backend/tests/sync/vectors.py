"""Loader for the frozen golden vectors in ``spec/sync/``.

The same two files are loaded by ``app/test/sync/`` on the Dart side.  Neither
suite regenerates them: a codec change that is not a deliberate protocol change
must fail here rather than move the goalposts.
"""

from __future__ import annotations

import json
from functools import cache
from pathlib import Path
from typing import Any

SPEC_SYNC_DIR = Path(__file__).resolve().parents[3] / "spec" / "sync"

#: Stated explicitly rather than left to the platform default.  The Dart suite
#: parses these same bytes as UTF-8, so a non-UTF-8 locale is the one way the two
#: suites could disagree about a file neither of them is allowed to regenerate.
SPEC_ENCODING = "utf-8"


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
