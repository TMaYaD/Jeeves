#!/usr/bin/env bash
# Tests for compute-server-version.sh.
#
# Every case builds a throwaway git repository in a temp directory and runs the
# real script against it — no stubs, no fixtures checked in.  git is the only
# thing the script talks to, so a scratch repo *is* production for it.
#
# The behaviours worth protecting are the ones nothing else would catch: the
# four-segment pre-1.0 arithmetic (including the patch elision that takes it
# back to three), the Other→patch floor that keeps a dependency bump from
# deploying under an unchanged version, the backend path filter that makes
# app-only ranges a no-op, subject anchoring (a body line mentioning `feat:`
# must not bump), how merge commits fall out of default history simplification,
# and the hard failure when the baseline tag has not been seeded.
#
# Usage: ./test-compute-server-version.sh
set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="${TESTS_DIR}/../compute-server-version.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

FAILURES=0

start_case() { printf '\n%s\n' "$1"; }
ok()  { printf '  ok   — %s\n' "$1"; }
bad() { printf '  FAIL — %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

report() {
  echo
  if [ "${FAILURES}" -eq 0 ]; then
    echo "All checks passed."
    exit 0
  fi
  echo "${FAILURES} check(s) failed."
  exit 1
}

# ----- Scratch repo helpers ---------------------------------------------------

REPO=""
REPO_SEQ=0

new_repo() {
  REPO_SEQ=$((REPO_SEQ + 1))
  REPO="${WORK}/repo-${REPO_SEQ}"
  mkdir -p "${REPO}/backend" "${REPO}/app"
  git -C "${REPO}" init -q -b main
  git -C "${REPO}" config user.email 'tests@example.invalid'
  git -C "${REPO}" config user.name 'Compute Version Tests'
  git -C "${REPO}" config commit.gpgsign false
  printf 'base\n' > "${REPO}/backend/service.txt"
  printf 'base\n' > "${REPO}/app/ui.txt"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m 'chore: initial import'
}

# touch_backend <content-line>; touch_app <content-line>
touch_backend() { printf '%s\n' "$1" >> "${REPO}/backend/service.txt"; }
touch_app()     { printf '%s\n' "$1" >> "${REPO}/app/ui.txt"; }

# commit_backend <subject> [body...]
commit_backend() {
  touch_backend "$1"
  git -C "${REPO}" add -A
  local subject="$1"; shift
  local args=(-m "${subject}")
  local paragraph
  for paragraph in "$@"; do args+=(-m "${paragraph}"); done
  git -C "${REPO}" commit -q "${args[@]}"
}

# commit_app <subject>
commit_app() {
  touch_app "$1"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m "$1"
}

tag_here() { git -C "${REPO}" tag -a "server/v$1" -m "Server $1"; }

# ----- Running the script -----------------------------------------------------

OUT=""
RC=0

compute() {
  OUT=$(cd "${REPO}" && "${SCRIPT}" 2>&1)
  RC=$?
}

field() { printf '%s\n' "${OUT}" | grep -m1 "^$1=" | cut -d= -f2-; }

has_key() { printf '%s\n' "${OUT}" | grep -q "^$1="; }

# The notes fragment is emitted as a GitHub Actions multi-line output
# (`notes<<DELIM ... DELIM`), so read the delimiter off the opening line rather
# than hardcoding it.
notes_body() {
  printf '%s\n' "${OUT}" | awk '
    /^notes<</ { delim = substr($0, 8); next }
    delim != "" && $0 == delim { exit }
    delim != "" { print }
  '
}

assert_eq() {
  local expected="$1" actual="$2" what="$3"
  if [ "${expected}" = "${actual}" ]; then
    ok "${what} (${actual})"
  else
    bad "${what}: expected '${expected}', got '${actual}'"
    printf '    --- output ---\n%s\n' "${OUT}" | sed 's/^/    /'
  fi
}

assert_version_bump() {
  local expected_version="$1" expected_bump="$2"
  assert_eq "${expected_version}" "$(field version)" "version"
  assert_eq "${expected_bump}" "$(field bump)" "bump"
  if [ "${expected_bump}" = none ]; then
    if has_key tag; then
      bad "no tag= emitted when bump=none"
    else
      ok "no tag= emitted when bump=none"
    fi
  else
    assert_eq "server/v${expected_version}" "$(field tag)" "tag"
  fi
}

assert_notes_contain() {
  if notes_body | grep -qF -- "$1"; then
    ok "release notes mention '$1'"
  else
    bad "release notes are missing '$1':$(printf '\n%s' "$(notes_body)")"
  fi
}

assert_notes_lack() {
  if notes_body | grep -qF -- "$1"; then
    bad "release notes should not mention '$1':$(printf '\n%s' "$(notes_body)")"
  else
    ok "release notes omit '$1'"
  fi
}

assert_rc() {
  if [ "${RC}" -eq "$1" ]; then
    ok "$2 (exit ${RC})"
  else
    bad "$2: expected exit $1, got ${RC}"
  fi
}

# ----- Cases ------------------------------------------------------------------

start_case "feat: touching backend/ bumps the inner minor"
new_repo
tag_here 0.1.0
commit_backend 'feat(backend): add an endpoint'
compute
assert_version_bump 0.1.1 minor
assert_notes_contain 'feat(backend): add an endpoint'

start_case "fix: touching backend/ bumps the inner patch into a fourth segment"
new_repo
tag_here 0.1.0
commit_backend 'fix(backend): stop the leak'
compute
assert_version_bump 0.1.0.1 patch

start_case "type!: subject marker bumps the inner major"
new_repo
tag_here 0.1.0
commit_backend 'feat(backend)!: replace the sync protocol'
compute
assert_version_bump 0.2.0 major

start_case "BREAKING CHANGE footer bumps the inner major"
new_repo
tag_here 0.1.0
commit_backend 'fix(backend): tighten the token check' 'BREAKING CHANGE: old tokens are rejected.'
compute
assert_version_bump 0.2.0 major

start_case "seed baseline: a breaking backend change takes 0.0.9 to 0.1.0"
new_repo
tag_here 0.0.9
commit_backend 'feat(backend)!: replace the sync protocol'
compute
assert_version_bump 0.1.0 major

start_case "Other-only range hits the patch floor rather than bump=none"
new_repo
tag_here 0.1.0
commit_backend 'chore(backend): bump asyncpg'
commit_backend 'refactor(backend): split the router'
compute
assert_version_bump 0.1.0.1 patch
assert_notes_contain 'chore(backend): bump asyncpg'

start_case "app-only range is bump=none but still reports the current version"
new_repo
tag_here 0.1.0
commit_app 'feat(app): new planning screen'
commit_app 'fix(app): tighten the padding'
compute
assert_version_bump 0.1.0 none
assert_notes_lack 'feat(app): new planning screen'

start_case "empty range is bump=none"
new_repo
commit_backend 'feat(backend): shipped before the tag'
tag_here 0.1.1
compute
assert_version_bump 0.1.1 none

start_case "mixed range applies the highest bump once and elides the patch again"
new_repo
tag_here 0.1.0
commit_backend 'fix(backend): first'
commit_backend 'feat(backend): second'
commit_backend 'chore(backend): third'
compute
assert_version_bump 0.1.1 minor

start_case "a body line beginning feat: does not bump (subject anchoring)"
new_repo
tag_here 0.1.0
# The quoted original subject sits at the start of its own body line — exactly
# the shape a revert takes, and the one a whole-message regex would misread.
commit_backend 'chore(backend): revert an experiment' \
  'This reverts commit deadbeef.' \
  'feat: add an endpoint'
compute
assert_version_bump 0.1.0.1 patch

start_case "a body line beginning fix: does not bump past a plain chore either"
new_repo
tag_here 0.1.0
commit_backend 'chore(backend): tidy imports' 'fix: an unrelated subject quoted in the body'
compute
assert_eq patch "$(field bump)" "bump"
assert_notes_contain '### Other'
assert_notes_lack '### Fixes'

start_case "mixed 3- and 4-segment tags sort by version, not lexically"
new_repo
tag_here 0.1.0
commit_backend 'fix(backend): a'
tag_here 0.1.0.1
commit_backend 'feat(backend): b'
tag_here 0.9.0
commit_backend 'feat(backend): c'
tag_here 0.10.0
commit_backend 'fix(backend): d'
compute
assert_version_bump 0.10.0.1 patch
assert_notes_contain 'fix(backend): d'
assert_notes_lack 'feat(backend): c'

start_case "merged PR: constituent commits classify, the merge subject is simplified away"
new_repo
tag_here 0.1.0
git -C "${REPO}" checkout -q -b feature
commit_backend 'feat(backend): merged behaviour'
commit_app 'chore(app): tidy the widget'
git -C "${REPO}" checkout -q main
git -C "${REPO}" merge -q --no-ff -m 'Merge pull request #42 from TMaYaD/feature' feature
compute
assert_version_bump 0.1.1 minor
assert_notes_contain 'feat(backend): merged behaviour'
assert_notes_lack 'Merge pull request #42'

start_case "conflict-resolving merge that itself changes backend/ classifies as Other"
new_repo
tag_here 0.1.0
git -C "${REPO}" checkout -q -b sideb
commit_backend 'chore(backend): side b tuning'
git -C "${REPO}" checkout -q main
commit_backend 'chore(backend): main tuning'
git -C "${REPO}" merge --no-ff -m 'Merge branch sideb' sideb >/dev/null 2>&1
printf 'base\nreconciled\n' > "${REPO}/backend/service.txt"
git -C "${REPO}" add -A
git -C "${REPO}" commit -q --no-edit
compute
assert_version_bump 0.1.0.1 patch
assert_notes_contain 'Merge branch sideb'

start_case "release notes list exactly the backend-touching commits, grouped"
new_repo
tag_here 0.1.0
commit_backend 'feat(backend)!: drop the legacy endpoint'
commit_backend 'feat(backend): add the replacement'
commit_backend 'fix(backend): correct the status code'
commit_backend 'chore(backend): bump httpx'
commit_app 'feat(app): unrelated app work'
compute
assert_version_bump 0.2.0 major
assert_notes_contain '### Breaking'
assert_notes_contain '### Features'
assert_notes_contain '### Fixes'
assert_notes_contain '### Other'
assert_notes_contain 'feat(backend)!: drop the legacy endpoint'
assert_notes_contain 'feat(backend): add the replacement'
assert_notes_contain 'fix(backend): correct the status code'
assert_notes_contain 'chore(backend): bump httpx'
assert_notes_lack 'feat(app): unrelated app work'

start_case "no server/v* tag fails loudly and names the baseline to seed"
new_repo
commit_backend 'feat(backend): something'
compute
assert_rc 1 "exits non-zero with no baseline tag"
if printf '%s' "${OUT}" | grep -q 'server/v0.0.9'; then
  ok "failure message names server/v0.0.9"
else
  bad "failure message does not name server/v0.0.9: ${OUT}"
fi

start_case "app tags in the v* namespace never perturb the server version"
new_repo
tag_here 0.1.0
git -C "${REPO}" tag -a 'v9.9.9' -m 'App GA'
commit_backend 'fix(backend): unaffected by app tags'
compute
assert_version_bump 0.1.0.1 patch

report
