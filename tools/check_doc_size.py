#!/usr/bin/env python3
"""Enforce the documentation size ceilings from AGENTS.md § Documentation in docs/.

Every document in docs/ is a map, and a map that no longer fits in one sitting
has stopped being a map. This file is the single source of truth for the
ceilings; AGENTS.md points here rather than restating the numbers.

Design docs sit slightly above ARCHITECTURE.md: they cover less ground at higher
fidelity, so they are allowed a little more room for it.

Enforcement is a ratchet, because the ceilings were adopted while several docs
were far above them. A doc under its ceiling may change freely up to it. A doc
over its ceiling may only shrink — so nothing gets worse from today, cleanup is
never blocked, and the ceiling takes over the moment a doc drops under it.

  tools/check_doc_size.py                 # report every tracked doc
  tools/check_doc_size.py --base origin/main   # enforce (CI)
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

# --- the ceilings -----------------------------------------------------------

ARCHITECTURE_CEILING = 3_000  # the country map: regions and the roads between
DESIGN_DOC_CEILING = 3_500  # city maps: one region, canals and watersheds
VOCABULARY_CEILING = 6_000  # the core words the project is thought in

CEILINGS: dict[str, int] = {
    "CONTEXT.md": VOCABULARY_CEILING,
    "docs/ARCHITECTURE.md": ARCHITECTURE_CEILING,
    "docs/DESIGN.md": DESIGN_DOC_CEILING,
    "docs/SYNC.md": DESIGN_DOC_CEILING,
    "docs/TESTING.md": DESIGN_DOC_CEILING,
    "docs/BACKEND_GUIDELINES.md": DESIGN_DOC_CEILING,
}

# --- counting ---------------------------------------------------------------

FENCED_CODE = re.compile(r"^\s*(```|~~~)")
TABLE_ROW = re.compile(r"^\s*\|")
HTML_COMMENT = re.compile(r"<!--.*?-->", re.S)


def prose_words(markdown: str) -> int:
    """Count prose words, excluding code blocks and tabular reference data.

    A word ceiling is the wrong instrument for a coordinate table or a matrix,
    so tables and fenced code are exempt; everything else is prose and counts.
    """
    text = HTML_COMMENT.sub("", markdown)
    words, in_fence = 0, False
    for line in text.splitlines():
        if FENCED_CODE.match(line):
            in_fence = not in_fence
            continue
        if in_fence or TABLE_ROW.match(line):
            continue
        words += len(line.split())
    return words


def count_at_ref(path: str, ref: str) -> int | None:
    """Prose words in `path` as of `ref`, or None if it did not exist there."""
    result = subprocess.run(
        ["git", "show", f"{ref}:{path}"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None
    return prose_words(result.stdout)


# --- reporting --------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--base",
        help="Enforce against this git ref: a doc over its ceiling may not grow.",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    failures: list[str] = []
    needs_cleanup: list[str] = []

    for path, ceiling in sorted(CEILINGS.items()):
        full = repo_root / path
        if not full.exists():
            print(f"  MISSING  {path} — tracked in CEILINGS but not on disk")
            failures.append(path)
            continue

        count = prose_words(full.read_text(encoding="utf-8"))

        if count <= ceiling:
            print(f"  ok       {path}: {count:,} / {ceiling:,} words")
            continue

        over = count - ceiling
        if not args.base:
            print(f"  OVER     {path}: {count:,} / {ceiling:,} words (+{over:,})")
            needs_cleanup.append(path)
            continue

        before = count_at_ref(path, args.base)
        if before is None:
            print(
                f"  FAIL     {path}: new file at {count:,} words, "
                f"ceiling {ceiling:,}"
            )
            failures.append(path)
        elif count > before:
            print(
                f"  FAIL     {path}: {before:,} -> {count:,} words "
                f"(+{count - before:,}); already {over:,} over the {ceiling:,} "
                f"ceiling, so it may only shrink"
            )
            failures.append(path)
        else:
            shrunk = before - count
            note = f"-{shrunk:,} this change" if shrunk else "unchanged"
            print(
                f"  over     {path}: {count:,} / {ceiling:,} words "
                f"(+{over:,}, {note}) — cleanup owed, not blocking"
            )
            needs_cleanup.append(path)

    print()
    if failures:
        print(
            "A document grew past what it is allowed. Every doc in docs/ is a "
            "map, not a reproduction of the territory:\n"
            "  WHAT  -> the doc          WHY   -> link an ADR / NOTES / CONTEXT term\n"
            "  HOW   -> the codebase     HISTORY -> git blame, the PR, the issue\n"
            "Cut something, or move it to the home that owns it. "
            "See AGENTS.md § Documentation in docs/."
        )
        return 1

    if needs_cleanup:
        print(
            f"{len(needs_cleanup)} document(s) still over ceiling and owed a "
            "cleanup pass. Not blocking: they did not grow."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
