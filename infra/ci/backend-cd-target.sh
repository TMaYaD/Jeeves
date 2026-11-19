#!/usr/bin/env bash
# Resolve what a Backend CD run should deploy, independent of what triggered it.
#
# GitHub keeps one pending run per concurrency group and cancels the pending
# one when a newer run arrives.  A run that said "a later run will deploy this"
# and skipped therefore loses its change whenever that later run is the one
# that was cancelled.  So no run trusts its own trigger: every run looks at
# main's tip and deploys the *target* — the newest first-parent commit that
# touches a Backend CI push-trigger path.  Every commit from the target to the
# tip has the same backend/infra tree, so deploying the target deploys exactly
# what the tip would, and the last run to arrive (never cancelled) ships any
# change a cancelled run would have.
#
# Modes:
#   backend-cd-target.sh <tip_sha>
#       stdout: target=<sha>.  A one-line reason goes to stderr.  Exits non-zero
#       if tip_sha is not a commit in this clone, or no commit touches a
#       trigger path.
#   backend-cd-target.sh --gate <status> <conclusion>
#       Decide from the target's Backend CI push run.  stdout:
#       deployable=true|false.  Exits non-zero when status is empty or "null",
#       i.e. no run was found: the job goes red instead of guessing.
#   backend-cd-target.sh --trigger-paths
#       Print the trigger paths, one per line.
set -euo pipefail

# Prefix-matched copy of `on.push.paths` in .github/workflows/backend-ci.yml
# (`x/**` becomes `x/`).  A workflow `paths:` filter cannot read a file, so the
# list exists twice; tests/test-backend-cd-target.sh fails if they differ.
TRIGGER_PATHS=(
  'backend/'
  'infra/'
  '.githooks/'
  '.github/workflows/backend-ci.yml'
)

usage() {
  echo "usage: $0 <tip_sha> | --gate <status> <conclusion> | --trigger-paths" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage

case "$1" in
  --trigger-paths)
    printf '%s\n' "${TRIGGER_PATHS[@]}"
    exit 0
    ;;
  --gate)
    [ "$#" -eq 3 ] || usage
    STATUS="$2"
    CONCLUSION="$3"
    if [ -z "${STATUS}" ] || [ "${STATUS}" = 'null' ]; then
      echo "::error::No Backend CI push run found for the deploy target." >&2
      exit 1
    fi
    if [ "${STATUS}" != 'completed' ]; then
      echo "::notice::Backend CI for the deploy target is ${STATUS}; its completion queues a CD run that re-evaluates." >&2
      echo 'deployable=false'
    elif [ "${CONCLUSION}" = 'success' ]; then
      echo 'Backend CI for the deploy target succeeded.' >&2
      echo 'deployable=true'
    else
      echo "::warning::Backend CI for the deploy target ended '${CONCLUSION}'; not deploying." >&2
      echo 'deployable=false'
    fi
    exit 0
    ;;
esac

[ "$#" -eq 1 ] || usage
TIP_SHA="$1"

cd "$(git rev-parse --show-toplevel)"

if ! git cat-file -e "${TIP_SHA}^{commit}" 2>/dev/null; then
  echo "main's tip ${TIP_SHA} is not in this clone; cannot resolve a target." >&2
  exit 1
fi

TARGET=$(git log --first-parent -1 --format=%H "${TIP_SHA}" -- "${TRIGGER_PATHS[@]}")
if [ -z "${TARGET}" ]; then
  echo "No commit up to ${TIP_SHA} touches a Backend CI trigger path." >&2
  exit 1
fi

echo "Deploy target ${TARGET} (main's tip is ${TIP_SHA})." >&2
echo "target=${TARGET}"
