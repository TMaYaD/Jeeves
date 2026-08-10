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
# The backend cases run under EVERY shell available, not just one. Git executes
# the hook through the `#!/bin/sh` in its shebang, so `sh` is the production
# path; `bash` and `zsh` are deliberate cross-shell compatibility coverage. That
# breadth is the substance of #539, because a bare `. .venv/bin/activate` fails
# two different ways: in POSIX mode (`sh`, dash) `.` is a special builtin, so the
# failure exits the script — the unguarded hook already returned non-zero there,
# and the guard is what makes the message actionable. Under `zsh` and plain
# `bash` the same failure is non-fatal, so the unguarded hook fell through to
# unactivated tools and, when those resolve on the outer PATH, reached `exit 0`
# and let the commit proceed unchecked. An `sh`-only suite would go green on
# that fall-through.
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

  # Probes are written under $sdk_root/.probe/, deliberately NOT under
  # bin/cache/ — anything dropped there would perturb sdk_cache_identity().
  cat > "${SDK}/bin/flutter" <<'FLUTTER'
#!/bin/sh
sdk_root=$(cd "$(dirname "$0")/.." && pwd -P)
mkdir -p "$sdk_root/.probe"
case "$1" in
  --version)
    rev=$(git rev-parse HEAD 2>/dev/null || echo "0.0.0-unknown")
    url=$(git remote get-url origin 2>/dev/null || echo "unknown")
    printf '{"flutterVersion":"%s","repositoryUrl":"%s"}\n' "$rev" "$url" \
      > "$sdk_root/bin/cache/flutter.version.json"
    ;;
  analyze)
    env | grep '^GIT_' | sort > "$sdk_root/.probe/flutter-analyze-git-env.txt"
    ;;
  test)
    env | grep '^GIT_' | sort > "$sdk_root/.probe/flutter-test-git-env.txt"
    ;;
esac
exit 0
FLUTTER
  chmod +x "${SDK}/bin/flutter"

  # Mirrors the real SDK's bin/internal/shared.sh, which `bin/dart` sources:
  # the launcher validates its tool cache against the SDK's OWN revision
  # (shared.sh:124), judges it stale when the two disagree (shared.sh:136), and
  # deletes bin/cache/flutter.version.json (shared.sh:150). With a leaked
  # GIT_DIR that `git` resolves the OUTER repo, so the check can never pass.
  #
  # The non-zero exit on a missing version file is not decoration: real
  # `dart run build_runner` fails outright once the SDK is corrupted, and that
  # failure is #644's headline symptom ("commits from any worktree fail
  # deterministically"). Without it the hook — and any real `git commit`
  # driving it — returns 0 whether or not the SDK was just wrecked, and every
  # exit-status assertion below is vacuous.
  cat > "${SDK}/bin/dart" <<'DART'
#!/bin/sh
sdk_root=$(cd "$(dirname "$0")/.." && pwd -P)
mkdir -p "$sdk_root/.probe"
env | grep '^GIT_' | sort > "$sdk_root/.probe/dart-git-env.txt"
cd "$sdk_root" || exit 1
rev=$(git rev-parse HEAD 2>/dev/null || echo unknown)
stamped=$(grep -o '"flutterVersion":"[^"]*"' bin/cache/flutter.version.json 2>/dev/null | cut -d'"' -f4)
if [ "$rev" != "$stamped" ]; then
  rm -f "$sdk_root/bin/cache/flutter.version.json"
fi
if [ ! -f "$sdk_root/bin/cache/flutter.version.json" ]; then
  echo "Could not find the Flutter SDK version file." >&2
  exit 1
fi
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

# The names git itself considers repo-local — the exact set the hook unsets,
# and the exact set that misresolves a child process to the wrong repository.
# Deliberately not "every GIT_* name": GIT_SSH_COMMAND and GIT_ASKPASS are not
# in this list and must survive, or a `dart pub` fetch of a git-sourced
# dependency loses its credential path for no benefit.
LOCAL_GIT_ENV_VARS=$(git -C "${TESTS_DIR}" rev-parse --local-env-vars)

# Asserts that a probe file written by a flutter/dart child carries none of
# them. A missing probe file is a failure, not a pass — it means the child
# never ran, so the assertion would otherwise be trivially satisfied.
assert_no_local_git_env_leaked() {
  local label="$1" probe_file="$2"
  local leaked="" var_name
  if [ ! -f "${probe_file}" ]; then
    bad "${label}: no probe at ${probe_file} — the child process never ran, so this proves nothing"
    return
  fi
  while IFS= read -r var_name; do
    [ -n "${var_name}" ] || continue
    if grep -q "^${var_name}=" "${probe_file}"; then
      leaked="${leaked} ${var_name}"
    fi
  done <<< "${LOCAL_GIT_ENV_VARS}"
  if [ -n "${leaked}" ]; then
    bad "${label}: repo-local git vars reached the child:${leaked}"
  else
    ok "${label}: no repo-local git vars reached the child"
  fi
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
  # $1 = cwd, $2 = optional PATH prefix (used to shadow `git` with a shim)
  local cwd="$1" path_prefix="${2:-}"
  local run_path="${BARE_PATH}"
  if [ -n "${path_prefix}" ]; then
    run_path="${path_prefix}:${BARE_PATH}"
  fi
  OUT=$(cd "${cwd}" && PATH="${run_path}" HOME="${WORK}/empty-home" sh "${HOOK}" 2>&1)
  RC=$?
}

# A `git` that behaves exactly like the real one except for
# `rev-parse --local-env-vars`, which it breaks in one of two ways: `empty`
# answers with nothing and exits 0, `nonzero` fails outright. Everything else
# is exec'd through to the real binary, because the hook needs a working `git`
# both before this point (`diff --cached`, `rev-parse --git-common-dir`) and
# inside the stub SDK.
make_broken_git_shim() {
  local shim_dir="$1" failure_mode="$2"
  local real_git
  real_git=$(command -v git)
  mkdir -p "${shim_dir}"
  cat > "${shim_dir}/git" <<SHIM
#!/bin/sh
if [ "\$1" = "rev-parse" ] && [ "\$2" = "--local-env-vars" ]; then
  case "${failure_mode}" in
    empty)   exit 0 ;;
    nonzero) echo 'fatal: simulated rev-parse failure' >&2; exit 128 ;;
  esac
fi
exec "${real_git}" "\$@"
SHIM
  chmod +x "${shim_dir}/git"
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

# Stub ruff/mypy/pytest that all pass. What's under test here is the hook's
# prerequisite resolution, not the linters: these stubs are the *control* that
# makes the guard the only variable. Real tools would defeat that — a genuine
# ruff failure is indistinguishable from the guard firing, so the negative cases
# below could no longer prove which one stopped the hook. Whether ruff/mypy/pytest
# themselves pass is covered for real by the backend-ci lint and test jobs.
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

# The three shapes of a venv that EXISTS but cannot be used. Each one passes the
# `[ -f .venv/bin/activate ]` existence guard, so each is a distinct chance to
# fall through to the outer PATH and re-run #539 one step further along.
#
# What makes that fall-through *detectable* is OUTER_TOOLS, which
# `run_backend_hook` puts on PATH for these cases — NOT the stubs inside
# .venv/bin. A failed or inert activation never adds .venv/bin to PATH, so those
# stubs are unreachable by definition; the outer ones are the only tools a
# fell-through hook can find, and they are what let it reach `exit 0` instead of
# dying on a missing binary. Drop the OUTER_TOOLS argument from these call sites
# and the cases still go green against a hook with no guard at all. Measured, on
# an inert venv with the guards reverted: rc=0 with the outer stubs, rc=1
# without.
#
# The fixtures do still populate .venv/bin, but for duller reasons: it creates
# the directory the activate file lives in, and makes each fixture a realistic
# "tools installed, activation broken" venv rather than an empty shell.

# Bad mode bits — readable by `[ -f ]`, not by `.`.
make_unreadable_venv() {
  local backend_dir="$1"
  write_passing_tool_stubs "${backend_dir}/.venv/bin"
  printf 'VIRTUAL_ENV=unused\n' > "${backend_dir}/.venv/bin/activate"
  chmod 000 "${backend_dir}/.venv/bin/activate"
}

# Corrupt/half-written activate — sourcing it fails outright.
make_unsourceable_venv() {
  local backend_dir="$1"
  write_passing_tool_stubs "${backend_dir}/.venv/bin"
  # An unterminated `if` — a parse error in every shell, and root-proof, unlike
  # relying on mode bits.
  printf 'if true\n' > "${backend_dir}/.venv/bin/activate"
}

# Truncated activate — the nastiest shape, and the reason a source-status check
# is not sufficient on its own: this is valid shell, so every interpreter
# sources it happily and returns 0 while activating nothing at all.
make_inert_venv() {
  local backend_dir="$1"
  write_passing_tool_stubs "${backend_dir}/.venv/bin"
  printf '# truncated by an interrupted uv sync\n' > "${backend_dir}/.venv/bin/activate"
}

# ruff/mypy/pytest installed system-wide, outside any venv. This is what makes
# #539's silent success reachable: with no venv the hook would fall through to
# these, "pass" against the wrong environment, and reach `exit 0`.
OUTER_TOOLS="${WORK}/outer-tools"
write_passing_tool_stubs "${OUTER_TOOLS}"

# The interpreters every backend case runs under. `sh` is the production path —
# git invokes the hook via its `#!/bin/sh` shebang — and covers the POSIX-mode
# abort. `bash` and `zsh` are cross-shell compatibility coverage, and they earn
# their place rather than padding the matrix: outside POSIX mode a failed `.` is
# non-fatal, so they are the interpreters that exercise the fall-through into
# unactivated tools which reaches `exit 0`. Note `sh` and `bash` are genuinely
# different runs even where /bin/sh *is* bash, since POSIX mode is what makes
# the failed source fatal.
#
# `dash` is listed explicitly and is not redundant with `sh`. On Linux /bin/sh
# IS dash, but on macOS it is bash in POSIX mode, and the two disagree about
# what is fatal: bash-as-sh aborts on a failed special builtin but recovers from
# a parse error in a sourced file, while dash dies on both. Without an explicit
# dash row a developer's local run cannot see the dash-only failures at all, and
# the suite goes green on a hook that dies silently in CI.
BACKEND_SHELLS="sh"
for optional_shell in dash bash zsh; do
  if command -v "${optional_shell}" >/dev/null 2>&1; then
    BACKEND_SHELLS="${BACKEND_SHELLS} ${optional_shell}"
  else
    skip "${optional_shell} not on PATH — a non-POSIX-mode interpreter, where #539's fall-through reaches exit 0, goes unexercised"
  fi
done

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

# The whole contract for a backend venv the hook cannot use — whether it is
# missing outright or present-but-unusable: non-zero exit, a message that names
# both the prerequisite and the command that creates it, and no partial
# execution of the checks it couldn't set up for.
#
# The second argument is the phrase unique to the guard that SHOULD have fired.
# Without it the guards are indistinguishable from each other: every one of them
# exits non-zero and names both backend/.venv and the remedy, so deleting the
# existence check entirely would still leave the suite green — the readability
# check catches a missing file too, just while reporting that it "exists".
# Pinning the phrase is what keeps each case a test of one specific guard.
assert_backend_guard_fired() {
  local label="$1" expected_phrase="$2"
  if printf '%s' "${OUT}" | grep -qF "${expected_phrase}"; then
    ok "${label}: the expected guard fired (\"${expected_phrase}\")"
  else
    bad "${label}: expected guard phrase \"${expected_phrase}\" absent — a different guard fired: ${OUT}"
  fi
  if [ "${RC}" -ne 0 ]; then
    ok "${label}: hook exits non-zero (${RC})"
  else
    bad "${label}: hook exited 0 — git would go ahead and commit with the backend checks never having run (#539)"
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

# This case and the real-`git commit` one below are BOTH red/green detectors for
# #644 — neither is a passive bystander. This one is the cheaper of the two: it
# synthesises the hook environment, so it runs in milliseconds and pins the
# mechanism. Measured against the unfixed hook (unset still confined to the
# self-heal subshell): "FAIL — SDK cache identity changed unexpectedly", and the
# hook exits 1. The case below earns its extra cost with real-`git commit`
# fidelity — it does not have to guess which variables git exports.
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

# Driven by a REAL `git commit` from a REAL linked worktree, so nothing about
# git's hook environment is guessed: whatever git 2.x exports is what the hook
# gets. This is the case that covers #644 end to end, and it reaches past the
# self-heal into `dart run build_runner` / `flutter analyze` / `flutter test` —
# the invocations the old fix never protected.
#
# Measured, run against the unfixed hook (the unset still confined to the
# self-heal subshell, everything else in this file identical). Seven of the
# suite's nine failures came from this case alone; the other two are the
# synthesised-env case above:
#
#   FAIL — real git commit: hook rejected the commit (rc=1): … Could not find
#          the Flutter SDK version file. ❌ build_runner failed!
#   FAIL — real git commit: the shared SDK's flutter.version.json was deleted
#   FAIL — real git commit: SDK cache identity changed: <sdk rev> -> <deleted>
#   FAIL — real git commit / dart: repo-local git vars reached the child:
#          GIT_DIR GIT_INDEX_FILE GIT_PREFIX
#   FAIL — real git commit / flutter analyze: no probe … the child never ran
#   FAIL — real git commit / flutter test: no probe … the child never ran
#   FAIL — real git commit: nothing was committed — the hook blocked it
#
# (The two "child never ran" lines are the corruption's blast radius: the hook
# died at build_runner, so analyze and test were never reached.) All green with
# the fix in place. If this case ever passes both ways it has stopped testing
# anything — check the dart stub still exits non-zero on a missing version file.
start_case "linked worktree, real \`git commit\`: no repo-local git env reaches dart/flutter and the shared SDK survives"
new_fake_sdk
new_repo
before_identity=$(sdk_cache_identity)
commit_wt="${WORK}/linked-wt-real-commit-${REPO_SEQ}"
git -C "${REPO}" worktree add -q -b "wt-commit-branch-${REPO_SEQ}" "${commit_wt}"
# A fresh linked worktree never carries its own app/.fvm — that is the real
# shape, and it makes the hook resolve the main checkout's SDK.
rm -rf "${commit_wt}/app/.fvm"
# Install ONLY pre-commit, into the common hooks dir a linked worktree shares.
# Pointing core.hooksPath at .githooks would also enlist commit-msg and
# prepare-commit-msg, which are out of scope here and would interfere.
ln -sf "${HOOK}" "${REPO}/.git/hooks/pre-commit"
stage_app_change "${commit_wt}"
# `env -i` so the assertion is unambiguous about provenance: every GIT_* name
# the probes see was exported by git itself, not inherited from this suite.
commit_out=$(env -i PATH="${BARE_PATH}" HOME="${WORK}/empty-home" \
  git -C "${commit_wt}" commit -q -m 'trigger the hook' 2>&1)
commit_rc=$?
if [ "${commit_rc}" -eq 0 ]; then
  ok "real git commit: the commit succeeded with no manual SDK repair"
else
  bad "real git commit: hook rejected the commit (rc=${commit_rc}): ${commit_out}"
fi
if [ -f "${SDK}/bin/cache/flutter.version.json" ]; then
  ok "real git commit: the shared SDK still has bin/cache/flutter.version.json"
else
  bad "real git commit: the shared SDK's flutter.version.json was deleted — every other worker on this machine is now broken (#644)"
fi
after_identity=$(sdk_cache_identity)
worktree_rev=$(git -C "${commit_wt}" rev-parse HEAD)
if [ "${after_identity}" = "${worktree_rev}" ]; then
  bad "real git commit: SDK cache was stamped with the committing worktree's revision (${worktree_rev})"
elif [ "${after_identity}" = "${before_identity}" ]; then
  ok "real git commit: SDK cache still carries the SDK's own revision (${after_identity})"
else
  bad "real git commit: SDK cache identity changed: ${before_identity} -> ${after_identity:-<deleted>}"
fi
assert_no_local_git_env_leaked "real git commit / dart" "${SDK}/.probe/dart-git-env.txt"
assert_no_local_git_env_leaked "real git commit / flutter analyze" "${SDK}/.probe/flutter-analyze-git-env.txt"
assert_no_local_git_env_leaked "real git commit / flutter test" "${SDK}/.probe/flutter-test-git-env.txt"
# Guards against a hook that "passes" by never reaching the Flutter block at all.
if git -C "${commit_wt}" log --oneline -1 2>/dev/null | grep -qF 'trigger the hook'; then
  ok "real git commit: the commit actually landed"
else
  bad "real git commit: nothing was committed — the hook blocked it"
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

# ----- #440: the codegen stamp -----------------------------------------------
#
# build_runner used to run on every app/ commit regardless — ~30s warm, and 236s
# cold on the Pi agent host. It is now conditional, and "conditional" is exactly
# the kind of change that goes wrong silently: a cache that never invalidates
# hands analyze a stale tree and blames the wrong thing. Every case below
# asserts on the EFFECT — did a dart child actually spawn? — rather than on the
# hook's console prose.

# Marks codegen as up to date: a stamp, plus the generated output whose absence
# the hook treats as proof the stamp is lying.
mark_codegen_fresh() {
  local target_repo="$1"
  mkdir -p "${target_repo}/app/.dart_tool"
  printf '// generated\n' > "${target_repo}/app/lib/foo.g.dart"
  # Stamp last, so it is newer than every input the hook compares against.
  sleep 1
  : > "${target_repo}/app/.dart_tool/jeeves-codegen.stamp"
}

dart_ran() { [ -f "${SDK}/.probe/dart-git-env.txt" ]; }

start_case "#440 codegen stamp: a fresh stamp skips build_runner entirely"
new_fake_sdk
new_repo
# Stage BEFORE marking fresh, so the stamp is newer than the staged edit and
# the hook has a genuine reason to skip. Staging afterwards would make the
# source newer and the skip would never be reached.
stage_app_change "${REPO}"
mark_codegen_fresh "${REPO}"
run_hook "${REPO}"
if [ "${RC}" -eq 0 ]; then ok "hook exits 0"; else bad "hook exited ${RC}: ${OUT}"; fi
if dart_ran; then
  bad "build_runner ran despite an up-to-date stamp — the cache does nothing"
else
  ok "build_runner was skipped (no dart child was spawned)"
fi

start_case "#440 codegen stamp: a source newer than the stamp forces a rebuild"
new_fake_sdk
new_repo
mark_codegen_fresh "${REPO}"
sleep 1
stage_app_change "${REPO}"   # touches app/lib/foo.dart, now newer than the stamp
run_hook "${REPO}"
if dart_ran; then
  ok "build_runner ran because an input changed after the stamp"
else
  bad "build_runner was skipped despite a source newer than the stamp — stale codegen would reach analyze: ${OUT}"
fi

start_case "#440 codegen stamp: a deleted source forces a rebuild (mtime lives on the directory)"
new_fake_sdk
new_repo
printf '// doomed\n' > "${REPO}/app/lib/doomed.dart"
git -C "${REPO}" add -A
git -C "${REPO}" commit -q -m 'add a second source'
mark_codegen_fresh "${REPO}"
sleep 1
# A deletion leaves no file whose mtime could betray it — only the parent
# directory changes. The orphaned foo.g.dart still says `part of` a source
# that is gone, so skipping here would hand analyze a tree that cannot build.
rm "${REPO}/app/lib/doomed.dart"
git -C "${REPO}" add -A
run_hook "${REPO}"
if dart_ran; then
  ok "build_runner ran after a source was deleted"
else
  bad "a deleted source did not invalidate the stamp — orphaned .g.dart would break analyze: ${OUT}"
fi

start_case "#440 codegen stamp: a stamp with no generated output still rebuilds"
new_fake_sdk
new_repo
stage_app_change "${REPO}"
mark_codegen_fresh "${REPO}"
# What `flutter clean`, a prune, or a fresh clone leaves behind: codegen is
# gitignored, so the outputs vanish while the stamp survives. Trusting the
# stamp here hands analyze a tree with no generated sources at all.
rm "${REPO}/app/lib/foo.g.dart"
run_hook "${REPO}"
if dart_ran; then
  ok "build_runner ran because the generated outputs were gone"
else
  bad "hook trusted a stamp whose outputs had been deleted: ${OUT}"
fi

# The unset is only as good as the list it is handed, and that list comes from a
# command that can fail. The empty-but-successful variant is the one a status
# check alone cannot see: `unset $local_git_env_vars` degrades to a bare `unset`
# with no operands — a no-op under sh/bash/dash, a non-fatal error under zsh —
# so nothing is cleared and the hook has no way to notice. Measured with the
# guard reverted, both variants: rc=0 and "Running build_runner" in the output,
# i.e. every Flutter invocation running with the repo-local git env intact,
# which is #644 back in force and completely silent about it.
for local_env_failure in empty nonzero; do
  start_case "\`git rev-parse --local-env-vars\` answers ${local_env_failure}: hook fails loudly instead of unsetting nothing"
  new_fake_sdk
  new_repo
  broken_git_dir="${WORK}/broken-git-${local_env_failure}-${REPO_SEQ}"
  make_broken_git_shim "${broken_git_dir}" "${local_env_failure}"
  stage_app_change "${REPO}"
  run_hook "${REPO}" "${broken_git_dir}"
  if [ "${RC}" -eq 1 ]; then
    ok "${local_env_failure}: hook exits 1"
  else
    bad "${local_env_failure}: hook exited ${RC}, expected 1: ${OUT}"
  fi
  if printf '%s' "${OUT}" | grep -qF "repo-local environment variables"; then
    ok "${local_env_failure}: message names the safeguard that could not be applied"
  else
    bad "${local_env_failure}: failure message is unclear: ${OUT}"
  fi
  if printf '%s' "${OUT}" | grep -qF 'Running build_runner'; then
    bad "${local_env_failure}: hook ran build_runner with the repo-local git env still set (#644)"
  else
    ok "${local_env_failure}: hook stopped before build_runner (no partial state)"
  fi
done

for backend_shell in ${BACKEND_SHELLS}; do

  start_case "no backend/.venv (${backend_shell}): hook fails loudly, does not attempt ruff"
  new_backend_repo
  stage_backend_change "${BACKEND_REPO}"
  run_backend_hook "${BACKEND_REPO}" "${backend_shell}"
  assert_backend_guard_fired "${backend_shell}" 'No backend venv found'

  start_case "no backend/.venv but ruff/mypy/pytest on the outer PATH (${backend_shell}): hook must not 'pass' against the wrong environment"
  new_backend_repo
  stage_backend_change "${BACKEND_REPO}"
  run_backend_hook "${BACKEND_REPO}" "${backend_shell}" "${OUTER_TOOLS}"
  assert_backend_guard_fired "${backend_shell}, system-wide tools" 'No backend venv found'

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
  assert_backend_guard_fired "${backend_shell}, linked worktree" 'No backend venv found'

  # A venv that exists but cannot be used has to fail exactly as loudly as a
  # missing one — same contract, so the same assertions. Each runs with the
  # outer tools on PATH, because that is the configuration where falling
  # through actually reaches `exit 0` instead of dying on a missing binary.

  start_case "backend/.venv present but activate unreadable (${backend_shell}): hook must not fall through"
  new_backend_repo
  # Stage first: `git add -A` cannot read a mode-000 file, and a failed stage
  # would leave nothing under backend/ for the hook to react to — the case
  # would then "pass" by never running the backend branch at all.
  stage_backend_change "${BACKEND_REPO}"
  make_unreadable_venv "${BACKEND_REPO}/backend"
  if [ -r "${BACKEND_REPO}/backend/.venv/bin/activate" ]; then
    skip "${backend_shell}: running as root — mode bits don't bite, unreadable case not exercisable"
  else
    run_backend_hook "${BACKEND_REPO}" "${backend_shell}" "${OUTER_TOOLS}"
    assert_backend_guard_fired "${backend_shell}, unreadable activate" 'is not readable'
  fi

  start_case "backend/.venv present but activate unsourceable (${backend_shell}): hook must not fall through"
  new_backend_repo
  make_unsourceable_venv "${BACKEND_REPO}/backend"
  stage_backend_change "${BACKEND_REPO}"
  run_backend_hook "${BACKEND_REPO}" "${backend_shell}" "${OUTER_TOOLS}"
  assert_backend_guard_fired "${backend_shell}, unsourceable activate" 'could not be sourced'

  start_case "backend/.venv present but activate inert (${backend_shell}): sources cleanly, activates nothing"
  new_backend_repo
  make_inert_venv "${BACKEND_REPO}/backend"
  stage_backend_change "${BACKEND_REPO}"
  run_backend_hook "${BACKEND_REPO}" "${backend_shell}" "${OUTER_TOOLS}"
  assert_backend_guard_fired "${backend_shell}, inert activate" 'does not resolve inside it'

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
