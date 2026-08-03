#!/usr/bin/env bash
# Tests for .githooks/prepare-commit-msg — the issue reference it appends to a
# commit subject from the current branch name (#666), and the autosquash
# subjects it must leave verbatim (#675).
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
# The defect pinned from #675:
#
#   `git commit --fixup <sha>`, `--squash <sha>`, `--fixup=amend:<sha>` and
#   `--fixup=reword:<sha>` all reach the hook with $COMMIT_SOURCE=message — the
#   same value a plain `-m` produces — so the COMMIT_SOURCE guard lets them
#   through. git built those subjects itself as `fixup! <target>` /
#   `squash! <target>` / `amend! <target>` (both amend: and reword: emit
#   `amend!`), and `git rebase --autosquash` matches them against the target's
#   subject BYTE-FOR-BYTE. Appending ` (#NNN)` breaks that match, so the fixup
#   never squashes and survives the rebase as a standalone commit. The
#   autosquash cases below drive a REAL `git commit --fixup`/`--squash` and a
#   REAL `git rebase --autosquash`, per AGENTS.md (no mocks for system parts).
#
#   Non-vacuity is load-bearing here: each autosquash case builds the target
#   commit ON `main`, reference-free, then checks out the numbered branch before
#   creating the fixup. Were the target built on the numbered branch it would
#   already carry `(#605)`, and the already-referenced guard would suppress the
#   append even on the UNPATCHED hook — so the case would pass against the bug
#   and prove nothing. Do NOT "simplify" the target back onto the numbered
#   branch; that silently re-vacuums every case. (This is the exact invisibility
#   the issue names: the defect hides whenever the target already carries the
#   reference.)
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

# ----- Capability probe: core.commentString (git 2.45+) ---------------------
# `git config core.commentString '//'` is NOT a capability test — git stores
# unknown configuration keys and exits 0 for any of them, so a gate keyed on its
# status never skips, on any git. Probe the BEHAVIOUR instead: feed stripspace a
# line that is a comment only if the key is understood. A git that knows the key
# strips it and prints nothing; one that does not keeps it. The probe body must
# be the comment ALONE — with any other text alongside it the output is non-empty
# either way, and the probe silently answers "supported" on every git.
if [ -z "$(printf '// probe\n' | git -c core.commentString='//' stripspace --strip-comments)" ]; then
  COMMENT_STRING_SUPPORTED=yes
else
  COMMENT_STRING_SUPPORTED=no
fi

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

# ----- Autosquash fixtures (#675) -------------------------------------------
# `git commit --fixup`/`--squash` build a subject git's own autosquash matches
# against its target BYTE-FOR-BYTE, so a real `git rebase --autosquash` is the
# only honest proof the fixup collapses. `--autosquash` is honoured only with
# `-i`; the two env editors below accept the auto-arranged todo list and any
# combined squash message with no human present.

TARGET_SUBJECT=""
TARGET_SHA=""

seed_autosquash_target() {
  # $1 = shell the hook runs under. Builds the rebase root and a REFERENCE-FREE
  # target ON `main`, records its subject/SHA, then moves onto the numbered
  # branch. Reference-free is the whole point (see the header note): a target
  # built on the numbered branch already carries `(#605)`, and the
  # already-referenced guard then suppresses the append even on the unpatched
  # hook, so the case would pass against the bug.
  new_case_repo 'main' "$1"
  commit_with -m 'chore: base'          # the root the autosquash rebase stops at
  commit_with -m 'fix: seed subject'    # the target — no reference on `main`
  TARGET_SUBJECT="${SUBJECT}"
  TARGET_SHA=$(git -C "${CASE_REPO}" rev-parse HEAD)
  git -C "${CASE_REPO}" checkout -q -b 'fix/605-converge-duplicate-tags'
}

REBASE_RC=0

assert_autosquash_collapses() {
  # $1 = label, $2 = the subject prefix that must NOT survive ("fixup!"/"squash!").
  # Runs a non-interactive `git rebase -i --autosquash` from the root commit and
  # asserts the history shrank by exactly one and no such subject is left.
  local label="$1" survivor_prefix="$2" root_sha count_before count_after
  root_sha=$(git -C "${CASE_REPO}" rev-list --max-parents=0 HEAD)
  count_before=$(git -C "${CASE_REPO}" rev-list --count HEAD)
  GIT_SEQUENCE_EDITOR=true GIT_EDITOR=true \
    git -C "${CASE_REPO}" rebase -i --autosquash "${root_sha}" >/dev/null 2>&1
  REBASE_RC=$?
  if [ "${REBASE_RC}" -ne 0 ]; then
    # A wedged rebase must not leak state into a later case. Each case gets a
    # fresh repo anyway, but this keeps a mid-rebase failure self-contained.
    git -C "${CASE_REPO}" rebase --abort >/dev/null 2>&1
    bad "${label}: git rebase --autosquash exited ${REBASE_RC}"
    return
  fi
  ok "${label}: git rebase --autosquash succeeded"
  count_after=$(git -C "${CASE_REPO}" rev-list --count HEAD)
  if [ "${count_after}" -eq $((count_before - 1)) ]; then
    ok "${label}: history shrank by one (${count_before} -> ${count_after})"
  else
    bad "${label}: history is ${count_after} commit(s), expected $((count_before - 1)) — the fixup did not squash"
  fi
  if git -C "${CASE_REPO}" log --pretty=%s | grep -q "^${survivor_prefix} "; then
    bad "${label}: a '${survivor_prefix}' subject survived the rebase"
  else
    ok "${label}: no '${survivor_prefix}' subject survived"
  fi
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

  start_case "editor (${hook_shell}): core.commentChar does not defeat the abort"
  # git's comment block and scissors line start with core.commentChar, not
  # necessarily `#`. An "is the message empty yet?" heuristic built on `^#`
  # therefore reads git's own template as a subject the moment this is set,
  # appends to it, and the quit-to-cancel abort fails open with a ` (#605)`
  # commit. The $COMMIT_SOURCE guard is what makes the abort independent of it.
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  git -C "${CASE_REPO}" config core.commentChar ';'
  commit_with_editor "${EDITOR_QUIT}" ''
  assert_nothing_committed "${hook_shell}, core.commentChar=';' + editor quit"

  start_case "editor (${hook_shell}): core.commentString does not defeat the abort"
  # Same hole, through the multi-character spelling (git 2.45+). Skipped where
  # git is too old to know the key, rather than silently asserting nothing.
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  if [ "${COMMENT_STRING_SUPPORTED}" = yes ]; then
    git -C "${CASE_REPO}" config core.commentString '//'
    commit_with_editor "${EDITOR_QUIT}" ''
    assert_nothing_committed "${hook_shell}, core.commentString='//' + editor quit"
  else
    skip "${hook_shell}, core.commentString: unsupported by $(git --version)"
  fi

  start_case "editor (${hook_shell}): core.commentChar + commit.verbose does not defeat the abort"
  # Both knobs at once: the scissors line no longer starts with `#` either, so
  # the un-commented staged diff below it is in play as well.
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  git -C "${CASE_REPO}" config core.commentChar ';'
  git -C "${CASE_REPO}" config commit.verbose true
  printf 'hello\n' > "${CASE_REPO}/f.txt"
  git -C "${CASE_REPO}" add f.txt
  commit_with_editor "${EDITOR_QUIT}" ''
  assert_nothing_committed "${hook_shell}, core.commentChar + commit.verbose + editor quit"

  start_case "editor (${hook_shell}): core.commentString + commit.verbose does not defeat the abort"
  # The sixth cell of the abort matrix — {default, commentChar, commentString}
  # x {verbose on, off}. All six must record zero commits.
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  if [ "${COMMENT_STRING_SUPPORTED}" = yes ]; then
    git -C "${CASE_REPO}" config core.commentString '//'
    git -C "${CASE_REPO}" config commit.verbose true
    printf 'hello\n' > "${CASE_REPO}/f.txt"
    git -C "${CASE_REPO}" add f.txt
    commit_with_editor "${EDITOR_QUIT}" ''
    assert_nothing_committed "${hook_shell}, core.commentString + commit.verbose + editor quit"
  else
    skip "${hook_shell}, core.commentString + verbose: unsupported by $(git --version)"
  fi

  start_case "extraction (${hook_shell}): core.commentChar leaves the -m path working"
  # The guard must close the editor hole without costing the -m path its
  # reference under the same config.
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  git -C "${CASE_REPO}" config core.commentChar ';'
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, core.commentChar=';' + -m" "${SEED_SUBJECT} (#605)"

  start_case "guard (${hook_shell}): a #605 inside the verbose diff is not a reference"
  # `-m ... -e` is the one path with both a real subject and a verbose diff.
  # The diff mentions #605; the message does not. The append must still happen.
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  git -C "${CASE_REPO}" config commit.verbose true
  printf 'see #605 for context\n' > "${CASE_REPO}/notes.txt"
  git -C "${CASE_REPO}" add notes.txt
  commit_with_editor "${EDITOR_QUIT}" '' -m "${SEED_SUBJECT}" -e
  assert_subject "${hook_shell}, #605 in the verbose diff only" "${SEED_SUBJECT} (#605)"

  start_case "guard (${hook_shell}): the verbose-diff trim survives core.commentChar"
  # The scissors line git writes above the verbose diff carries the comment
  # character, so a trim anchored on `#` misses it entirely once that character
  # changes — and the whole diff, `#605` and all, is scanned as if it were the
  # message. Same case as above, one config away.
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  git -C "${CASE_REPO}" config commit.verbose true
  git -C "${CASE_REPO}" config core.commentChar ';'
  printf 'see #605 for context\n' > "${CASE_REPO}/notes.txt"
  git -C "${CASE_REPO}" add notes.txt
  commit_with_editor "${EDITOR_QUIT}" '' -m "${SEED_SUBJECT}" -e
  assert_subject "${hook_shell}, verbose diff + core.commentChar=';'" "${SEED_SUBJECT} (#605)"

  start_case "guard (${hook_shell}): the verbose-diff trim survives core.commentString"
  # `core.commentString` makes the prefix a whole string rather than one
  # character, which is why the trim matches the `>8` run and not the prefix.
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  git -C "${CASE_REPO}" config commit.verbose true
  if [ "${COMMENT_STRING_SUPPORTED}" = yes ]; then
    git -C "${CASE_REPO}" config core.commentString '//'
    printf 'see #605 for context\n' > "${CASE_REPO}/notes.txt"
    git -C "${CASE_REPO}" add notes.txt
    commit_with_editor "${EDITOR_QUIT}" '' -m "${SEED_SUBJECT}" -e
    assert_subject "${hook_shell}, verbose diff + core.commentString='//'" "${SEED_SUBJECT} (#605)"
  else
    skip "${hook_shell}, core.commentString: unsupported by $(git --version)"
  fi

  # --- The comment character the already-referenced guard reads through ---

  start_case "guard (${hook_shell}): git's own status block is skipped under core.commentChar"
  # The reachable form of the hard-coded-`^#` defect, and it needs no unusual
  # message — only an unusual config. Under `core.commentChar=';'` git writes
  # its status block with `;`, so the line `; On branch fix/605-#605` sails
  # straight through a `^#` filter; the guard then reads the `#605` in git's
  # OWN text as an existing reference and silently suppresses a legitimate
  # append. `message_body` goes through `git stripspace --strip-comments`,
  # which reads `core.commentChar` itself, so the block is dropped as git
  # drops it.
  new_case_repo 'fix/605-#605' "${hook_shell}"
  git -C "${CASE_REPO}" config core.commentChar ';'
  commit_with_editor "${EDITOR_QUIT}" '' -m "${SEED_SUBJECT}" -e
  assert_subject "${hook_shell}, status block under core.commentChar=';'" "${SEED_SUBJECT} (#605)"

  # The same branch under the DEFAULT comment character, so the case above is
  # pinned to the config and not to the branch name.
  new_case_repo 'fix/605-#605' "${hook_shell}"
  commit_with_editor "${EDITOR_QUIT}" '' -m "${SEED_SUBJECT}" -e
  assert_subject "${hook_shell}, status block under the default comment char" "${SEED_SUBJECT} (#605)"

  start_case "guard (${hook_shell}): a #605 body line is message text under core.commentChar"
  # The mirror image. With the comment character set to `;`, a `#605` line the
  # user wrote is NOT a comment — git keeps it, so it is a genuine reference
  # and the append must be suppressed. A hard-coded `^#` filter dropped it and
  # appended a second reference.
  new_case_repo 'fix/605-x' "${hook_shell}"
  git -C "${CASE_REPO}" config core.commentChar ';'
  commit_with -m "${SEED_SUBJECT}" -m '#605'
  assert_subject "${hook_shell}, '#605' body line under core.commentChar=';'" "${SEED_SUBJECT}"

  start_case "guard (${hook_shell}): the accepted duplicate residual is comment-char-uniform"
  # Under the default character a `#605` body line IS a comment to this hook,
  # so the append happens and the message carries the reference twice. That is
  # the residual the hook's comment records: its cause is git's cleanup MODE
  # (plain `-m` cleans up with `whitespace`, which KEEPS comment lines), not
  # the comment character. Pinned so it stays uniform — the same shape under
  # `core.commentChar=';'` behaves the same way, where it used to differ.
  new_case_repo 'fix/605-x' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}" -m '#605'
  assert_subject "${hook_shell}, '#605' body line under the default comment char" "${SEED_SUBJECT} (#605)"

  new_case_repo 'fix/605-x' "${hook_shell}"
  git -C "${CASE_REPO}" config core.commentChar ';'
  commit_with -m "${SEED_SUBJECT}" -m '; note #605'
  assert_subject "${hook_shell}, ';' body line under core.commentChar=';'" "${SEED_SUBJECT} (#605)"

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

  # --- Autosquash: git-authored fixup!/squash!/amend! subjects (#675) ---

  start_case "autosquash (${hook_shell}): --fixup subject stays byte-identical and squashes"
  # AC #1, #3, #4, #5. --fixup reaches the hook with $COMMIT_SOURCE=message, so
  # the COMMIT_SOURCE guard lets it through; the subject must still be left as
  # git's `fixup! <target>` or autosquash cannot match it.
  seed_autosquash_target "${hook_shell}"
  # AC #5: an ordinary commit on the numbered branch still gets its reference.
  # This is its OWN commit, distinct from the fixup target — reusing the target
  # here would give it back `(#605)` and re-mask the defect.
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, ordinary commit alongside a fixup" "${SEED_SUBJECT} (#605)"
  # AC #1: byte-identical to `fixup! ` + the target's reference-free subject.
  commit_with --fixup="${TARGET_SHA}"
  assert_subject "${hook_shell}, --fixup byte-identical" "fixup! ${TARGET_SUBJECT}"
  # AC #3, #4: a real autosquash rebase collapses it into its target.
  assert_autosquash_collapses "${hook_shell}, --fixup autosquash" 'fixup!'

  start_case "autosquash (${hook_shell}): --squash subject stays byte-identical and squashes"
  # AC #2, #3. --squash arrives the same way, but unlike --fixup it OPENS THE
  # EDITOR by default to invite an extended message, so with no editor
  # configured (as in CI) a plain `git commit --squash` errors "Terminal is
  # dumb, but EDITOR unset". It therefore goes through commit_with_editor like
  # the amend:/reword: cases: the hook runs before the editor, the file already
  # holds `squash! <target>`, and quitting without saving keeps it. (The rebase
  # below opens its own combining editor, accepted by GIT_EDITOR=true inside
  # assert_autosquash_collapses.)
  seed_autosquash_target "${hook_shell}"
  commit_with_editor "${EDITOR_QUIT}" '' --squash="${TARGET_SHA}"
  assert_subject "${hook_shell}, --squash byte-identical" "squash! ${TARGET_SUBJECT}"
  assert_autosquash_collapses "${hook_shell}, --squash autosquash" 'squash!'

  start_case "autosquash (${hook_shell}): --fixup=amend: and --fixup=reword: keep amend! verbatim"
  # Both emit `amend!` and OPEN THE EDITOR (git errors with none configured), so
  # they must go through commit_with_editor, not plain commit_with. The hook
  # runs before the editor, the file already holds `amend! <target>`, and
  # quitting without saving keeps it. No rebase — subject identity is the AC.
  seed_autosquash_target "${hook_shell}"
  commit_with_editor "${EDITOR_QUIT}" '' --fixup=amend:"${TARGET_SHA}"
  assert_subject "${hook_shell}, --fixup=amend: byte-identical" "amend! ${TARGET_SUBJECT}"
  seed_autosquash_target "${hook_shell}"
  commit_with_editor "${EDITOR_QUIT}" '' --fixup=reword:"${TARGET_SHA}"
  assert_subject "${hook_shell}, --fixup=reword: byte-identical" "amend! ${TARGET_SUBJECT}"

  start_case "autosquash (${hook_shell}): a hand-typed fixup! subject is left verbatim"
  # A genuine user path that $COMMIT_SOURCE structurally cannot catch: a
  # hand-typed `fixup!` subject arrives as $COMMIT_SOURCE=message just like any
  # `-m`. Only the subject prefix distinguishes it, and the append must not fire.
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  commit_with -m 'fixup! chore: tidy imports'
  assert_subject "${hook_shell}, hand-typed fixup! via -m" 'fixup! chore: tidy imports'

done

report
