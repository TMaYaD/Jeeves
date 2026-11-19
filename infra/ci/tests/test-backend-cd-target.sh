#!/usr/bin/env bash
# Tests for backend-cd-target.sh, on throwaway git repos with the real script.
# Includes a parity check that the script's trigger list matches the real
# `on.push.paths` of .github/workflows/backend-ci.yml.
#
# Usage: ./test-backend-cd-target.sh
set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="${TESTS_DIR}/../backend-cd-target.sh"
VERSION_SCRIPT="${TESTS_DIR}/../compute-server-version.sh"
CI_WORKFLOW="${TESTS_DIR}/../../../.github/workflows/backend-ci.yml"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
FAILURES=0

start_case() { printf '\n%s\n' "$1"; }
ok()  { printf '  ok   — %s\n' "$1"; }
bad() { printf '  FAIL — %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

REPO="${WORK}/repo"
mkdir -p "${REPO}"
git -C "${REPO}" init -q -b main
git -C "${REPO}" config user.email 'tests@example.invalid'
git -C "${REPO}" config user.name 'Target Tests'
git -C "${REPO}" config commit.gpgsign false

# commit_file <path> [subject] -> sets LAST to the new commit's sha
commit_file() {
  mkdir -p "${REPO}/$(dirname "$1")"
  printf 'x\n' >> "${REPO}/$1"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m "${2:-touch $1}"
  LAST=$(git -C "${REPO}" rev-parse HEAD)
}

OUT=""; RC=0
resolve() { OUT=$(cd "${REPO}" && "${SCRIPT}" "$1" 2>/dev/null); RC=$?; }
gate() { OUT=$("${SCRIPT}" --gate "$1" "$2" 2>/dev/null); RC=$?; }

expect_target() { # expect_target <sha> <description>
  if [ "${RC}" -eq 0 ] && [ "${OUT}" = "target=$1" ]; then ok "$2"
  else bad "$2: expected target=$1, got rc=${RC} '${OUT}'"; fi
}
expect_gate() { # expect_gate <true|false> <description>
  if [ "${RC}" -eq 0 ] && [ "${OUT}" = "deployable=$1" ]; then ok "$2 (deployable=$1)"
  else bad "$2: expected deployable=$1, got rc=${RC} '${OUT}'"; fi
}
expect_failure() {
  if [ "${RC}" -ne 0 ]; then ok "$1: non-zero exit (${RC})"; else bad "$1: expected non-zero exit, got '${OUT}'"; fi
}

commit_file backend/a.txt; BASE=${LAST}

start_case "tip touches backend/"
resolve "${BASE}"; expect_target "${BASE}" "target is the tip"

start_case "only app commits after the last backend commit"
commit_file app/ui.txt; resolve "${LAST}"; expect_target "${BASE}" "target is the backend commit"

for path in infra/x.txt .githooks/x .github/workflows/backend-ci.yml; do
  start_case "${path} commit after the backend commit"
  git -C "${REPO}" reset -q --hard "${BASE}"
  commit_file "${path}"; commit_file app/more.txt
  resolve "${LAST}"; expect_target "$(git -C "${REPO}" rev-parse HEAD~1)" "target is the ${path} commit"
done

start_case "backend-cd.yml edit is not a trigger"
git -C "${REPO}" reset -q --hard "${BASE}"
commit_file .github/workflows/backend-cd.yml; resolve "${LAST}"; expect_target "${BASE}" "target unchanged"

start_case "PR merged with --no-ff: target is the merge commit"
git -C "${REPO}" reset -q --hard "${BASE}"
git -C "${REPO}" checkout -q -b feature
commit_file backend/branch.txt
git -C "${REPO}" checkout -q main
git -C "${REPO}" merge -q --no-ff feature -m "Merge pull request"
MERGE=$(git -C "${REPO}" rev-parse HEAD)
resolve "${MERGE}"; expect_target "${MERGE}" "target is the merge, not the branch commit"
git -C "${REPO}" reset -q --hard "${BASE}"

start_case "#1004 shape: a cancelled run's change ships from the surviving run"
git -C "${REPO}" reset -q --hard "${BASE}"
git -C "${REPO}" tag server/v0.0.9 "${BASE}"
commit_file backend/p.txt "fix: older change P"
commit_file backend/b.txt "feat: newer change B"
B_SHA=${LAST}
commit_file app/tip.txt
resolve "$(git -C "${REPO}" rev-parse HEAD)"; expect_target "${B_SHA}" "target is B, whichever run resolves it"
git -C "${REPO}" checkout -q --detach "${B_SHA}"
VERSION_OUT=$(cd "${REPO}" && "${VERSION_SCRIPT}" 2>/dev/null); VERSION_RC=$?
if [ "${VERSION_RC}" -eq 0 ] \
  && printf '%s\n' "${VERSION_OUT}" | grep -qx 'deploy=true' \
  && printf '%s\n' "${VERSION_OUT}" | grep -qx 'bump=minor' \
  && printf '%s\n' "${VERSION_OUT}" | grep -q 'older change P' \
  && printf '%s\n' "${VERSION_OUT}" | grep -q 'newer change B'; then
  ok "deploying B deploys P and B (deploy=true, bump=minor)"
else
  bad "version at B: rc=${VERSION_RC} '${VERSION_OUT}'"
fi
git -C "${REPO}" checkout -q main

start_case "unknown tip fails loudly"
resolve "0000000000000000000000000000000000000001"; expect_failure "unknown tip"

start_case "no commit touches a trigger path"
EMPTY="${WORK}/empty"; mkdir -p "${EMPTY}"
git -C "${EMPTY}" init -q -b main
git -C "${EMPTY}" config user.email 'tests@example.invalid'; git -C "${EMPTY}" config user.name t
git -C "${EMPTY}" config commit.gpgsign false
git -C "${EMPTY}" commit -q --allow-empty -m init
OUT=$(cd "${EMPTY}" && "${SCRIPT}" "$(git -C "${EMPTY}" rev-parse HEAD)" 2>/dev/null); RC=$?
expect_failure "no trigger commit"

start_case "CI gate"
gate completed success;    expect_gate true  "completed success"
gate in_progress '';       expect_gate false "in progress"
gate queued '';            expect_gate false "queued"
gate completed failure;    expect_gate false "failure"
gate completed cancelled;  expect_gate false "cancelled"
gate completed timed_out;  expect_gate false "timed out"
gate '' '';                expect_failure "no run (empty)"
gate null null;            expect_failure "no run (null)"

start_case "trigger list matches backend-ci.yml on.push.paths"
WORKFLOW_PATHS=$(awk '
  /^on:/ { inon = 1; next }
  inon && /^  push:/ { inpush = 1; next }
  inpush && /^  [a-z_]+:/ { exit }
  inpush && /paths:/ { print; exit }
' "${CI_WORKFLOW}" | grep -o '"[^"]*"' | tr -d '"' | sed 's|/\*\*$|/|' | sort)
SCRIPT_PATHS=$("${SCRIPT}" --trigger-paths | sort)
if [ -n "${WORKFLOW_PATHS}" ] && [ "${WORKFLOW_PATHS}" = "${SCRIPT_PATHS}" ]; then
  ok "lists match"
else
  bad "lists differ"
  printf '    workflow:\n%s\n    script:\n%s\n' "${WORKFLOW_PATHS}" "${SCRIPT_PATHS}" | sed 's/^/    /'
fi

echo
if [ "${FAILURES}" -eq 0 ]; then echo "All checks passed."; exit 0; fi
echo "${FAILURES} check(s) failed."
exit 1
