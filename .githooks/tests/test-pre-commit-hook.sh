#!/usr/bin/env bash
# Tests for .githooks/pre-commit's two prerequisite-resolution steps: the
# Flutter SDK resolution / self-heal step, and the backend venv check.
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
# outer repo's revision into the shared SDK cache (#594's corruption); a
# linked worktree — which never carries its own app/.fvm/flutter_sdk — must
# either resolve the main checkout's SDK or fail loudly, never silently; and
# a checkout without backend/.venv must fail loudly naming the fix command
# rather than falling through into whichever ruff/mypy/pytest happens to sit
# on the outer PATH (#539).
#
# The backend cases run under BOTH `sh` and `zsh`, because that difference is
# the whole substance of #539: a failed `. .venv/bin/activate` aborts the
# script under bash/dash but is NON-FATAL under zsh, where execution falls
# through to unactivated tools and can still reach `exit 0`. A suite that only
# exercised `sh` would go green while the reported bug was still live.
#
# Usage: ./test-pre-commit-hook.sh
set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
HOOK="${TESTS_DIR}/../pre-commit"

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

# ----- Fake backend checkout ------------------------------------------------
# A minimal repo carrying a backend/ directory and no backend/.venv — the exact
# shape of a freshly created linked worktree, since backend/.venv is gitignored
# and only ever materialized by `uv sync` (#539).

BACKEND_REPO=""
BACKEND_REPO_SEQ=0

new_backend_repo() {
  BACKEND_REPO_SEQ=$((BACKEND_REPO_SEQ + 1))
  BACKEND_REPO="${WORK}/backend-checkout-${BACKEND_REPO_SEQ}"
  mkdir -p "${BACKEND_REPO}/backend/app"
  git -C "${BACKEND_REPO}" init -q -b main
  git -C "${BACKEND_REPO}" config user.email 'jeeves@example.invalid'
  git -C "${BACKEND_REPO}" config user.name 'Jeeves Dev'
  git -C "${BACKEND_REPO}" config commit.gpgsign false
  printf '# seed\n' > "${BACKEND_REPO}/backend/app/main.py"
  git -C "${BACKEND_REPO}" add -A
  git -C "${BACKEND_REPO}" commit -q -m 'seed backend repo'
}

stage_backend_change() {
  local target_repo="$1"
  printf '# edited\n' >> "${target_repo}/backend/app/main.py"
  git -C "${target_repo}" add -A
}

# Stub ruff/mypy/pytest that all pass. A real toolchain isn't available in CI
# and installing one would make these tests slow and network-dependent; what's
# under test is the prerequisite check, not the linters themselves.
write_passing_tool_stubs() {
  local bin_dir="$1"
  mkdir -p "${bin_dir}"
  for stub_tool in ruff mypy pytest; do
    printf '#!/bin/sh\nexit 0\n' > "${bin_dir}/${stub_tool}"
    chmod +x "${bin_dir}/${stub_tool}"
  done
}

# A fake venv whose activate script does what a real one does — prepend its own
# bin/ to PATH — so sourcing it is exercised for real, not stubbed out.
make_fake_venv() {
  local backend_dir="$1"
  write_passing_tool_stubs "${backend_dir}/.venv/bin"
  cat > "${backend_dir}/.venv/bin/activate" <<ACTIVATE
VIRTUAL_ENV="${backend_dir}/.venv"
export VIRTUAL_ENV
PATH="\${VIRTUAL_ENV}/bin:\${PATH}"
export PATH
ACTIVATE
}

# ruff/mypy/pytest installed system-wide, outside any venv. This is what makes
# #539's silent success reachable: with no venv the hook would fall through to
# these, "pass" against the wrong environment, and reach `exit 0`.
OUTER_TOOLS="${WORK}/outer-tools"
write_passing_tool_stubs "${OUTER_TOOLS}"

# The interpreters every backend case runs under. zsh is not a nicety here: a
# failed `. .venv/bin/activate` aborts the script under bash/dash but is
# non-fatal under zsh, so zsh is the only interpreter where the unguarded
# source actually reproduces #539's silent success.
BACKEND_SHELLS="sh"
if command -v zsh >/dev/null 2>&1; then
  BACKEND_SHELLS="sh zsh"
else
  skip "zsh not on PATH — the interpreter where #539's silent-success path is live goes unexercised"
fi

run_backend_hook() {
  # $1 = cwd, $2 = interpreter name, $3 = optional PATH prefix
  local cwd="$1" shell_name="$2" path_prefix="${3:-}"
  local interpreter run_path="${BARE_PATH}"
  interpreter=$(command -v "${shell_name}")
  if [ -n "${path_prefix}" ]; then
    run_path="${path_prefix}:${BARE_PATH}"
  fi
  OUT=$(cd "${cwd}" && PATH="${run_path}" HOME="${WORK}/empty-home" \
    "${interpreter}" "${HOOK}" 2>&1)
  RC=$?
}

# The whole contract for a missing backend venv: non-zero exit, a message that
# names both the missing prerequisite and the command that creates it, and no
# partial execution of the checks it couldn't set up for.
assert_backend_guard_fired() {
  local label="$1"
  if [ "${RC}" -ne 0 ]; then
    ok "${label}: hook exits non-zero (${RC})"
  else
    bad "${label}: hook exited 0 — 'git commit' would report success and commit nothing (#539)"
  fi
  if printf '%s' "${OUT}" | grep -qF 'backend/.venv'; then
    ok "${label}: message names the missing prerequisite (backend/.venv)"
  else
    bad "${label}: message does not name backend/.venv: ${OUT}"
  fi
  if printf '%s' "${OUT}" | grep -qF 'uv sync --extra dev'; then
    ok "${label}: message names the remedy command"
  else
    bad "${label}: message does not name 'uv sync --extra dev': ${OUT}"
  fi
  if printf '%s' "${OUT}" | grep -qF 'Running ruff check'; then
    bad "${label}: fell through into ruff with no venv activated (partial state)"
  else
    ok "${label}: stopped before ruff (no partial state)"
  fi
}

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

for backend_shell in ${BACKEND_SHELLS}; do

  start_case "no backend/.venv (${backend_shell}): hook fails loudly, does not attempt ruff"
  new_backend_repo
  stage_backend_change "${BACKEND_REPO}"
  run_backend_hook "${BACKEND_REPO}" "${backend_shell}"
  assert_backend_guard_fired "${backend_shell}"

  start_case "no backend/.venv but ruff/mypy/pytest on the outer PATH (${backend_shell}): hook must not 'pass' against the wrong environment"
  new_backend_repo
  stage_backend_change "${BACKEND_REPO}"
  run_backend_hook "${BACKEND_REPO}" "${backend_shell}" "${OUTER_TOOLS}"
  assert_backend_guard_fired "${backend_shell}, system-wide tools"

  start_case "real linked worktree with no backend/.venv (${backend_shell}): hook fails loudly"
  new_backend_repo
  backend_wt="${WORK}/backend-linked-wt-${BACKEND_REPO_SEQ}-${backend_shell}"
  git -C "${BACKEND_REPO}" worktree add -q \
    -b "backend-wt-${BACKEND_REPO_SEQ}-${backend_shell}" "${backend_wt}"
  stage_backend_change "${backend_wt}"
  # A fresh linked worktree genuinely has no backend/.venv — nothing to remove.
  if [ -e "${backend_wt}/backend/.venv" ]; then
    bad "${backend_shell}: fixture is wrong — the linked worktree carries a backend/.venv"
  fi
  run_backend_hook "${backend_wt}" "${backend_shell}" "${OUTER_TOOLS}"
  assert_backend_guard_fired "${backend_shell}, linked worktree"

  start_case "backend/.venv present (${backend_shell}): guard doesn't false-positive, checks run"
  new_backend_repo
  make_fake_venv "${BACKEND_REPO}/backend"
  stage_backend_change "${BACKEND_REPO}"
  run_backend_hook "${BACKEND_REPO}" "${backend_shell}"
  if [ "${RC}" -eq 0 ]; then
    ok "${backend_shell}: hook exits 0 when the venv exists"
  else
    bad "${backend_shell}: hook exited ${RC} with a valid venv: ${OUT}"
  fi
  if printf '%s' "${OUT}" | grep -qF 'Running ruff check'; then
    ok "${backend_shell}: hook proceeded past the guard into the checks"
  else
    bad "${backend_shell}: hook never reached ruff despite a valid venv: ${OUT}"
  fi
  if printf '%s' "${OUT}" | grep -qF 'uv sync --extra dev'; then
    bad "${backend_shell}: guard false-positived — reported a missing venv that exists"
  else
    ok "${backend_shell}: guard stayed quiet"
  fi

done

report
