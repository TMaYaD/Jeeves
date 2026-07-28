#!/usr/bin/env bash
# Compute the next server version from the conventional commits that touch the
# backend, and emit it — with a matching release-notes fragment — as GitHub
# Actions step outputs.
#
# This script is the single source of truth for the server versioning scheme.
# Documentation links here instead of restating the tag prefix, the path filter
# or the bump rules; see docs/BACKEND_GUIDELINES.md, "Server versioning &
# releases", for the policy those values implement.
#
# The scheme is ordinary semver hidden behind a `0.` prefix, so the numbers a
# reader sees are `0.X.Y` — and `0.X.Y.Z` once an inner patch exists.  X, Y and
# Z are the inner major, minor and patch.
#
# It only reads and prints.  Running it in a working checkout is therefore a
# true dry run: it answers "what would the next server version be" and changes
# nothing.
#
# Output, in GitHub Actions `key=value` form — append it straight to
# $GITHUB_OUTPUT:
#
#   version=<the next version, or the current one when bump=none>
#   bump=major|minor|patch|none
#   tag=server/v<version>              (omitted when bump=none)
#   notes<<DELIM ... DELIM             (markdown release-notes fragment)
#
# Usage: infra/ci/compute-server-version.sh
set -euo pipefail

# The whole scheme is these two constants plus arithmetic.  Docs point here.
TAG_PREFIX='server/v'
BACKEND_PATH_PREFIX='backend/'

# The one-time baseline the pipeline is seeded with.  Named in the failure
# below so an unseeded repository says what to do rather than guessing a
# starting point.
SEED_TAG="${TAG_PREFIX}0.0.9"

# Pathspecs and `git log` ranges are resolved relative to the working
# directory, so anchor at the repository root and keep BACKEND_PATH_PREFIX a
# plain repo-relative path.
cd "$(git rev-parse --show-toplevel)"

# Highest tag, not nearest ancestor: server tags are only ever cut by Backend
# CD, at main's tip, behind its freshness check and concurrency group — so they
# are totally ordered along main's first-parent history and the highest is
# always the most recent ancestor.  `sort -V` is what orders a mixed set of
# three- and four-segment versions correctly (0.1.0 < 0.1.0.1 < 0.1.1).
LAST_TAG=$(git tag --list "${TAG_PREFIX}*" | sort -V | tail -1)

if [ -z "${LAST_TAG}" ]; then
  cat >&2 <<EOF
No ${TAG_PREFIX}* tag found — seed ${SEED_TAG} first:

    git tag -a ${SEED_TAG} -m 'Baseline server version' <main tip>
    git push origin ${SEED_TAG}

The version is computed from the commits since the last ${TAG_PREFIX}* tag, so
without that baseline there is no range to compute from and every deploy would
be told a version that is merely plausible.  See docs/BACKEND_GUIDELINES.md,
"Server versioning & releases".
EOF
  exit 1
fi

CURRENT="${LAST_TAG#"${TAG_PREFIX}"}"
if ! printf '%s' "${CURRENT}" | grep -qE '^0\.[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
  echo "Malformed server tag ${LAST_TAG}: expected ${TAG_PREFIX}0.X.Y or ${TAG_PREFIX}0.X.Y.Z." >&2
  exit 1
fi

# Walk the range under default history simplification — deliberately neither
# --no-merges nor --full-history.  The commits of a merged PR that touch the
# backend appear and carry their conventional-commit type, while the
# `Merge pull request #N` commit is TREESAME to the merged branch for this
# pathspec and is simplified away.  A merge that is TREESAME to neither parent
# (a conflict resolution that itself changes the backend) does survive; its
# non-conventional subject classifies as Other, which the patch floor below
# turns into a version bump — correct, because such a merge is real backend
# content that exists in no other commit.
BREAKING=()
FEATURES=()
FIXES=()
OTHER=()

while IFS= read -r -d '' entry; do
  if [ -z "${entry}" ]; then continue; fi
  sha="${entry%%$'\n'*}"
  msg="${entry#*$'\n'}"
  subject="${msg%%$'\n'*}"
  line="- ${subject} (${sha:0:7})"
  # Anchor the type regexes to the subject: a revert or a quoted body line
  # beginning `feat:` must not bump.  BREAKING CHANGE is a footer convention,
  # so that one is matched against the whole message.
  if printf '%s' "${subject}" | grep -qE '^[a-z]+(\(.+\))?!:' \
     || printf '%s' "${msg}" | grep -q 'BREAKING CHANGE'; then
    BREAKING+=("${line}")
  elif printf '%s' "${subject}" | grep -qE '^feat(\(.+\))?:'; then
    FEATURES+=("${line}")
  elif printf '%s' "${subject}" | grep -qE '^fix(\(.+\))?:'; then
    FIXES+=("${line}")
  else
    OTHER+=("${line}")
  fi
done < <(git log -z --format="%H%n%B" "${LAST_TAG}..HEAD" -- "${BACKEND_PATH_PREFIX}")

TOTAL=$(( ${#BREAKING[@]} + ${#FEATURES[@]} + ${#FIXES[@]} + ${#OTHER[@]} ))

if [ "${TOTAL}" -eq 0 ]; then
  # Reserved for exactly this: nothing in the range touched the backend, so
  # there is no new server to name.  App-only work lands here.
  BUMP='none'
elif [ "${#BREAKING[@]}" -gt 0 ]; then
  BUMP='major'
elif [ "${#FEATURES[@]}" -gt 0 ]; then
  BUMP='minor'
else
  # fix: — and the patch floor.  A range of nothing but chore/refactor/deps
  # commits still ships different code; without the floor it would deploy under
  # an unchanged version and a lying /health.
  BUMP='patch'
fi

IMAJOR=$(printf '%s' "${CURRENT}" | cut -d. -f2)
IMINOR=$(printf '%s' "${CURRENT}" | cut -d. -f3)
IPATCH=$(printf '%s' "${CURRENT}" | cut -d. -f4)
IPATCH="${IPATCH:-0}"

case "${BUMP}" in
  major) IMAJOR=$((IMAJOR + 1)); IMINOR=0; IPATCH=0 ;;
  minor) IMINOR=$((IMINOR + 1)); IPATCH=0 ;;
  patch) IPATCH=$((IPATCH + 1)) ;;
esac

if [ "${BUMP}" = 'none' ]; then
  VERSION="${CURRENT}"
elif [ "${IPATCH}" -eq 0 ]; then
  # Four segments only once an inner patch exists.
  VERSION="0.${IMAJOR}.${IMINOR}"
else
  VERSION="0.${IMAJOR}.${IMINOR}.${IPATCH}"
fi

emit_group() {
  local heading="$1"
  shift
  if [ "$#" -eq 0 ]; then return 0; fi
  printf '### %s\n' "${heading}"
  printf '%s\n' "$@"
  printf '\n'
}

echo "version=${VERSION}"
echo "bump=${BUMP}"
if [ "${BUMP}" != 'none' ]; then
  echo "tag=${TAG_PREFIX}${VERSION}"
fi

# The same walk produced the bump and these notes, so the two cannot disagree.
# Multi-line step outputs need a delimiter that cannot occur in the value.
DELIM="SERVER_NOTES_$(date +%s)_$$"
echo "notes<<${DELIM}"
emit_group 'Breaking' ${BREAKING[@]+"${BREAKING[@]}"}
emit_group 'Features' ${FEATURES[@]+"${FEATURES[@]}"}
emit_group 'Fixes' ${FIXES[@]+"${FIXES[@]}"}
emit_group 'Other' ${OTHER[@]+"${OTHER[@]}"}
echo "${DELIM}"
