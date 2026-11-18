#!/usr/bin/env bash
# Decide whether a Backend CD run may deploy its own commit, or whether a newer
# main tip will do it instead.
#
# Backend CI finishes per push in whatever order its jobs take, so a successful
# run need not be for main's latest commit, and deploying a superseded one
# would push older code over newer.  The old answer was "skip unless the run's
# commit is main's tip" — which assumes the tip gets its own CD run.  It does
# not when the tip touches nothing Backend CI triggers on: no CI run, so no CD
# run, and the superseded run's backend change is never deployed.
#
# So a run is superseded only if a later commit will get its own CD run, i.e.
# the range run_sha..tip_sha touches a Backend CI push-trigger path.  Otherwise
# backend/ at the tip is identical to backend/ at run_sha, and deploying
# run_sha deploys exactly what the tip would.
#
# Output, in GitHub Actions form — append it straight to $GITHUB_OUTPUT:
#
#   current=true|false
#
# A one-line reason goes to stderr.  An unknown tip_sha exits non-zero: the run
# goes red, visibly, instead of guessing.
#
# Usage: infra/ci/backend-cd-freshness.sh <run_sha> <tip_sha>
#        infra/ci/backend-cd-freshness.sh --trigger-paths
set -euo pipefail

# Prefix-matched copy of `on.push.paths` in .github/workflows/backend-ci.yml
# (`x/**` becomes `x/`).  A workflow `paths:` filter cannot read a file, so the
# list exists twice; tests/test-backend-cd-freshness.sh fails if they differ.
TRIGGER_PATHS=(
  'backend/'
  'infra/'
  '.githooks/'
  '.github/workflows/backend-ci.yml'
)

if [ "${1:-}" = '--trigger-paths' ]; then
  printf '%s\n' "${TRIGGER_PATHS[@]}"
  exit 0
fi

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <run_sha> <tip_sha> | --trigger-paths" >&2
  exit 2
fi
RUN_SHA="$1"
TIP_SHA="$2"

cd "$(git rev-parse --show-toplevel)"

if ! git cat-file -e "${TIP_SHA}^{commit}" 2>/dev/null; then
  echo "main's tip ${TIP_SHA} is not in this clone; cannot decide freshness." >&2
  exit 1
fi

if [ "${RUN_SHA}" = "${TIP_SHA}" ]; then
  echo "This run is for main's tip." >&2
  echo 'current=true'
elif ! git merge-base --is-ancestor "${RUN_SHA}" "${TIP_SHA}"; then
  echo "${RUN_SHA} is not an ancestor of main's tip ${TIP_SHA}; not deploying." >&2
  echo 'current=false'
elif [ -n "$(git diff --name-only "${RUN_SHA}" "${TIP_SHA}" -- "${TRIGGER_PATHS[@]}")" ]; then
  echo "Superseded: ${TIP_SHA} touches Backend CI trigger paths, so its own run deploys this change too." >&2
  echo 'current=false'
else
  echo "Later commits up to ${TIP_SHA} trigger no Backend CI run; deploying ${RUN_SHA}, whose backend/ is identical." >&2
  echo 'current=true'
fi
