#!/usr/bin/env bash
# Real-SDK coverage for .githooks/pre-commit's Flutter path (issue #678).
#
# WHAT THIS IS, AND WHY IT IS SEPARATE FROM test-pre-commit-hook.sh
# ----------------------------------------------------------------
# test-pre-commit-hook.sh runs the real hook against *fake* flutter/dart
# launchers that hand-model the SDK's own self-resolution (#594/#644). That
# suite is the fast red/green detector for the hook's LOGIC — it runs on four
# shells in milliseconds and goes red against the unfixed hook — but it is
# blind to the SDK CHANGING. If a future Flutter release resolves its own
# revision through a different channel, the stubs keep passing while the #644
# protection quietly stops matching reality.
#
# This script closes that blind spot with ONE additive check: it drives the
# hook's Flutter path against a real, pinned, DISPOSABLE Flutter SDK, in the
# linked-worktree + real-`git commit` configuration that reproduces #644. It
# does not replace any stub case and it changes neither the hook nor the stub
# suite (both out of scope for #678).
#
# BLAST RADIUS — READ BEFORE POINTING THIS AT ANYTHING
# ----------------------------------------------------
# The bug it exercises DELETES SHARED SDK STATE: bin/internal/shared.sh judges
# its tool cache stale (a leaked GIT_DIR misdirects `git -C "$FLUTTER_ROOT"
# rev-parse HEAD`) and deletes bin/cache/flutter.version.json AND
# "$FLUTTER_ROOT/version", then never rewrites them for a `dart` call. Run
# against a SHARED SDK, that wedges `dart pub` for every other worker on the
# machine. So this script:
#   * uses ONLY a disposable SDK, designated explicitly via JEEVES_REAL_SDK
#     (CI passes the runner-local subosito/flutter-action install); it never
#     auto-resolves the machine's shared SDK;
#   * HARD-REFUSES the hook's own shared fallbacks and the FVM store
#     (~/fvm/versions/*, ~/development/flutter, ~/flutter, /opt/flutter) —
#     refusal, not a warning;
#   * repairs the disposable SDK on exit via a clean-env `flutter --version`,
#     so even a run that corrupts it heals before returning;
#   * makes no multi-GB per-run SDK copies (the workaround #676 retired).
#
# RECORDED AC-NARROWING (issue #678 acceptance criterion 3)
# ---------------------------------------------------------
# AC #3 asks one check to assert BOTH that flutter.version.json survives AND
# that no `git rev-parse --local-env-vars` name reaches a Flutter/Dart child.
# This check SPLITS them deliberately:
#   * Survival  -> asserted here directly (byte-compare of the version file).
#   * "no repo-local var reaches a launcher's own environment" -> stays the
#     STUB suite's job (assert_no_local_git_env_leaked, on four shells), which
#     records the child's env with no interposition conflict. Here the real
#     launchers run UNMODIFIED, so nothing can read a launcher's own env; a
#     *harmful* leak is still caught through the survival outcome (a leak that
#     corrupts changes the cache -> byte-compare reds), and a non-interposing
#     git-shim adds an AC #4 mechanism-drift sentinel (below).
#
# TEETH-PROOF (development-order step 1 — done by hand, never in this file)
# ------------------------------------------------------------------------
# A green check that cannot go red proves nothing. Against a DISPOSABLE SDK
# and an unfixed copy of the hook (the `unset` narrowed back into the
# self-heal subshell), the byte-compare MUST red — both because the leaked
# GIT_DIR makes the self-heal stamp the worktree revision and because `dart`
# hits shared.sh's revision mismatch and deletes flutter.version.json with no
# rewrite. Measured on 3.44.1 against a deliberately-unfixed hook: byte-compare
# red, commit rejected. If a future pinned SDK does NOT corrupt against the
# unfixed hook, STOP and escalate (comment on the issue, flag maintainers) —
# do not ship a green-by-construction check. Run the teeth-proof with:
#   HOOK=/tmp/unfixed-pre-commit \
#   JEEVES_REAL_SDK=/tmp/throwaway-flutter-clone \
#   ./.githooks/tests/test-pre-commit-real-sdk.sh
#
# WHERE IT RUNS / COST
# --------------------
# Executed in the Flutter workflow (.github/workflows/flutter-ci.yml, job
# `hook-real-sdk`), NOT the fast SDK-less `Infra & hooks` job. Its shebang means
# the backend-ci shell-lint sweep covers it too. Cost is recorded in that
# job's YAML comment.
#
# Usage (local): JEEVES_REAL_SDK=/path/to/disposable/sdk ./test-pre-commit-real-sdk.sh
#   No JEEVES_REAL_SDK -> loud SKIP + exit 0 locally; a hard failure under CI
#   (or REQUIRE_REAL_SDK=1, which the CI job sets).

set -uo pipefail

# ----- Configuration (named module-level constants, no inline magic) --------

# The Flutter package the fixture generates. Both fixtures (main checkout and
# linked worktree) use it; the linked-worktree commit is what triggers the hook.
FIXTURE_PACKAGE_NAME="jeeves_precommit_fixture"

# build_runner pinned EXACT: an unpinned range would let a future pub.dev
# release red this job for reasons unrelated to the hook. Kept in step with the
# app's own resolution (app/pubspec.lock) so it is known to resolve against the
# SDK pinned in app/.fvmrc.
# not configurable: this is the fixture's own dependency pin, not a tunable.
PINNED_BUILD_RUNNER_VERSION="2.15.0"

# A restricted PATH so the hook can only see whatever SDK bin dir it resolves
# and puts on PATH itself, never a real system Flutter/Dart. Mirrors the stub
# suite's BARE_PATH.
BARE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

TESTS_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
# HOOK is overridable so the teeth-proof can point it at an unfixed copy.
HOOK="${HOOK:-${TESTS_DIR}/../pre-commit}"

# The real HOME and pub cache, captured before any HOME rewriting. The commit
# runs under an empty HOME (to neutralise the hook's $HOME/*flutter fallbacks),
# but the fixtures' `pub get` ran under the real HOME, so the commit must be
# handed the real pub cache or build_runner/analyze/test resolve nothing.
REAL_HOME="${HOME}"
REAL_PUB_CACHE="${PUB_CACHE:-${REAL_HOME}/.pub-cache}"

# The names git considers repo-local — exactly what the hook unsets, and
# exactly what would misresolve a Flutter/Dart child to the wrong repository.
LOCAL_GIT_ENV_VARS=$(git -C "${TESTS_DIR}" rev-parse --local-env-vars 2>/dev/null || true)

# Defensive: never let a repo-local git env inherited by THIS script misdirect
# the SDK's own self-resolution during setup. The hook clears its own for the
# committing child; we clear ours for the setup commands.
if [ -n "${LOCAL_GIT_ENV_VARS}" ]; then
  # shellcheck disable=SC2086
  unset ${LOCAL_GIT_ENV_VARS}
fi

# ----- Bookkeeping ----------------------------------------------------------

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

WORK=$(mktemp -d)
mkdir -p "${WORK}/empty-home"

sdk=""                         # resolved (pwd -P) disposable SDK root
sdk_confirmed_disposable=0     # only repair a SDK we proved is disposable

# Trap-repair on exit: a clean-env `flutter --version` from inside the SDK
# regenerates flutter.version.json (and version) even if the run corrupted it,
# then WORK is removed. Only fires once the SDK has passed the hard-refuse.
# shellcheck disable=SC2317  # body runs via the EXIT trap, not inline
cleanup() {
  if [ "${sdk_confirmed_disposable}" -eq 1 ] && [ -n "${sdk}" ] && [ -x "${sdk}/bin/flutter" ]; then
    ( cd "${sdk}" && ./bin/flutter --version >/dev/null 2>&1 ) || true
  fi
  rm -rf "${WORK}"
}
trap cleanup EXIT

# ----- Premise resolution (skip loudly; fail in CI) -------------------------

# Missing designated SDK: skip locally, fail under CI / REQUIRE_REAL_SDK — a
# silently skipped real-SDK check is exactly how SDK drift would stay invisible.
premise_unmet() {
  local reason="$1"
  if [ -n "${CI:-}" ] || [ -n "${REQUIRE_REAL_SDK:-}" ]; then
    start_case "real-SDK coverage: premise unmet under CI"
    bad "${reason} (CI requires a designated disposable git-checkout SDK)"
    report
  fi
  start_case "real-SDK coverage: no disposable SDK designated"
  skip "${reason}"
  echo
  echo "Set JEEVES_REAL_SDK to a throwaway git-checkout Flutter SDK to run this"
  echo "locally; CI runs it in the Flutter workflow against the runner-local"
  echo "subosito/flutter-action install."
  exit 0
}

# Hard error regardless of environment — an explicitly designated SDK that is
# non-git or shared is a mistake or drift, never something to skip past.
fatal() {
  start_case "real-SDK coverage: designated SDK is unusable"
  bad "$1"
  report
}

designated="${JEEVES_REAL_SDK:-}"
[ -n "${designated}" ] || premise_unmet "JEEVES_REAL_SDK is not set"
[ -d "${designated}" ] || premise_unmet "JEEVES_REAL_SDK=${designated} is not a directory"
sdk=$(cd "${designated}" && pwd -P) || premise_unmet "JEEVES_REAL_SDK=${designated} could not be resolved"

start_case "real-SDK coverage: driving the hook's Flutter path against ${sdk}"

# AC-anchor: the mechanism #644 protects is `git -C "$FLUTTER_ROOT" rev-parse
# HEAD`. If the designated SDK is not a git checkout, that mechanism has
# changed — red loudly rather than going vacuously green.
if ! git -C "${sdk}" rev-parse HEAD >/dev/null 2>&1 || [ ! -e "${sdk}/.git" ]; then
  fatal "designated SDK ${sdk} is not a git checkout — the #644 self-resolution mechanism (git -C FLUTTER_ROOT rev-parse HEAD) no longer applies; a release archive keeps its .git for flutter upgrade/channel, so a missing one means the mechanism changed and must be investigated, not skipped"
fi
sdk_head=$(git -C "${sdk}" rev-parse HEAD)

# Hard-refuse the shared SDKs a mis-designation would land on: the FVM store and
# the hook's own $HOME/system fallbacks. Refusal, not a warning.
#
# FVM keeps its versions under <cache>/versions/<ver>. The cache defaults to
# ~/fvm or ~/.fvm but is configurable via FVM_CACHE_PATH (current) or FVM_HOME
# (legacy fallback), so a shared SDK can live outside the two default roots.
# Enumerate the configured caches too — a designation that lands on any of them
# must be refused, exactly like the hard-coded roots.
refuse_if_shared() {
  local candidate resolved
  local -a shared_candidates=(
    "${REAL_HOME}/fvm/versions"/*
    "${REAL_HOME}/.fvm/versions"/*
  )
  [ -n "${FVM_CACHE_PATH:-}" ] && shared_candidates+=( "${FVM_CACHE_PATH}/versions"/* )
  [ -n "${FVM_HOME:-}" ] && shared_candidates+=( "${FVM_HOME}/versions"/* )
  shared_candidates+=(
    "${REAL_HOME}/development/flutter"
    "${REAL_HOME}/flutter"
    "/opt/flutter"
  )
  for candidate in "${shared_candidates[@]}"; do
    [ -d "${candidate}" ] || continue
    resolved=$(cd "${candidate}" && pwd -P) || continue
    if [ "${resolved}" = "${sdk}" ]; then
      fatal "designated SDK ${sdk} resolves to a SHARED SDK (${candidate}); running this against it would corrupt it for every worktree and worker on the machine (#644). Designate a DISPOSABLE SDK."
    fi
  done
}
refuse_if_shared
sdk_confirmed_disposable=1
ok "designated SDK is a git checkout (HEAD ${sdk_head}) and not a shared SDK"

# ----- Warm the SDK, then snapshot the healthy baseline ---------------------

# shared.sh's invalidation predicate has FOUR conditions (missing snapshot,
# missing/empty stamp, stamp != compilekey, and pubspec.yaml newer than
# pubspec.lock). A freshly installed SDK that has not built flutter_tools yet
# would lose flutter.version.json on the hook's first `dart` call — a false red
# unrelated to any leak. Warm the tool first (building it also runs a `pub get`
# that touches pubspec.lock, covering the mtime clause too), leaving the
# revision mismatch (the #644 signal) as the only remaining invalidation.
if ! ( cd "${sdk}" && ./bin/flutter --version >/dev/null 2>&1 ); then
  bad "could not warm the designated SDK (\`flutter --version\` failed from inside it)"
  report
fi

version_json="${sdk}/bin/cache/flutter.version.json"
version_file="${sdk}/version"   # absent on 3.44.1; snapshotted only if present
baseline_json="${WORK}/baseline-flutter.version.json"
baseline_version="${WORK}/baseline-version"

if [ ! -f "${version_json}" ]; then
  bad "warming did not produce ${version_json} — cannot establish a healthy baseline"
  report
fi
cp "${version_json}" "${baseline_json}"
[ -f "${version_file}" ] && cp "${version_file}" "${baseline_version}"

# Parse frameworkRevision (the SHA lives here in a real file; the real JSON puts
# a space after the colon, so the pattern tolerates it).
framework_revision_of() {
  grep -o '"frameworkRevision":[[:space:]]*"[^"]*"' "$1" 2>/dev/null | head -1 | cut -d'"' -f4
}
baseline_revision=$(framework_revision_of "${baseline_json}")
if [ "${baseline_revision}" = "${sdk_head}" ]; then
  ok "baseline flutter.version.json is healthy (frameworkRevision == SDK HEAD)"
else
  bad "baseline frameworkRevision (${baseline_revision:-<none>}) != SDK HEAD (${sdk_head}) after warming — the baseline is not trustworthy"
  report
fi

# ----- Fixture: a minimal real Flutter package ------------------------------

build_fixture_app() {
  local app_dir="$1"
  mkdir -p "${app_dir}/lib" "${app_dir}/test"

  cat > "${app_dir}/pubspec.yaml" <<EOF
name: ${FIXTURE_PACKAGE_NAME}
description: Disposable fixture for the real-SDK pre-commit hook check (#678).
publish_to: none
version: 0.0.0

environment:
  sdk: ">=3.11.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter

dev_dependencies:
  flutter_test:
    sdk: flutter
  build_runner: ${PINNED_BUILD_RUNNER_VERSION}

flutter:
  uses-material-design: true
EOF

  cat > "${app_dir}/lib/${FIXTURE_PACKAGE_NAME}.dart" <<'EOF'
/// Trivial library so the fixture analyzes cleanly.
int answer() => 42;
EOF

  cat > "${app_dir}/test/${FIXTURE_PACKAGE_NAME}_test.dart" <<EOF
import 'package:flutter_test/flutter_test.dart';
import 'package:${FIXTURE_PACKAGE_NAME}/${FIXTURE_PACKAGE_NAME}.dart';

void main() {
  test('answer is 42', () {
    expect(answer(), 42);
  });
}
EOF

  # Keep pub artefacts and the FVM link out of the tree, exactly like the app.
  cat > "${app_dir}/.gitignore" <<'EOF'
.dart_tool/
.fvm/
build/
EOF
}

git_init_repo() {
  local dir="$1" branch="$2"
  git -C "${dir}" init -q -b "${branch}"
  git -C "${dir}" config user.email 'jeeves@example.invalid'
  git -C "${dir}" config user.name 'Jeeves Dev'
  git -C "${dir}" config commit.gpgsign false
}

# Runs `flutter pub get` in a fixture app dir, from OUTSIDE the SDK, with a
# clean git env (the script already cleared its own). The SDK computes its own
# revision here — no cwd/GIT_DIR misdirection — so setup never corrupts it.
fixture_pub_get() {
  local label="$1" app_dir="$2" out
  if ! out=$( cd "${app_dir}" && "${sdk}/bin/flutter" pub get 2>&1 ); then
    bad "${label}: \`flutter pub get\` failed: ${out}"
    report
  fi
}

main_checkout="${WORK}/main-checkout"
mkdir -p "${main_checkout}/app"
build_fixture_app "${main_checkout}/app"
git_init_repo "${main_checkout}" main
git -C "${main_checkout}" add -A
git -C "${main_checkout}" commit -q -m 'seed fixture app'

# The FVM symlink lives ONLY in the main checkout, gitignored so a linked
# worktree never inherits it — the exact shape that makes the hook resolve the
# main checkout's SDK (#644's configuration). A plain symlink, nothing written
# under it, so the hook's `pwd -P` self-heal lands on the real disposable SDK.
mkdir -p "${main_checkout}/app/.fvm"
ln -s "${sdk}" "${main_checkout}/app/.fvm/flutter_sdk"
fixture_pub_get "main checkout" "${main_checkout}/app"

# A real linked worktree, with its own app/.fvm removed (a fresh one never
# carries it anyway — it is gitignored), so the hook must fall back to the main
# checkout's SDK.
commit_wt="${WORK}/linked-wt"
git -C "${main_checkout}" worktree add -q -b wt-real-sdk "${commit_wt}"
rm -rf "${commit_wt}/app/.fvm"
fixture_pub_get "linked worktree" "${commit_wt}/app"

# ----- Prove, by construction, which SDK the hook will resolve --------------

# The hook picks the SDK from a fixed candidate order (pre-commit:139-144). With
# candidate 1 (worktree app/.fvm/flutter_sdk) absent and candidate 2 (the main
# checkout's) resolving to the designated disposable SDK and executable, the
# hook MUST resolve candidate 2 and can never reach the absolute /opt/flutter
# path (which BARE_PATH cannot mask), because an earlier valid candidate wins.
worktree_candidate1="${commit_wt}/app/.fvm/flutter_sdk"
main_fvm_link="${main_checkout}/app/.fvm/flutter_sdk"
resolved_candidate2=$(cd "${main_fvm_link}" 2>/dev/null && pwd -P)

if [ ! -e "${worktree_candidate1}" ]; then
  ok "worktree carries no app/.fvm/flutter_sdk (candidate 1 absent — the #644 shape)"
else
  bad "worktree still carries app/.fvm/flutter_sdk — the fixture is not the #644 shape"
fi
if [ "${resolved_candidate2}" = "${sdk}" ] && [ -x "${main_fvm_link}/bin/flutter" ]; then
  ok "main checkout's app/.fvm/flutter_sdk resolves to the designated SDK and is executable (candidate 2 wins by construction)"
else
  bad "candidate 2 does not resolve to the designated SDK (${resolved_candidate2:-<none>} != ${sdk}) — resolution is not pinned"
  report
fi

# ----- Non-interposing git-shim (AC #4 mechanism-drift sentinel) ------------

# A recording `git` that logs each call's cwd, argv and any repo-local git env,
# then execs the real git unchanged. It touches nothing under the SDK, so it
# does not disturb the `pwd -P` self-heal. Its unique value is the case a
# byte-compare cannot see: a future SDK that self-resolves through a DIFFERENT
# channel (so `git -C FLUTTER_ROOT rev-parse HEAD` vanishes) reds on the "≥1
# SDK-targeted call" assertion even when the cache is not corrupted.
#
# A bare shim first on PATH is NOT enough: git prepends its own exec-path
# (which contains a `git`) to a hook's PATH, so the hook's own `git` would hit
# that, not the shim. The fix is to make the shim dir BE the exec-path —
# symlink git-core's helpers into it so external subcommands still resolve, then
# override only `git` — and point GIT_EXEC_PATH at it in the commit below.
git_shim_dir="${WORK}/git-shim"
git_probes="${WORK}/git-probes"
mkdir -p "${git_shim_dir}" "${git_probes}"
real_git=$(command -v git)
real_exec_path=$(git --exec-path)
if [ -d "${real_exec_path}" ]; then
  for helper in "${real_exec_path}"/*; do
    [ -e "${helper}" ] || continue
    ln -s "${helper}" "${git_shim_dir}/${helper##*/}"
  done
fi
rm -f "${git_shim_dir}/git"
cat > "${git_shim_dir}/git" <<SHIM
#!/bin/sh
_probe=\$(mktemp "\${SHIM_PROBE_DIR}/call.XXXXXX") || exec ${real_git} "\$@"
{
  printf 'CWD=%s\n' "\$(pwd -P)"
  printf 'ARGV=%s\n' "\$*"
  env | grep -E '^(GIT_|FLUTTER_ROOT=)' | sort
} > "\$_probe" 2>/dev/null
exec ${real_git} "\$@"
SHIM
chmod +x "${git_shim_dir}/git"

# ----- Stage the app change and drive a real `git commit` -------------------

# Install ONLY pre-commit into the common hooks dir a linked worktree shares —
# pointing core.hooksPath at .githooks would enlist commit-msg/prepare-commit-msg
# and interfere. A non-executable hook is silently ignored by git (a real risk
# for a hand-prepared teeth-proof copy), so fail clearly rather than letting the
# liveness gate report a mysterious "Flutter block never ran".
if [ ! -x "${HOOK}" ]; then
  bad "the hook at ${HOOK} is not executable — git would ignore it; run 'chmod +x' on it (teeth-proof copies especially)"
  report
fi
# git resolves a hook symlink against the hooks dir, not this script's cwd, so a
# relative HOOK (an overridden teeth-proof copy) would install a DANGLING link
# that git silently ignores — surfacing later as a mysterious "Flutter block
# never ran". The default HOOK is already absolute; pin an overridden one too.
hook_abs=$(cd -- "$(dirname -- "${HOOK}")" && printf '%s/%s\n' "$(pwd -P)" "$(basename -- "${HOOK}")")
ln -sf "${hook_abs}" "${main_checkout}/.git/hooks/pre-commit"

# Stage a single app/ file so the diff unambiguously matches the hook's
# `^app/` gate, without dragging in pub artefacts.
printf '\n// edited by the real-SDK check\n' >> "${commit_wt}/app/lib/${FIXTURE_PACKAGE_NAME}.dart"
git -C "${commit_wt}" add "app/lib/${FIXTURE_PACKAGE_NAME}.dart"

# `env -i` so every GIT_* the probes see was exported by git itself, not
# inherited from this suite. GIT_EXEC_PATH points git's own exec-path at the
# shim dir (see above), so the `git` git prepends to the hook's PATH — and the
# one every flutter/dart child inherits — is the recording shim. HOME is empty
# to neutralise the hook's $HOME/*flutter fallbacks. PUB_CACHE is pinned to the
# real, warmed cache the fixtures resolved against. SHIM_PROBE_DIR is not a
# repo-local git var, so it survives the hook's unset and reaches the shim in
# every child. GIT_EXEC_PATH and SHIM_PROBE_DIR are likewise not repo-local, so
# they too survive the unset. The outer git is the REAL binary (absolute path).
commit_out=$(env -i \
  PATH="${git_shim_dir}:${BARE_PATH}" \
  HOME="${WORK}/empty-home" \
  PUB_CACHE="${REAL_PUB_CACHE}" \
  GIT_EXEC_PATH="${git_shim_dir}" \
  SHIM_PROBE_DIR="${git_probes}" \
  "${real_git}" -C "${commit_wt}" commit -q -m 'trigger the hook' 2>&1)
commit_rc=$?

# ----- Assertions -----------------------------------------------------------

# 1. The commit succeeded and landed. This alone does NOT prove the Flutter
#    block ran (pre-commit:117 gates it and a skipped block still exits 0) —
#    assertion 2 is what proves the block executed.
if [ "${commit_rc}" -eq 0 ]; then
  ok "real git commit: the commit succeeded with no manual SDK repair"
else
  bad "real git commit: hook rejected the commit (rc=${commit_rc}): ${commit_out}"
fi
if git -C "${commit_wt}" log --oneline -1 2>/dev/null | grep -qF 'trigger the hook'; then
  ok "real git commit: the commit actually landed"
else
  bad "real git commit: nothing was committed"
fi

# 2. Liveness — the Flutter block actually ran. Without this, every survival /
#    revision assertion below would pass trivially on a hook that skipped the
#    block entirely.
if printf '%s' "${commit_out}" | grep -qF 'Flutter app files modified'; then
  ok "liveness: the Flutter block was entered (pre-commit:117 gate matched)"
else
  bad "liveness: the Flutter block never ran — the survival assertions below would be vacuous: ${commit_out}"
fi
if printf '%s' "${commit_out}" | grep -qF 'Running build_runner'; then
  ok "liveness: the hook reached the dart invocation past the unset (build_runner)"
else
  bad "liveness: the hook did not reach build_runner — the corruption path was not exercised: ${commit_out}"
fi

# 3. Survival — byte-identical version file(s). Catches deletion AND mutation,
#    schema-agnostic (the real file carries no wall-clock/path fields).
if [ -f "${version_json}" ] && cmp -s "${baseline_json}" "${version_json}"; then
  ok "survival: bin/cache/flutter.version.json survived byte-for-byte"
elif [ ! -f "${version_json}" ]; then
  bad "survival: bin/cache/flutter.version.json was DELETED — every other worker on the machine would be broken (#644)"
else
  bad "survival: bin/cache/flutter.version.json was MUTATED (not byte-identical to the healthy baseline)"
fi
if [ -f "${baseline_version}" ]; then
  if [ -f "${version_file}" ] && cmp -s "${baseline_version}" "${version_file}"; then
    ok "survival: \$FLUTTER_ROOT/version survived byte-for-byte"
  else
    bad "survival: \$FLUTTER_ROOT/version was deleted or mutated"
  fi
fi

# 4. Human-readable diagnostic on top of the byte-compare (matches TESTING.md).
after_revision=$(framework_revision_of "${version_json}")
if [ "${after_revision}" = "${sdk_head}" ]; then
  ok "frameworkRevision still matches the SDK's own HEAD (${sdk_head})"
else
  bad "frameworkRevision (${after_revision:-<none>}) != the SDK's own HEAD (${sdk_head}) — the cache no longer identifies the SDK"
fi

# 5/6. The git-shim's AC #4 sentinel: at least one SDK-targeted self-resolution
#      call, and none carrying a repo-local git var. "SDK-targeted" = argv
#      `-C <sdk>` OR cwd inside the SDK, compared on pwd -P-resolved paths
#      because the fixture SDK path is a symlink.
sdk_targeted_calls=0
for probe in "${git_probes}"/call.*; do
  [ -f "${probe}" ] || continue
  probe_cwd=$(grep -m1 '^CWD=' "${probe}" 2>/dev/null); probe_cwd="${probe_cwd#CWD=}"
  probe_argv=$(grep -m1 '^ARGV=' "${probe}" 2>/dev/null); probe_argv="${probe_argv#ARGV=}"
  is_sdk_targeted=0
  case " ${probe_argv} " in *" -C ${sdk} "*) is_sdk_targeted=1 ;; esac
  case "${probe_cwd}" in "${sdk}" | "${sdk}"/*) is_sdk_targeted=1 ;; esac
  [ "${is_sdk_targeted}" -eq 1 ] || continue
  sdk_targeted_calls=$((sdk_targeted_calls + 1))
  while IFS= read -r var_name; do
    [ -n "${var_name}" ] || continue
    if grep -q "^${var_name}=" "${probe}"; then
      bad "AC #4: an SDK-targeted git call carried repo-local ${var_name} (argv: ${probe_argv}) — the unset did not protect it"
    fi
  done <<< "${LOCAL_GIT_ENV_VARS}"
done

if [ "${sdk_targeted_calls}" -ge 1 ]; then
  ok "AC #4: the hook made ${sdk_targeted_calls} SDK-targeted git call(s) to the designated SDK — the self-resolution mechanism the stubs model still fires, against the real one"
else
  bad "AC #4: no SDK-targeted git call was recorded — a real SDK that resolves its revision through a different channel would silently stop matching the stubs"
fi

report
