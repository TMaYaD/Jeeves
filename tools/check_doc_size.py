#!/usr/bin/env python3
"""Enforce the documentation size ceilings from AGENTS.md § Documentation in docs/.

Every document in docs/ is a map, and a map that no longer fits in one sitting
has stopped being a map. This file is the single source of truth for the
ceilings; AGENTS.md points here rather than restating the numbers.

Design docs sit slightly above ARCHITECTURE.md: they cover less ground at higher
fidelity, so they are allowed a little more room for it.

Not every document is a map. TESTING.md and DESIGN.md are registers — a list of
harness traps, a list of components — whose length tracks an inventory rather
than a scale, so they get ceilings set from that inventory instead.

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
#
# Maps are bounded by what fits in one sitting, whatever their scale.

ARCHITECTURE_CEILING = 3_000  # the country map: regions and the roads between
DESIGN_DOC_CEILING = 3_500  # city maps: one region, canals and watersheds
VOCABULARY_CEILING = 10_000  # the core words the project is thought in

# Two documents are registers rather than maps, and a map's ceiling is the wrong
# instrument for them. A register is an enumeration whose length tracks an
# inventory out in the world, not the scale of the thing being drawn: it grows
# when the inventory grows, and cutting it deletes an entry someone needs rather
# than zooming out. They still get a ceiling — an unbounded document is how this
# started — but one set from the inventory, with headroom.

TEST_REGISTER_CEILING = 14_000  # strategy, plus the harness traps that keep biting
DESIGN_SYSTEM_CEILING = 6_000  # tokens, components and surfaces, one entry each
REQUIREMENTS_CEILING = 8_000  # epics and their acceptance criteria, one entry each

CEILINGS: dict[str, int] = {
    "CONTEXT.md": VOCABULARY_CEILING,
    "docs/ARCHITECTURE.md": ARCHITECTURE_CEILING,
    "docs/CEREMONIES.md": DESIGN_DOC_CEILING,
    "docs/SYNC.md": DESIGN_DOC_CEILING,
    "docs/BACKEND_GUIDELINES.md": DESIGN_DOC_CEILING,
    "docs/DESIGN.md": DESIGN_SYSTEM_CEILING,
    "docs/TESTING.md": TEST_REGISTER_CEILING,
    "docs/REQUIREMENTS.md": REQUIREMENTS_CEILING,
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

    for path, ceiling_words in sorted(CEILINGS.items()):
        document = repo_root / path
        if not document.exists():
            print(f"  MISSING  {path} — tracked in CEILINGS but not on disk")
            failures.append(path)
            continue

        prose_word_count = prose_words(document.read_text(encoding="utf-8"))

        if prose_word_count <= ceiling_words:
            print(f"  ok       {path}: {prose_word_count:,} / {ceiling_words:,} words")
            continue

        words_over_ceiling = prose_word_count - ceiling_words
        if not args.base:
            print(
                f"  OVER     {path}: {prose_word_count:,} / {ceiling_words:,} "
                f"words (+{words_over_ceiling:,})"
            )
            needs_cleanup.append(path)
            continue

        base_prose_word_count = count_at_ref(path, args.base)
        if base_prose_word_count is None:
            print(
                f"  FAIL     {path}: new file at {prose_word_count:,} words, "
                f"ceiling {ceiling_words:,}"
            )
            failures.append(path)
        elif prose_word_count > base_prose_word_count:
            print(
                f"  FAIL     {path}: {base_prose_word_count:,} -> "
                f"{prose_word_count:,} words "
                f"(+{prose_word_count - base_prose_word_count:,}); already "
                f"{words_over_ceiling:,} over the {ceiling_words:,} ceiling, "
                f"so it may only shrink"
            )
            failures.append(path)
        else:
            words_removed = base_prose_word_count - prose_word_count
            note = f"-{words_removed:,} this change" if words_removed else "unchanged"
            print(
                f"  over     {path}: {prose_word_count:,} / {ceiling_words:,} "
                f"words (+{words_over_ceiling:,}, {note}) — cleanup owed, "
                f"not blocking"
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
