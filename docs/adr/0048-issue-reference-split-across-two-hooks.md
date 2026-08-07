# ADR-0048: The issue reference is appended by two hooks over one shared contract

**Status:** Accepted. Extends the branch-name extraction contract settled in #666 (the
anchored parameter-expansion rules and the bare-digits output) to the editor commit path,
which #666 left as a deliberate no-op.

## Context

`.githooks/prepare-commit-msg` appends `(#N)` to a commit subject from the branch name. It
runs **before** git opens the editor, so on a plain `git commit` the file it receives holds
only git's comment block and no subject — there is nothing to append to, and the hook
appends nothing there by design (#666). The result was a gap: `git commit -m` got a
reference, `git commit` through the editor did not, and which one a contributor got depended
only on how they happened to commit (#679).

The subject the editor path is owed exists only **after** the editor closes — which is when
`.githooks/commit-msg` runs. `commit-msg` already exists and is already wired through
`core.hooksPath`, so the reference belongs there. The catch is that git does **not** pass
`commit-msg` the `$COMMIT_SOURCE` that `prepare-commit-msg` uses to tell `-m` from a merge
from a fixup from the editor.

## Decision

**Both hooks append through one shared library, `.githooks/lib/issue-reference.sh`.** The
branch-name contract — accepted shapes, bare-digits output, the already-referenced guards —
lives there once, so the two callers cannot drift. `prepare-commit-msg` keeps the `-m`/`-F`
path; `commit-msg` takes the editor path.

**`commit-msg` reconstructs the absent `$COMMIT_SOURCE` from intrinsic signals** rather than
having it handed over: a merge or squash is recognised from git's in-progress marker files,
an autosquash from the `fixup!`/`squash!`/`amend!` subject prefix, and a rebase from the fact
that git parks you on a **detached HEAD** there — so no branch name, and no number, is
produced. That last one is the load-bearing subtlety of the whole design: it is an *accident
of git's rebase implementation*, not a guard anyone wrote, and it is the only reason a reword
or an autosquash-combine does not acquire a spurious reference. It carries a dedicated
regression test precisely because a future git that stopped detaching HEAD there would
silently break it. (The exact signals, guard ordering, and library-location fallback are
documented where they live — in the hook comments and `docs/TESTING.md` — not here.)

The format validation runs **before** the reference logic and needs no library, so an
unreadable or missing lib degrades the *feature* to a non-blocking no-op (a warning on
stderr, then success) without ever disabling the format check that every push depends on. The
same ordering keeps quit-to-cancel intact on the editor path: a comments-only quit fails
validation, and an *untouched* `commit.template` is detected and left unappended so git's own
"did not edit the message" abort still fires — appending would otherwise fabricate a commit
from a cancelled one.

## Consequences

Behaviour on the `-m`/reuse family is **not** byte-identical to `main`. It differs two
safe-direction ways, both because the append moved onto a hook that cannot see
`$COMMIT_SOURCE`:

- **The `$COMMIT_SOURCE = commit` reuse paths gain a reference `main` did not add.** Plain
  `git commit --amend`, `git commit -c <commit>` and `git commit -C <commit>` of a genuinely
  *unreferenced* subject on a conventional branch now gain that branch's `(#N)`. `main`'s
  `prepare-commit-msg` skipped these (source `commit`); `commit-msg` cannot tell them from
  the editor path, so it appends.
- **The trailing-reference guard suppresses a reference `main` would have appended.** On any
  path — including `-m` — a subject already ending in *some* issue's reference keeps it and
  is not given a second: `main` recorded `fix: follow-up to (#500) (#605)`, the shared
  contract now records `fix: follow-up to (#500)`.

Both are the safe direction — the subject ends with at most one trailing reference, never a
doubled or corrupted one — and consistent with the user story. Making them byte-identical would require
relaying `$COMMIT_SOURCE` from `prepare-commit-msg` through `.git/` state into `commit-msg`;
that was rejected as adding a cross-hook invariant the codebase's hook comments consistently
avoid, and the trade is recorded here so it is not re-litigated.

The reliance on the detached-HEAD accident is the one fragile assumption, which is why it
lives behind a test rather than only in this document. A stale `SQUASH_MSG` from an abandoned
`merge --squash` can suppress one append until git removes it — again the safe direction (a
missing reference, never a corrupted subject).
