#!/usr/bin/env bash
# Tests for .githooks/prepare-commit-msg — the hook that appends an issue
# reference (e.g. "(#605)") drawn from the current branch name to the commit
# message.
#
# The behaviour worth protecting is that the appended reference is a REAL issue
# number or nothing at all. The old hook extracted the first '<letters>-<digits>'
# or bare digit run anywhere in the branch name, so generated branch names —
# which is what agents committing from `git worktree` branches always have —
# appended a wrong reference and linked the commit to an unrelated issue in the
# tracker permanently (#666):
#
#   review-655                        -> (#review-655)
#   coderabbit-review-proxy-3048c7    -> (#proxy-3048)
#   worktree-agent-a0c916b19a98a11ae  -> (#0)      (first digit run in the hex)
#
# A second defect compounded it: the "already referenced" guard was a bare
# substring test, so a degenerate id like '0' matched almost any message and
# silently skipped the append, and a real id could match an unrelated number in
# the body.
#
# Every case runs the REAL hook (AGENTS.md: no mocks for system components).
# The default driver is a real `git commit` in a throwaway repo checked out on
# the branch under test, with only prepare-commit-msg installed — the exact
# production path, argv and all, that produced the wrong "(#review-655)" in the
# first place. The COMMIT_SOURCE cases invoke the hook with git's own argv
# directly, because a merge/template source is awkward to synthesise through a
# plain `-m` commit.
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

report() {
  echo
  if [ "${FAILURES}" -eq 0 ]; then
    echo "All checks passed."
    exit 0
  fi
  echo "${FAILURES} check(s) failed."
  exit 1
}

# ----- Throwaway repo on a chosen branch ------------------------------------
# `git init -b "<branch>"` puts HEAD on an unborn "<branch>", which is all the
# hook reads (`git symbolic-ref --short HEAD`). Branch names with slashes are
# fine. Only prepare-commit-msg is installed, so no other hook interferes.

REPO=""
REPO_SEQ=0

new_repo_on_branch() {
  REPO_SEQ=$((REPO_SEQ + 1))
  REPO="${WORK}/repo-${REPO_SEQ}"
  git init -q -b "$1" "${REPO}"
  git -C "${REPO}" config user.email 'jeeves@example.invalid'
  git -C "${REPO}" config user.name 'Jeeves Dev'
  git -C "${REPO}" config commit.gpgsign false
  ln -sf "${HOOK}" "${REPO}/.git/hooks/prepare-commit-msg"
}

# Drive a real `git commit` (source = "message"). Each -m argument becomes one
# paragraph, exactly as on the command line. Sets SUBJECT / BODY_MSG / RC.
SUBJECT=""
BODY_MSG=""
RC=0
commit_with_messages() {
  local repo="$1"; shift
  local margs=() m
  for m in "$@"; do margs+=(-m "$m"); done
  printf 'seed\n' > "${repo}/file.txt"
  git -C "${repo}" add file.txt
  RC=0
  git -C "${repo}" commit -q "${margs[@]}" >/dev/null 2>&1 || RC=$?
  SUBJECT=$(git -C "${repo}" log -1 --format=%s 2>/dev/null)
  BODY_MSG=$(git -C "${repo}" log -1 --format=%B 2>/dev/null)
}

# Invoke the hook with git's own argv on a message file, for the COMMIT_SOURCE
# variants. Sets DIRECT_MSG / DIRECT_RC.
DIRECT_MSG=""
DIRECT_RC=0
run_hook_direct() {
  # $1 = repo (for branch context), $2 = message content, $3 = source arg
  local repo="$1" content="$2" source="$3"
  local msg_file="${repo}/COMMIT_MSG_UNDER_TEST"
  printf '%s\n' "${content}" > "${msg_file}"
  ( cd "${repo}" && sh "${HOOK}" "${msg_file}" "${source}" )
  DIRECT_RC=$?
  DIRECT_MSG=$(cat "${msg_file}")
}

assert_subject() {
  # $1 = label, $2 = expected subject
  if [ "${SUBJECT}" = "$2" ]; then
    ok "$1: subject is \"$2\""
  else
    bad "$1: expected subject \"$2\", got \"${SUBJECT}\""
  fi
}

assert_committed() {
  # A no-op append must still succeed silently — the commit lands, rc 0.
  if [ "${RC}" -eq 0 ]; then
    ok "$1: commit succeeded (rc 0)"
  else
    bad "$1: commit failed (rc ${RC}) — the hook did not exit silently and successfully"
  fi
}

# ----- Cases: shapes that SHOULD contribute a reference ---------------------

start_case "PR branch fix/<n>-<slug>: appends (#605) — the existing correct behaviour must still hold"
new_repo_on_branch "fix/605-converge-duplicate-tags"
commit_with_messages "${REPO}" "fix(tags): converge duplicates"
assert_committed "fix/605"
assert_subject "fix/605" "fix(tags): converge duplicates (#605)"

start_case "PR branch feat/<n>-<slug>: number right after the first slash"
new_repo_on_branch "feat/584-sync-health-visibility"
commit_with_messages "${REPO}" "feat(sync): health visibility"
assert_subject "feat/584" "feat(sync): health visibility (#584)"

start_case "generated worktree branch issue-<n>/<slug>: the shape agents actually commit on"
new_repo_on_branch "issue-666/prepare-commit-msg-appends-a-wrong-issue-reference"
commit_with_messages "${REPO}" "fix(githooks): anchor issue extraction"
assert_subject "issue-666" "fix(githooks): anchor issue extraction (#666)"

start_case "worktree branch issue-<n>-<slug> (no slash): still a leading issue token"
new_repo_on_branch "issue-304-plan"
commit_with_messages "${REPO}" "docs: plan"
assert_subject "issue-304" "docs: plan (#304)"

start_case "bare leading number <n>-<slug>: appends (#123)"
new_repo_on_branch "123-add-login"
commit_with_messages "${REPO}" "feat: add login"
assert_subject "123-slug" "feat: add login (#123)"

start_case "Jira-style key JVS-<n>: appends (#123)"
new_repo_on_branch "JVS-123"
commit_with_messages "${REPO}" "chore: tidy"
assert_subject "JVS-123" "chore: tidy (#123)"

# ----- Cases: the observed wrong-reference shapes MUST append nothing --------

start_case "review-655: was (#review-655) — must now append nothing"
new_repo_on_branch "review-655"
commit_with_messages "${REPO}" "fix: address review"
assert_committed "review-655"
assert_subject "review-655" "fix: address review"

start_case "coderabbit-review-proxy-3048c7: was (#proxy-3048) — must append nothing"
new_repo_on_branch "coderabbit-review-proxy-3048c7"
commit_with_messages "${REPO}" "fix: proxy tweak"
assert_committed "coderabbit-proxy"
assert_subject "coderabbit-proxy" "fix: proxy tweak"

start_case "worktree-agent-<hex>: was (#0) from the first digit run in the hex — must append nothing"
new_repo_on_branch "worktree-agent-a0c916b19a98a11ae"
commit_with_messages "${REPO}" "chore: worktree work"
assert_committed "worktree-agent"
assert_subject "worktree-agent" "chore: worktree work"

start_case "main: no issue number — appends nothing, silently and successfully"
new_repo_on_branch "main"
commit_with_messages "${REPO}" "chore: release prep"
assert_committed "main"
assert_subject "main" "chore: release prep"

# ----- The already-referenced guard: whole token, not substring -------------

start_case "already references (#605) in the subject: not appended twice"
new_repo_on_branch "fix/605-converge-duplicate-tags"
commit_with_messages "${REPO}" "fix(tags): converge duplicates (#605)"
assert_subject "no-dup" "fix(tags): converge duplicates (#605)"

start_case "already references #605 (bare, no parens) in the body: not appended"
new_repo_on_branch "fix/605-converge-duplicate-tags"
commit_with_messages "${REPO}" "fix(tags): converge duplicates" "Follow-up to #605."
if [ "${SUBJECT}" = "fix(tags): converge duplicates" ]; then
  ok "bare-#605-in-body: subject left unchanged"
else
  bad "bare-#605-in-body: subject was modified to \"${SUBJECT}\""
fi

start_case "id appears only inside a longer number (#6050) in the body: the guard must NOT suppress the real append"
new_repo_on_branch "fix/605-converge-duplicate-tags"
commit_with_messages "${REPO}" "fix(tags): converge duplicates" "Unrelated to #6050."
assert_subject "not-fooled-by-6050" "fix(tags): converge duplicates (#605)"
if printf '%s' "${BODY_MSG}" | grep -qF '#6050'; then
  ok "not-fooled-by-6050: the unrelated #6050 in the body is preserved"
else
  bad "not-fooled-by-6050: the body's #6050 was lost"
fi

# ----- Body preservation ----------------------------------------------------

start_case "multi-paragraph message: reference lands on the subject, the body is untouched"
new_repo_on_branch "fix/605-converge-duplicate-tags"
commit_with_messages "${REPO}" "fix(tags): converge duplicates" "Detailed explanation line."
assert_subject "body-preserved" "fix(tags): converge duplicates (#605)"
if printf '%s' "${BODY_MSG}" | grep -qF 'Detailed explanation line.'; then
  ok "body-preserved: the body paragraph survived"
else
  bad "body-preserved: the body paragraph was lost: ${BODY_MSG}"
fi

# ----- COMMIT_SOURCE guard --------------------------------------------------
# On a branch that WOULD otherwise contribute (#605), a non-"message" source
# must make the hook exit without touching the message.

for source in merge template squash commit; do
  start_case "COMMIT_SOURCE=${source}: hook leaves the message untouched even on an issue branch"
  new_repo_on_branch "fix/605-converge-duplicate-tags"
  run_hook_direct "${REPO}" "Merge branch 'x'" "${source}"
  if [ "${DIRECT_RC}" -eq 0 ]; then
    ok "${source}: hook exits 0"
  else
    bad "${source}: hook exited ${DIRECT_RC}"
  fi
  if [ "${DIRECT_MSG}" = "Merge branch 'x'" ]; then
    ok "${source}: message left untouched"
  else
    bad "${source}: message was modified to \"${DIRECT_MSG}\""
  fi
done

# The empty-source path (an editor commit) is NOT an early exit — the hook
# proceeds and appends, same as the "message" source above.
start_case "empty COMMIT_SOURCE (editor commit): hook proceeds and appends"
new_repo_on_branch "fix/605-converge-duplicate-tags"
run_hook_direct "${REPO}" "fix(tags): converge duplicates" ""
if [ "${DIRECT_MSG}" = "fix(tags): converge duplicates (#605)" ]; then
  ok "empty-source: reference appended"
else
  bad "empty-source: expected the reference to be appended, got \"${DIRECT_MSG}\""
fi

report
