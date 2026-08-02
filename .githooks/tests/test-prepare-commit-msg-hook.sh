#!/usr/bin/env bash
# Tests for .githooks/prepare-commit-msg — the issue reference it appends to a
# commit subject from the current branch name (#666).
#
# Every case builds a throwaway git repository in a temp directory, checks out
# a branch under test, and runs a REAL `git commit`. Nothing here invokes the
# hook by hand: going through git is what makes $COMMIT_SOURCE real, and the
# assertion is always on the message git actually recorded (`git log -1`),
# never on the hook's stdout. A hook that exits 0 having done nothing and one
# that exits 0 having done the right thing are indistinguishable by status.
#
# `core.hooksPath` points at an isolated directory holding ONLY a copy of
# prepare-commit-msg. Pointing it at the real .githooks would drag in
# pre-commit (the whole Flutter + backend gauntlet) and commit-msg, so each
# case would be testing four hooks at once.
#
# The hook has no external dependencies, so nothing is stubbed anywhere.
#
# The two defects being pinned, from #666:
#
#   1. The extraction was `grep -oE '([a-zA-Z]+-[0-9]+|[0-9]+)' | head -n 1`,
#      unanchored, so the LEFTMOST digit-ish run anywhere in the name won:
#      `review-655` -> `(#review-655)`, `coderabbit-review-proxy-3048c7` ->
#      `(#proxy-3048)`, `worktree-agent-<hex>` -> `(#0)`. Agents work in
#      generated worktree branches, so the wrong-id case is routine, and a
#      wrong `(#NNN)` links a commit to an unrelated issue permanently.
#   2. The already-referenced guard was `grep -q "$ISSUE_ID"` — a raw
#      substring search over the whole file. With a degenerate id like `0` it
#      matched almost any message; with a real one it matched unrelated
#      numbers in prose, and the append was skipped silently.
#
# Each case is run under every shell present, by rewriting the copied hook's
# shebang. `sh` is the production path — git executes the hook through its
# `#!/bin/sh`. `dash` is NOT redundant with it: on Linux (so in CI) /bin/sh IS
# dash, but on macOS it is bash in POSIX mode, and the two disagree about
# parameter-expansion and `case` edge cases. Without an explicit dash row a
# developer's local run cannot see a dash-only failure at all — the same gap
# docs/TESTING.md records the pre-commit suite as having closed deliberately.
# `bash` and `zsh` are cross-shell coverage for anyone who rewrites the
# shebang or sources the logic elsewhere.
#
# Usage: ./test-prepare-commit-msg-hook.sh
set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
HOOK="${TESTS_DIR}/../prepare-commit-msg"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

FAILURES=0

start_case() { printf '\n%s\n' "$1"; }
ok()   { printf '  ok   — %s\n' "$1"; }
bad()  { printf '  FAIL — %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
skip() { printf '  SKIP — %s\n' "$1"; }

report() {
  echo
  if [ "${FAILURES}" -eq 0 ]; then
    echo "All checks passed."
    exit 0
  fi
  echo "${FAILURES} check(s) failed."
  exit 1
}

# ----- Per-shell hook installs ----------------------------------------------
# A copy of the real hook with its shebang rewritten to the interpreter under
# test. Everything below line 1 is the production file, byte for byte.

hooks_dir_for() { printf '%s/hooks-%s' "${WORK}" "$1"; }

install_hook_for_shell() {
  local shell_name="$1" interpreter dir
  interpreter=$(command -v "${shell_name}")
  dir=$(hooks_dir_for "${shell_name}")
  mkdir -p "${dir}"
  {
    printf '#!%s\n' "${interpreter}"
    tail -n +2 "${HOOK}"
  } > "${dir}/prepare-commit-msg"
  chmod +x "${dir}/prepare-commit-msg"
}

HOOK_SHELLS=""
for candidate_shell in sh dash bash zsh; do
  if command -v "${candidate_shell}" >/dev/null 2>&1; then
    HOOK_SHELLS="${HOOK_SHELLS} ${candidate_shell}"
    install_hook_for_shell "${candidate_shell}"
  else
    skip "${candidate_shell} not on PATH — that interpreter's parameter-expansion behaviour goes unexercised"
  fi
done

# This suite's whole body is inside `for hook_shell in ${HOOK_SHELLS}`. An empty
# list would run zero assertions and still print "All checks passed." — the one
# way this file can lie. `sh` is guaranteed here (it is this script's own
# interpreter's neighbour, and bash — the shebang — is itself a candidate), so
# the branch is not reachable today; it is a tripwire for whoever edits the
# candidate list.
if [ -z "${HOOK_SHELLS# }" ]; then
  bad "no shell interpreter found — the suite would otherwise report success having asserted nothing"
  report
fi

# ----- Repo fixtures --------------------------------------------------------

CASE_REPO=""
CASE_SEQ=0

new_case_repo() {
  # $1 = branch name to sit on, $2 = shell the hook runs under
  CASE_SEQ=$((CASE_SEQ + 1))
  CASE_REPO="${WORK}/case-${CASE_SEQ}"
  mkdir -p "${CASE_REPO}"
  git -C "${CASE_REPO}" init -q -b "$1"
  git -C "${CASE_REPO}" config user.email 'jeeves@example.invalid'
  git -C "${CASE_REPO}" config user.name 'Jeeves Dev'
  git -C "${CASE_REPO}" config commit.gpgsign false
  git -C "${CASE_REPO}" config core.hooksPath "$(hooks_dir_for "$2")"
}

COMMIT_RC=0
COMMIT_OUT=""
SUBJECT=""
FULL_MSG=""

commit_with() {
  # Remaining args are passed straight to `git commit`. --allow-empty keeps the
  # fixtures to one concern: what is staged is irrelevant to this hook.
  COMMIT_OUT=$(git -C "${CASE_REPO}" commit -q --allow-empty "$@" 2>&1)
  COMMIT_RC=$?
  SUBJECT=$(git -C "${CASE_REPO}" log -1 --pretty=%s 2>/dev/null)
  FULL_MSG=$(git -C "${CASE_REPO}" log -1 --pretty=%B 2>/dev/null)
}

# AC #2 is "appends nothing, silently AND successfully", so the exit status is
# asserted on every single case, not just the negative ones.
assert_commit_succeeded() {
  if [ "${COMMIT_RC}" -eq 0 ]; then
    ok "$1: git commit succeeded"
  else
    bad "$1: git commit exited ${COMMIT_RC}: ${COMMIT_OUT}"
  fi
}

assert_subject() {
  # $1 = label, $2 = the exact subject line expected
  assert_commit_succeeded "$1"
  if [ "${SUBJECT}" = "$2" ]; then
    ok "$1: subject is \"${SUBJECT}\""
  else
    bad "$1: subject is \"${SUBJECT}\", expected \"$2\""
  fi
}

assert_nothing_committed() {
  # $1 = label. Quitting the editor without saving must leave the repo exactly
  # as it was — a non-zero status alone is not enough, because a hook that
  # writes a junk message makes git succeed.
  if [ "${COMMIT_RC}" -ne 0 ]; then
    ok "$1: git commit aborted (status ${COMMIT_RC})"
  else
    bad "$1: git commit succeeded, expected an abort — recorded \"${SUBJECT}\""
  fi
  local commit_count
  commit_count=$(git -C "${CASE_REPO}" rev-list --all --count 2>/dev/null || printf '0')
  if [ "${commit_count}" = "0" ]; then
    ok "$1: nothing was committed"
  else
    bad "$1: ${commit_count} commit(s) recorded, expected none — subject \"${SUBJECT}\""
  fi
}

# ----- Editor-path fixtures -------------------------------------------------
# A plain `git commit` reaches this hook with $COMMIT_SOURCE EMPTY, and the
# message file at that moment holds nothing but git's `#` comment block. That
# is the path every developer and agent takes when they do not pass -m, and a
# scripted GIT_EDITOR is the only way to drive it from a test.

EDITOR_QUIT="${WORK}/editor-quit"
printf '#!/bin/sh\nexit 0\n' > "${EDITOR_QUIT}"
chmod +x "${EDITOR_QUIT}"

# Types ${EDITOR_SUBJECT} above git's comment block and saves — what a
# developer who actually writes a subject leaves behind.
EDITOR_WRITE="${WORK}/editor-write"
cat > "${EDITOR_WRITE}" <<'EDITOR_SCRIPT'
#!/bin/sh
{ printf '%s\n' "${EDITOR_SUBJECT}"; cat "$1"; } > "$1.typed"
mv "$1.typed" "$1"
EDITOR_SCRIPT
chmod +x "${EDITOR_WRITE}"

commit_with_editor() {
  # $1 = editor script, $2 = the subject it types (ignored by editor-quit).
  # Remaining args go to `git commit`. With none, there is no -m, so git opens
  # the editor and $COMMIT_SOURCE is empty.
  local editor="$1" typed="$2"
  shift 2
  COMMIT_OUT=$(EDITOR_SUBJECT="${typed}" GIT_EDITOR="${editor}" \
    git -C "${CASE_REPO}" commit -q --allow-empty "$@" 2>&1)
  COMMIT_RC=$?
  SUBJECT=$(git -C "${CASE_REPO}" log -1 --pretty=%s 2>/dev/null)
  FULL_MSG=$(git -C "${CASE_REPO}" log -1 --pretty=%B 2>/dev/null)
}

# ----- Cases ----------------------------------------------------------------
# Two seed messages, deliberately free of digits, so the only thing that can
# put a number in the subject is the hook.
SEED_SUBJECT='feat: add the thing'

for hook_shell in ${HOOK_SHELLS}; do

  # --- Extraction: the shapes that must yield a reference ---

  start_case "extraction (${hook_shell}): conventional branch shapes append the right number"

  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, fix/605-converge-duplicate-tags" "${SEED_SUBJECT} (#605)"

  new_case_repo 'reviews/586' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, reviews/586" "${SEED_SUBJECT} (#586)"

  # The most dangerous of the wrong shapes, because `(#issue-458)` looks
  # plausible enough to survive a glance in a way `(#proxy-3048)` does not.
  new_case_repo 'issue-458/global-capture-fab' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, issue-458/global-capture-fab" "${SEED_SUBJECT} (#458)"

  new_case_repo '605-add-login' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, 605-add-login" "${SEED_SUBJECT} (#605)"

  # The prefix must never survive into the message: (#123), not (#JVS-123).
  new_case_repo 'JVS-123' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, JVS-123" "${SEED_SUBJECT} (#123)"

  # --- Extraction: the shapes that must yield nothing ---

  start_case "extraction (${hook_shell}): ad-hoc and generated branch names append nothing"

  # Observed in practice on PR #655: produced (#review-655), caught by hand.
  new_case_repo 'review-655' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, review-655" "${SEED_SUBJECT}"

  new_case_repo 'coderabbit-review-proxy-3048c7' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, coderabbit-review-proxy-3048c7" "${SEED_SUBJECT}"

  # 87 of these existed in the checkout when #666 was written. The first digit
  # run in the hex suffix used to win, giving (#0).
  new_case_repo 'worktree-agent-a0c916b19a98a11ae' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, worktree-agent-<hex>" "${SEED_SUBJECT}"

  new_case_repo 'drive-epic-666-644-b99fc4' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, drive-epic-666-644-b99fc4" "${SEED_SUBJECT}"

  # 0028 is a migration number, not issue #28 — but what stops this one is the
  # ANCHOR: the last segment starts with `alembic-`, not a digit. The leading
  # zero never gets a say.
  new_case_repo 'fix/alembic-0028-ambiguous-parameter' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, fix/alembic-0028-..." "${SEED_SUBJECT}"

  # Same, for an ADR number — and again it is the anchor doing the work.
  new_case_repo 'docs/renumber-duplicate-adr-0044' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, docs/renumber-duplicate-adr-0044" "${SEED_SUBJECT}"

  # THIS is the case the leading-zero rule exists for: the digits sit right on
  # the anchor, so the anchor passes them and only the zero check rejects them.
  new_case_repo 'fix/0028-ambiguous-parameter' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, fix/0028-ambiguous-parameter" "${SEED_SUBJECT}"

  new_case_repo 'fix/agp9-kotlin-android-plugin' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, fix/agp9-kotlin-android-plugin" "${SEED_SUBJECT}"

  new_case_repo 'dependabot/gradle/app/android/com.android.application-9.2.0' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, dependabot/.../com.android.application-9.2.0" "${SEED_SUBJECT}"

  # The trailing-number shape is deliberately unsupported — that is where
  # versions, ADR numbers and dependabot bumps collide.
  new_case_repo 'feat/login-registration-ui-94' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, feat/login-registration-ui-94" "${SEED_SUBJECT}"

  # Digits must be followed by a separator, never by more branch name.
  new_case_repo 'fix/605_underscore' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, fix/605_underscore" "${SEED_SUBJECT}"

  new_case_repo 'deps/pin-postgres-exact-versions' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, deps/pin-postgres-exact-versions" "${SEED_SUBJECT}"

  new_case_repo 'main' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, main" "${SEED_SUBJECT}"

  # --- The already-referenced guard ---

  start_case "guard (${hook_shell}): the reference token is matched, not an arbitrary substring"

  new_case_repo 'fix/605-x' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT} (#605)"
  assert_subject "${hook_shell}, already referenced" "${SEED_SUBJECT} (#605)"

  # The substring guard used to see `605` inside `1605` and skip the append,
  # leaving the commit with no reference at all.
  new_case_repo 'fix/605-x' "${hook_shell}"
  commit_with -m 'fix: handle 1605 rows'
  assert_subject "${hook_shell}, unrelated number in subject" 'fix: handle 1605 rows (#605)'

  # #6051 is a different issue. The append SHOULD happen.
  new_case_repo 'fix/605-x' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}" -m 'Refs #6051'
  assert_subject "${hook_shell}, body references #6051" "${SEED_SUBJECT} (#605)"

  # A genuine reference anywhere in the message suppresses the append.
  new_case_repo 'fix/605-x' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}" -m 'Closes #605'
  assert_subject "${hook_shell}, body closes #605" "${SEED_SUBJECT}"
  case "${FULL_MSG}" in
    *"Closes #605"*) ok "${hook_shell}, body closes #605: body preserved" ;;
    *) bad "${hook_shell}, body closes #605: body lost — ${FULL_MSG}" ;;
  esac

  # The old hook extracted ISSUE_ID=0 here, which its substring guard then
  # found inside `v1.0.3` — so it exited early for entirely the wrong reason.
  # Assert the message, not just the status: they are indistinguishable
  # otherwise, and only one of them is the behaviour under test.
  start_case "guard (${hook_shell}): a generated branch appends nothing and exits 0, on its own merits"
  new_case_repo 'worktree-agent-a0c916b19a98a11ae' "${hook_shell}"
  commit_with -m 'chore: bump to v1.0.3'
  assert_subject "${hook_shell}, worktree-agent + version-like message" 'chore: bump to v1.0.3'

  # --- The COMMIT_SOURCE guard: the editor path ($COMMIT_SOURCE empty) ---

  start_case "editor (${hook_shell}): quitting without saving still aborts the commit"
  # Quit-to-cancel is the standard gesture for calling off a commit, and it
  # works because git sees an empty message. A hook that appends to line 1 of a
  # file holding only git's comment block destroys that: the file is no longer
  # empty, so git happily records a commit whose subject is " (#605)".
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  commit_with_editor "${EDITOR_QUIT}" ''
  assert_nothing_committed "${hook_shell}, editor quit without saving"

  start_case "editor (${hook_shell}): a typed subject is recorded exactly as typed"
  # This hook runs BEFORE the editor opens, so on the editor path there is no
  # subject for it to append to — only git's comment block and an empty line 1.
  # It therefore appends nothing here, which is also what the pre-#666 hook did
  # (by accident: its substring guard found the branch number inside git's own
  # `# On branch fix/605-...` line). What must never happen is the middle
  # ground: a ` (#605)` fragment left on its own line above the comment block,
  # which git folds into the subject as `feat: add the thing  (#605)`.
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  commit_with_editor "${EDITOR_WRITE}" "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, editor typed a subject" "${SEED_SUBJECT}"

  start_case "editor (${hook_shell}): a typed subject already carrying the reference is not doubled"
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  commit_with_editor "${EDITOR_WRITE}" "${SEED_SUBJECT} (#605)"
  assert_subject "${hook_shell}, editor typed an existing reference" "${SEED_SUBJECT} (#605)"

  start_case "editor (${hook_shell}): commit.verbose does not defeat the abort"
  # Under commit.verbose git appends the staged diff below the scissors line,
  # UN-commented. A guard that only strips `#` lines sees that diff as message
  # text and appends anyway — the same junk commit, one config away.
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  git -C "${CASE_REPO}" config commit.verbose true
  printf 'hello\n' > "${CASE_REPO}/f.txt"
  git -C "${CASE_REPO}" add f.txt
  commit_with_editor "${EDITOR_QUIT}" ''
  assert_nothing_committed "${hook_shell}, commit.verbose + editor quit"

  start_case "guard (${hook_shell}): a #605 inside the verbose diff is not a reference"
  # `-m ... -e` is the one path with both a real subject and a verbose diff.
  # The diff mentions #605; the message does not. The append must still happen.
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  git -C "${CASE_REPO}" config commit.verbose true
  printf 'see #605 for context\n' > "${CASE_REPO}/notes.txt"
  git -C "${CASE_REPO}" add notes.txt
  commit_with_editor "${EDITOR_QUIT}" '' -m "${SEED_SUBJECT}" -e
  assert_subject "${hook_shell}, #605 in the verbose diff only" "${SEED_SUBJECT} (#605)"

  # --- The COMMIT_SOURCE guard ---

  start_case "COMMIT_SOURCE (${hook_shell}): a merge commit is left alone"
  new_case_repo 'fix/605-x' "${hook_shell}"
  commit_with -m 'chore: seed'
  git -C "${CASE_REPO}" checkout -q -b side
  printf 'side\n' > "${CASE_REPO}/side.txt"
  git -C "${CASE_REPO}" add side.txt
  git -C "${CASE_REPO}" commit -q -m 'chore: side'
  git -C "${CASE_REPO}" checkout -q 'fix/605-x'
  printf 'trunk\n' > "${CASE_REPO}/trunk.txt"
  git -C "${CASE_REPO}" add trunk.txt
  git -C "${CASE_REPO}" commit -q -m 'chore: trunk'
  MERGE_OUT=$(git -C "${CASE_REPO}" merge --no-ff --no-edit -m 'Merge branch side' side 2>&1)
  MERGE_RC=$?
  MERGE_SUBJECT=$(git -C "${CASE_REPO}" log -1 --pretty=%s)
  if [ "${MERGE_RC}" -eq 0 ]; then
    ok "${hook_shell}, merge: git merge succeeded"
  else
    bad "${hook_shell}, merge: git merge exited ${MERGE_RC}: ${MERGE_OUT}"
  fi
  if [ "${MERGE_SUBJECT}" = 'Merge branch side' ]; then
    ok "${hook_shell}, merge: subject untouched (\"${MERGE_SUBJECT}\")"
  else
    bad "${hook_shell}, merge: subject is \"${MERGE_SUBJECT}\", expected \"Merge branch side\""
  fi

done

report
