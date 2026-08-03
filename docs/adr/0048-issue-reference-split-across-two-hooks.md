# ADR-0048: The issue reference is appended by two hooks over one shared contract

**Status:** Accepted. Extends the branch-name extraction contract settled in #666 (the
anchored parameter-expansion rules and the bare-digits output) to the editor commit path,
which #666 left as a deliberate no-op.

## Context

`.githooks/prepare-commit-msg` appends `(#N)` to a commit subject from the branch name. It
runs **before** git opens the editor, so on a plain `git commit` the file it receives holds
only git's comment block and a blank first line — there is no subject to append to. The hook
therefore appends nothing on the editor path, by design (#666). The result was a gap: `git
commit -m` got a reference, `git commit` through the editor did not, and which one a
contributor got depended only on how they happened to commit (#679).

The subject the editor path is owed exists only **after** the editor closes — which is
exactly when `.githooks/commit-msg` runs. `commit-msg` already exists and is already wired
through `core.hooksPath`, so the reference belongs there. The catch is that `commit-msg` is
handed only the message file; git does **not** pass it `$COMMIT_SOURCE`, the signal
`prepare-commit-msg` uses to tell `-m` from a merge from a fixup from the editor.

## Decision

**Both hooks append through one shared library, `.githooks/lib/issue-reference.sh`.** The
branch-name contract — accepted shapes, bare-digits output, the already-referenced guard —
lives there once, so the two callers cannot drift. `prepare-commit-msg` keeps the `-m`/`-F`
path (guarded on `$COMMIT_SOURCE = message`); `commit-msg` takes the editor path.

**`commit-msg` reconstructs the absent `$COMMIT_SOURCE` from intrinsic signals** — the part
no future reader would guess from the code alone:

- **merge** — `MERGE_HEAD` exists → skip. A non-conventional `Merge branch …` subject is
  already rejected by the format validation that runs first, exactly as it is today; the
  guard exists for a *conventional* merge subject (`chore: merge x`), which passes
  validation and would otherwise gain a reference.
- **squash** — `SQUASH_MSG` exists (`git merge --squash`, rebase squash) → skip.
- **autosquash** — the subject begins `fixup!`/`squash!`/`amend!` → skip, so
  `git rebase --autosquash` still matches it byte-for-byte (#675). Checked in the lib, so
  both hooks share it.
- **rebase reword/edit** — **HEAD is detached**, so `git symbolic-ref` fails, the branch
  name is empty, and no number is produced. This is an *accident of git's rebase
  implementation*, not a guard anyone wrote, and it is the whole reason a reword or an
  autosquash-combine does not acquire a spurious reference. It is pinned by a test
  precisely because a future git that stopped detaching HEAD there would silently break it.
- **already referenced / already trailing a `(#N)`** — checked in the lib. The
  already-referenced guard only looks for *this* branch's number, so a commit authored on
  one numbered branch and amended on another (`feat: work (#605)` amended on `fix/999-b`)
  needs a second, **trailing-reference** guard to keep it from stacking `(#999)` on top.

Validation runs **before** the reference logic and needs no library, so a missing or
unreadable lib degrades the *feature* to a silent no-op without ever disabling the
format check that every push depends on. It reads the **subject** — the first non-blank
line, the same line the reference logic uses — not the whole file, so a conventional-shaped
body line cannot pass a non-conventional subject; and it accepts `amend!` alongside
`fixup!`/`squash!` so those git-authored autosquash subjects clear it and reach the (no-op)
append. The lib is located by a candidate list — `$0`'s directory, then
`git rev-parse --git-path hooks`, then `--show-toplevel`/.githooks — because a
`.git/hooks/* → ../../.githooks/*` symlink layout puts `$0` where `lib/` is not. The
missing-lib guard sits *before* the `.` source, because `.` is a POSIX special builtin whose
failure aborts the script under `sh`/`dash` and would otherwise reject the commit.

## Consequences

Plain `git commit --amend` of a genuinely *unreferenced* subject on a conventional branch
now gains that branch's `(#N)`. That is a change in the safe direction — it adds the correct
reference and, thanks to the trailing-reference guard, never doubles or corrupts one — and
it is consistent with the user story. Making plain `--amend` byte-for-byte unchanged would
require relaying `$COMMIT_SOURCE` from `prepare-commit-msg` through `.git/` state into
`commit-msg`; that was rejected as adding a cross-hook invariant the codebase's hook
comments consistently avoid, and the trade is recorded here so it is not re-litigated.

A stale `SQUASH_MSG` from an abandoned `merge --squash` can suppress one append until git
removes it on the next commit — again the safe direction (a missing reference, never a
corrupted subject). The detached-HEAD reliance is the one fragile assumption, which is why
it carries a dedicated regression test rather than living only in this document.
