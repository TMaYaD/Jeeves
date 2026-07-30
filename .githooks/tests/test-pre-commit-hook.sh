#!/usr/bin/env bash
# Tests for the Flutter-resolution and self-heal step in .githooks/pre-commit.
#
# Every case builds throwaway git repositories in a temp directory — a fake
# shared FVM SDK (itself a git checkout, exactly like the real
# ~/fvm/versions/<ver> one), a fake "Jeeves" checkout, and a fake linked
# worktree of it — and runs the real hook against them. `flutter` and `dart`
# are stubbed (a real Flutter SDK isn't available in CI and would make these
# tests slow and network-dependent), but the stub reproduces the exact bug
# from #594: `flutter --version` writes bin/cache/flutter.version.json using
# the git identity of its OWN cwd, same as the real tool.
#
# The behaviours worth protecting: the self-heal step must never stamp the
# outer repo's revision into the shared SDK cache (#594's corruption), and a
# linked worktree — which never carries its own app/.fvm/flutter_sdk — must
# either resolve the main checkout's SDK or fail loudly, never silently.
#
# Usage: ./test-pre-commit-hook.sh
set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
HOOK="${TESTS_DIR}/../pre-commit"

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

# A restricted PATH so the hook can only see whatever SDK bin dir it resolves
# and puts on PATH itself, never a real system Flutter/Dart.
BARE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# ----- Fake SDK -----------------------------------------------------------
# A stub Flutter SDK that is itself a git checkout, like the real shared FVM
# SDK. Its stub `flutter --version` reproduces #594's bug faithfully: it
# derives the identity it writes into bin/cache/flutter.version.json from
# the git repo of ITS CWD, exactly like the real tool.

SDK=""
SDK_SEQ=0

new_fake_sdk() {
  SDK_SEQ=$((SDK_SEQ + 1))
  SDK="${WORK}/fake-sdk-${SDK_SEQ}"
  mkdir -p "${SDK}/bin/cache"

  cat > "${SDK}/bin/flutter" <<'FLUTTER'
#!/bin/sh
sdk_root=$(cd "$(dirname "$0")/.." && pwd -P)
case "$1" in
  --version)
    rev=$(git rev-parse HEAD 2>/dev/null || echo "0.0.0-unknown")
    url=$(git remote get-url origin 2>/dev/null || echo "unknown")
    printf '{"flutterVersion":"%s","repositoryUrl":"%s"}\n' "$rev" "$url" \
      > "$sdk_root/bin/cache/flutter.version.json"
    ;;
  analyze) : ;;
  test) : ;;
esac
exit 0
FLUTTER
  chmod +x "${SDK}/bin/flutter"

  cat > "${SDK}/bin/dart" <<'DART'
#!/bin/sh
exit 0
DART
  chmod +x "${SDK}/bin/dart"

  git -C "${SDK}" init -q -b flutter-sdk-main
  git -C "${SDK}" config user.email 'sdk@example.invalid'
  git -C "${SDK}" config user.name 'Fake SDK'
  git -C "${SDK}" config commit.gpgsign false
  git -C "${SDK}" remote add origin 'git@github.com:flutter/flutter.git'
  git -C "${SDK}" add -A
  git -C "${SDK}" commit -q -m 'seed sdk'

  sdk_rev=$(git -C "${SDK}" rev-parse HEAD)
  printf '{"flutterVersion":"%s","repositoryUrl":"git@github.com:flutter/flutter.git"}\n' \
    "${sdk_rev}" > "${SDK}/bin/cache/flutter.version.json"
}

sdk_cache_identity() {
  # Prints just the flutterVersion field — the SDK's own revision when
  # healthy, or a foreign repo's revision when corrupted.
  grep -o '"flutterVersion":"[^"]*"' "${SDK}/bin/cache/flutter.version.json" | cut -d'"' -f4
}

# ----- Fake "Jeeves" checkout ----------------------------------------------

REPO=""
REPO_SEQ=0

new_repo() {
  REPO_SEQ=$((REPO_SEQ + 1))
  REPO="${WORK}/main-checkout-${REPO_SEQ}"
  mkdir -p "${REPO}/app/lib"
  git -C "${REPO}" init -q -b main
  git -C "${REPO}" config user.email 'jeeves@example.invalid'
  git -C "${REPO}" config user.name 'Jeeves Dev'
  git -C "${REPO}" config commit.gpgsign false
  printf '// seed\n' > "${REPO}/app/lib/foo.dart"
  git -C "${REPO}" add -A
  git -C "${REPO}" commit -q -m 'seed jeeves repo'

  mkdir -p "${REPO}/app/.fvm"
  ln -s "${SDK}" "${REPO}/app/.fvm/flutter_sdk"
}

stage_app_change() {
  local target_repo="$1"
  printf '// edited\n' >> "${target_repo}/app/lib/foo.dart"
  git -C "${target_repo}" add -A
}

run_hook() {
  local cwd="$1"
  OUT=$(cd "${cwd}" && PATH="${BARE_PATH}" HOME="${WORK}/empty-home" sh "${HOOK}" 2>&1)
  RC=$?
}

OUT=""
RC=0

# ----- Cases ----------------------------------------------------------------

start_case "main checkout: self-heal does not corrupt the shared SDK cache with Jeeves's revision"
new_fake_sdk
new_repo
before_identity=$(sdk_cache_identity)
stage_app_change "${REPO}"
run_hook "${REPO}"
if [ "${RC}" -eq 0 ]; then ok "hook exits 0"; else bad "hook exited ${RC}: ${OUT}"; fi
after_identity=$(sdk_cache_identity)
jeeves_rev=$(git -C "${REPO}" rev-parse HEAD)
if [ "${after_identity}" = "${jeeves_rev}" ]; then
  bad "SDK cache was stamped with Jeeves's revision (${jeeves_rev}) — this is #594"
elif [ "${after_identity}" = "${before_identity}" ]; then
  ok "SDK cache still carries the SDK's own revision (${after_identity})"
else
  bad "SDK cache identity changed unexpectedly: ${before_identity} -> ${after_identity}"
fi

start_case "linked worktree without app/.fvm: hook resolves the main checkout's SDK and still doesn't corrupt it"
new_fake_sdk
new_repo
before_identity=$(sdk_cache_identity)
linked_wt="${WORK}/linked-wt-${REPO_SEQ}"
git -C "${REPO}" worktree add -q -b "wt-branch-${REPO_SEQ}" "${linked_wt}"
rm -rf "${linked_wt}/app/.fvm"
stage_app_change "${linked_wt}"
run_hook "${linked_wt}"
if [ "${RC}" -eq 0 ]; then
  ok "hook exits 0 from a linked worktree lacking app/.fvm"
else
  bad "hook exited ${RC} from a linked worktree lacking app/.fvm: ${OUT}"
fi
after_identity=$(sdk_cache_identity)
if [ "${after_identity}" = "${before_identity}" ]; then
  ok "SDK cache untouched/idempotent (${after_identity})"
else
  bad "SDK cache identity changed: ${before_identity} -> ${after_identity}"
fi

start_case "linked worktree, invoked with git's own hook env: self-heal doesn't leak the outer worktree's identity into the SDK cache"
new_fake_sdk
new_repo
before_identity=$(sdk_cache_identity)
linked_wt="${WORK}/linked-wt-git-env-${REPO_SEQ}"
git -C "${REPO}" worktree add -q -b "wt-env-branch-${REPO_SEQ}" "${linked_wt}"
stage_app_change "${linked_wt}"
# `git commit` sets GIT_DIR/GIT_INDEX_FILE on the hook's own environment when
# run from a linked worktree — pointing at the worktree's git-dir, not the
# SDK's. Reproduce that env directly rather than shelling the hook out
# through a real `git commit`, so this stays a targeted regression test.
worktree_git_dir=$(git -C "${linked_wt}" rev-parse --absolute-git-dir)
OUT=$(cd "${linked_wt}" && PATH="${BARE_PATH}" HOME="${WORK}/empty-home" \
  GIT_DIR="${worktree_git_dir}" GIT_INDEX_FILE="${worktree_git_dir}/index" \
  sh "${HOOK}" 2>&1)
RC=$?
if [ "${RC}" -eq 0 ]; then
  ok "hook exits 0 under an outer-repo git env"
else
  bad "hook exited ${RC} under an outer-repo git env: ${OUT}"
fi
after_identity=$(sdk_cache_identity)
jeeves_rev=$(git -C "${linked_wt}" rev-parse HEAD)
if [ "${after_identity}" = "${jeeves_rev}" ]; then
  bad "SDK cache was stamped with the outer worktree's revision (${jeeves_rev}) — inherited GIT_DIR/GIT_INDEX_FILE leaked past the cd (#594)"
elif [ "${after_identity}" = "${before_identity}" ]; then
  ok "SDK cache still carries the SDK's own revision (${after_identity})"
else
  bad "SDK cache identity changed unexpectedly: ${before_identity} -> ${after_identity}"
fi

start_case "no SDK anywhere: hook fails loudly, does not attempt build_runner"
new_repo
rm -rf "${REPO}/app/.fvm"
stage_app_change "${REPO}"
run_hook "${REPO}"
if [ "${RC}" -eq 1 ]; then
  ok "hook exits 1 when no Flutter SDK can be resolved"
else
  bad "hook exited ${RC}, expected 1: ${OUT}"
fi
if printf '%s' "${OUT}" | grep -qi 'no flutter sdk found'; then
  ok "failure message names the problem clearly"
else
  bad "failure message is unclear: ${OUT}"
fi
if printf '%s' "${OUT}" | grep -q 'Running build_runner'; then
  bad "hook attempted build_runner despite having no SDK (partial state)"
else
  ok "hook stopped before build_runner (no partial state)"
fi

report
