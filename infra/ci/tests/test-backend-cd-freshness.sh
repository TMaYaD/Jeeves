#!/usr/bin/env bash
# Tests for backend-cd-freshness.sh, on throwaway git repos with the real script.
# Includes a parity check that the script's trigger list matches the real
# `on.push.paths` of .github/workflows/backend-ci.yml.
#
# Usage: ./test-backend-cd-freshness.sh
set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="${TESTS_DIR}/../backend-cd-freshness.sh"
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
git -C "${REPO}" config user.name 'Freshness Tests'
git -C "${REPO}" config commit.gpgsign false

# commit_file <path> -> sets LAST to the new commit's sha
commit_file() {
  mkdir -p "${REPO}/$(dirname "$1")"
  printf 'x\n' >> "${REPO}/$1"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m "touch $1"
  LAST=$(git -C "${REPO}" rev-parse HEAD)
}

OUT=""; RC=0
decide() { OUT=$(cd "${REPO}" && "${SCRIPT}" "$1" "$2" 2>/dev/null); RC=$?; }

expect() { # expect <current value> <description>
  if [ "${RC}" -eq 0 ] && [ "${OUT}" = "current=$1" ]; then ok "$2 (current=$1)"
  else bad "$2: expected current=$1, got rc=${RC} '${OUT}'"; fi
}

commit_file backend/a.txt; BASE=${LAST}

start_case "run is main's tip"
decide "${BASE}" "${BASE}"; expect true "tip == run"

start_case "only app commits after the run: no later CD run, so deploy"
commit_file app/ui.txt; TIP=${LAST}
decide "${BASE}" "${TIP}"; expect true "app-only commit after"

start_case "infra commit after the run: its CD run deploys this change"
commit_file infra/x.txt; TIP=${LAST}
decide "${BASE}" "${TIP}"; expect false "infra commit after"

start_case "backend commit after the run"
git -C "${REPO}" reset -q --hard "${BASE}"
commit_file backend/b.txt; TIP=${LAST}
decide "${BASE}" "${TIP}"; expect false "backend commit after"

start_case "backend-ci.yml edit after the run"
git -C "${REPO}" reset -q --hard "${BASE}"
commit_file .github/workflows/backend-ci.yml; TIP=${LAST}
decide "${BASE}" "${TIP}"; expect false "backend-ci.yml edit after"

start_case "other workflow edit after the run triggers no Backend CI"
git -C "${REPO}" reset -q --hard "${BASE}"
commit_file .github/workflows/backend-cd.yml; TIP=${LAST}
decide "${BASE}" "${TIP}"; expect true "backend-cd.yml edit after"

start_case "run commit is not an ancestor of the tip"
git -C "${REPO}" reset -q --hard "${BASE}"
commit_file app/one.txt; OLD=${LAST}
git -C "${REPO}" reset -q --hard "${BASE}"
commit_file app/two.txt; TIP=${LAST}
decide "${OLD}" "${TIP}"; expect false "diverged history"

start_case "unknown tip fails loudly"
decide "${BASE}" "0000000000000000000000000000000000000001"
if [ "${RC}" -ne 0 ]; then ok "non-zero exit (${RC})"; else bad "expected non-zero exit, got '${OUT}'"; fi

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
