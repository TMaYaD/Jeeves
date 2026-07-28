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


@cache
def envelope_vectors() -> dict[str, Any]:
    document: dict[str, Any] = json.loads((SPEC_SYNC_DIR / "envelope_v1_vectors.json").read_text())
    return document


@cache
def reducer_vectors() -> dict[str, Any]:
    document: dict[str, Any] = json.loads((SPEC_SYNC_DIR / "reducer_v1_vectors.json").read_text())
    return document
