#!/usr/bin/env bash
# Tests for .githooks/commit-msg — the Conventional Commits validation it has
# always done, and the issue reference it now appends on the EDITOR path (#679),
# the path prepare-commit-msg cannot reach because it runs before the editor
# opens and no subject exists yet.
#
# Every case builds a throwaway git repository in a temp directory, checks out a
# branch under test, and runs a REAL `git commit` — through a scripted
# GIT_EDITOR where the editor path is what is being exercised. Nothing here
# invokes the hook by hand: going through git is what makes the intrinsic
# signals real (MERGE_HEAD, SQUASH_MSG, detached HEAD during rebase), and the
# assertion is always on the message git actually recorded (`git log -1`), never
# on a hook's stdout — a hook that exits 0 having done nothing and one that
# exits 0 having done the right thing are indistinguishable by status.
#
# `core.hooksPath` points at an isolated directory holding the PRODUCTION
# PAIRING — prepare-commit-msg, commit-msg, and lib/issue-reference.sh — because
# the reference is now produced by the two hooks over one shared contract, and
# testing commit-msg without prepare beside it would miss the `-m`/editor parity
# the whole feature is about. It deliberately does NOT install pre-commit (the
# Flutter + backend gauntlet).
#
# What commit-msg reconstructs, and what pins each reconstruction:
#
#   * commit-msg gets no $COMMIT_SOURCE, so it rebuilds the "don't append here"
#     cases from intrinsic signals — MERGE_HEAD (merge), SQUASH_MSG (squash),
#     the fixup!/squash!/amend! subject prefix (autosquash), and a detached HEAD
#     (rebase reword). Each has its own case below, driven by a real git
#     operation.
#   * The editor-quit abort is NOT git's empty-message check on this path: a
#     comments-only file fails the conventional-format validation first and
#     exits 1 with zero commits. The six-cell matrix pins that under the default
#     comment character, core.commentChar, core.commentString, and each with
#     commit.verbose.
#   * The already-referenced guard is joined by a trailing-reference guard, so a
#     commit authored on one numbered branch and amended on another does not
#     stack a second `(#N)`.
#
# Harness trap, load-bearing: do NOT seed an "unreferenced" commit with
# `--no-verify`. `--no-verify` skips pre-commit and commit-msg but NOT
# prepare-commit-msg, so a `-m` commit still gets `(#N)`. Unreferenced fixtures
# are seeded on a non-contract branch (`main`) instead, where the branch name
# yields no number.
#
# Pipefail trap, load-bearing: this runs under `set -uo pipefail`, so a
# `git log --pretty=%s | grep -q` can surface git-log's SIGPIPE (141) as the
# pipeline status and read as a false negative. Every such check uses `grep -c`,
# which reads to EOF, and tests the printed count — never the pipeline status
# (the #682 fix).
#
# Each case runs under every shell present, by rewriting the copied hooks'
# shebangs. `sh` is the production path; `dash` is not redundant with it (CI's
# /bin/sh is dash, macOS's is bash in POSIX mode); `bash` and `zsh` are
# cross-shell coverage. The lib is sourced by the hook, so it runs under the
# hook's interpreter and needs no shebang rewrite.
#
# Usage: ./test-commit-msg-hook.sh
set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
GITHOOKS="${TESTS_DIR}/.."

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

# ----- Per-shell hook installs ----------------------------------------------
# A copy of the real production pairing with the two hooks' shebangs rewritten
# to the interpreter under test. Everything below line 1 of each hook, and the
# whole lib, is the production file byte for byte.

hooks_dir_for()       { printf '%s/hooks-%s' "${WORK}" "$1"; }
hooks_dir_nolib_for() { printf '%s/hooks-nolib-%s' "${WORK}" "$1"; }

install_hook_for_shell() {
  local shell_name="$1" interpreter dir nolib hook
  interpreter=$(command -v "${shell_name}")
  dir=$(hooks_dir_for "${shell_name}")
  mkdir -p "${dir}/lib"
  for hook in prepare-commit-msg commit-msg; do
    {
      printf '#!%s\n' "${interpreter}"
      tail -n +2 "${GITHOOKS}/${hook}"
    } > "${dir}/${hook}"
    chmod +x "${dir}/${hook}"
  done
  cp "${GITHOOKS}/lib/issue-reference.sh" "${dir}/lib/issue-reference.sh"

  # A twin hooks dir with NO lib, for the missing-lib degradation case.
  nolib=$(hooks_dir_nolib_for "${shell_name}")
  mkdir -p "${nolib}"
  for hook in prepare-commit-msg commit-msg; do
    cp "${dir}/${hook}" "${nolib}/${hook}"
  done
}

HOOK_SHELLS=""
for candidate_shell in sh dash bash zsh; do
  if command -v "${candidate_shell}" >/dev/null 2>&1; then
    HOOK_SHELLS="${HOOK_SHELLS} ${candidate_shell}"
    install_hook_for_shell "${candidate_shell}"
  else
    skip "${candidate_shell} not on PATH — that interpreter's behaviour goes unexercised"
  fi
done

# The whole suite body is inside `for hook_shell in ${HOOK_SHELLS}`. An empty
# list would run zero assertions and still print "All checks passed." — the one
# way this file can lie. `sh` is guaranteed here, so the branch is unreachable
# today; it is a tripwire for whoever edits the candidate list.
if [ -z "${HOOK_SHELLS# }" ]; then
  bad "no shell interpreter found — the suite would otherwise report success having asserted nothing"
  report
fi

# ----- Repo fixtures --------------------------------------------------------

CASE_REPO=""
CASE_SEQ=0

new_case_repo() {
  # $1 = branch name to sit on, $2 = shell the hooks run under.
  CASE_SEQ=$((CASE_SEQ + 1))
  CASE_REPO="${WORK}/case-${CASE_SEQ}"
  mkdir -p "${CASE_REPO}"
  git -C "${CASE_REPO}" init -q -b "$1"
  git -C "${CASE_REPO}" config user.email 'jeeves@example.invalid'
  git -C "${CASE_REPO}" config user.name 'Jeeves Dev'
  git -C "${CASE_REPO}" config commit.gpgsign false
  git -C "${CASE_REPO}" config core.hooksPath "$(hooks_dir_for "$2")"
}

new_symlink_repo() {
  # $1 = branch, $2 = shell. Builds a repo whose .git/hooks/* are symlinks to
  # ../../.githooks/*, with a real .githooks/lib alongside, and NO
  # core.hooksPath. That is the layout `dirname "$0"` cannot resolve — $0 lands
  # in .git/hooks, where lib/ does not exist — so only resolver candidate 3
  # (git rev-parse --show-toplevel) finds the lib. The default fixtures use an
  # absolute mktemp hooks dir where candidate 1 always resolves, so this is the
  # only case that exercises candidate 3.
  CASE_SEQ=$((CASE_SEQ + 1))
  CASE_REPO="${WORK}/symcase-${CASE_SEQ}"
  local src
  src=$(hooks_dir_for "$2")
  mkdir -p "${CASE_REPO}/.githooks/lib"
  git -C "${CASE_REPO}" init -q -b "$1"
  git -C "${CASE_REPO}" config user.email 'jeeves@example.invalid'
  git -C "${CASE_REPO}" config user.name 'Jeeves Dev'
  git -C "${CASE_REPO}" config commit.gpgsign false
  cp "${src}/prepare-commit-msg" "${CASE_REPO}/.githooks/prepare-commit-msg"
  cp "${src}/commit-msg" "${CASE_REPO}/.githooks/commit-msg"
  cp "${src}/lib/issue-reference.sh" "${CASE_REPO}/.githooks/lib/issue-reference.sh"
  ln -sf ../../.githooks/prepare-commit-msg "${CASE_REPO}/.git/hooks/prepare-commit-msg"
  ln -sf ../../.githooks/commit-msg "${CASE_REPO}/.git/hooks/commit-msg"
}

COMMIT_RC=0
COMMIT_OUT=""
SUBJECT=""

commit_with() {
  # Remaining args are passed straight to `git commit`. --allow-empty keeps the
  # fixtures to one concern: what is staged is irrelevant to these hooks.
  COMMIT_OUT=$(git -C "${CASE_REPO}" commit -q --allow-empty "$@" 2>&1)
  COMMIT_RC=$?
  SUBJECT=$(git -C "${CASE_REPO}" log -1 --pretty=%s 2>/dev/null)
}

commit_with_editor() {
  # $1 = editor script, $2 = the subject it types (ignored by editor-quit).
  # Remaining args go to `git commit`. With none there is no -m, so git opens
  # the editor and commit-msg is where the reference is decided.
  local editor="$1" typed="$2"
  shift 2
  COMMIT_OUT=$(EDITOR_SUBJECT="${typed}" GIT_EDITOR="${editor}" \
    git -C "${CASE_REPO}" commit -q --allow-empty "$@" 2>&1)
  COMMIT_RC=$?
  SUBJECT=$(git -C "${CASE_REPO}" log -1 --pretty=%s 2>/dev/null)
}

assert_commit_succeeded() {
  if [ "${COMMIT_RC}" -eq 0 ]; then
    ok "$1: git commit succeeded"
  else
    bad "$1: git commit exited ${COMMIT_RC}: ${COMMIT_OUT}"
  fi
}

assert_subject() {
  # $1 = label, $2 = the exact subject line expected.
  assert_commit_succeeded "$1"
  if [ "${SUBJECT}" = "$2" ]; then
    ok "$1: subject is \"${SUBJECT}\""
  else
    bad "$1: subject is \"${SUBJECT}\", expected \"$2\""
  fi
}

assert_nothing_committed() {
  # $1 = label. Quitting the editor without saving must leave the repo exactly
  # as it was — a non-zero status alone is not enough, because a hook that
  # writes a junk message makes git succeed.
  if [ "${COMMIT_RC}" -ne 0 ]; then
    ok "$1: git commit aborted (status ${COMMIT_RC})"
  else
    bad "$1: git commit succeeded, expected an abort — recorded \"${SUBJECT}\""
  fi
  local commit_count
  commit_count=$(git -C "${CASE_REPO}" rev-list --all --count 2>/dev/null || printf '0')
  if [ "${commit_count}" = "0" ]; then
    ok "$1: nothing was committed"
  else
    bad "$1: ${commit_count} commit(s) recorded, expected none — subject \"${SUBJECT}\""
  fi
}

# ----- Capability probe: core.commentString (git 2.45+) ---------------------
# `git config core.commentString '//'` is NOT a capability test — git stores
# unknown keys and exits 0. Probe the BEHAVIOUR: feed stripspace a line that is
# a comment only if the key is understood. The probe body must be the comment
# ALONE, or the output is non-empty either way and the probe lies "supported".
if [ -z "$(printf '// probe\n' | git -c core.commentString='//' stripspace --strip-comments)" ]; then
  COMMENT_STRING_SUPPORTED=yes
else
  COMMENT_STRING_SUPPORTED=no
fi

# ----- Editor fixtures ------------------------------------------------------

# Quits without writing — a developer calling off the commit.
EDITOR_QUIT="${WORK}/editor-quit"
printf '#!/bin/sh\nexit 0\n' > "${EDITOR_QUIT}"
chmod +x "${EDITOR_QUIT}"

# Types ${EDITOR_SUBJECT} above git's comment block and saves.
EDITOR_WRITE="${WORK}/editor-write"
cat > "${EDITOR_WRITE}" <<'EDITOR_SCRIPT'
#!/bin/sh
{ printf '%s\n' "${EDITOR_SUBJECT}"; cat "$1"; } > "$1.typed"
mv "$1.typed" "$1"
EDITOR_SCRIPT
chmod +x "${EDITOR_WRITE}"

# Types a blank line, THEN ${EDITOR_SUBJECT} — a developer who left a blank line
# above the subject. git takes the first non-blank line as the subject, so the
# reference must land there, not on the blank line 1 (#679, the leading-blank
# corruption).
EDITOR_WRITE_BELOW_BLANK="${WORK}/editor-write-below-blank"
cat > "${EDITOR_WRITE_BELOW_BLANK}" <<'EDITOR_SCRIPT'
#!/bin/sh
{ printf '\n%s\n' "${EDITOR_SUBJECT}"; cat "$1"; } > "$1.typed"
mv "$1.typed" "$1"
EDITOR_SCRIPT
chmod +x "${EDITOR_WRITE_BELOW_BLANK}"

# Replaces the whole file with just ${EDITOR_SUBJECT} — used where git has
# pre-filled the file (merge --squash) and the assertion wants a clean subject.
EDITOR_REPLACE="${WORK}/editor-replace"
cat > "${EDITOR_REPLACE}" <<'EDITOR_SCRIPT'
#!/bin/sh
printf '%s\n' "${EDITOR_SUBJECT}" > "$1"
EDITOR_SCRIPT
chmod +x "${EDITOR_REPLACE}"

# Rebase sequence editor: turn the first `pick` into `reword`, portably (no
# `sed -i`, which is not the same on BSD sed).
SEQ_REWORD_FIRST="${WORK}/seq-reword-first"
cat > "${SEQ_REWORD_FIRST}" <<'SEQ_SCRIPT'
#!/bin/sh
sed '1s/^pick/reword/' "$1" > "$1.seq"
mv "$1.seq" "$1"
SEQ_SCRIPT
chmod +x "${SEQ_REWORD_FIRST}"

# ----- Autosquash fixtures (#675) -------------------------------------------
# A real `git commit --fixup`/`--squash` builds a subject git's own autosquash
# matches against its target byte-for-byte, so a real `git rebase --autosquash`
# is the only honest proof it collapses. GIT_SEQUENCE_EDITOR=true accepts the
# auto-arranged todo and GIT_EDITOR=true accepts any combined message.

TARGET_SUBJECT=""
TARGET_SHA=""

seed_autosquash_target() {
  # $1 = shell the hooks run under. Builds the rebase root and a REFERENCE-FREE
  # target ON `main` (see #675: a target built on the numbered branch already
  # carries `(#605)`, and the already-referenced guard would then suppress the
  # append even on an unpatched hook, so the case would pass against the bug),
  # then moves onto the numbered branch.
  new_case_repo 'main' "$1"
  commit_with -m 'chore: base'
  commit_with -m 'fix: seed subject'
  TARGET_SUBJECT="${SUBJECT}"
  TARGET_SHA=$(git -C "${CASE_REPO}" rev-parse HEAD)
  git -C "${CASE_REPO}" checkout -q -b 'fix/605-converge-duplicate-tags'
}

REBASE_RC=0

assert_autosquash_collapses() {
  # $1 = label, $2 = the subject prefix that must NOT survive ("fixup!"/"squash!").
  local label="$1" survivor_prefix="$2" root_sha count_before count_after survivor_count
  root_sha=$(git -C "${CASE_REPO}" rev-list --max-parents=0 HEAD)
  count_before=$(git -C "${CASE_REPO}" rev-list --count HEAD)
  GIT_SEQUENCE_EDITOR=true GIT_EDITOR=true \
    git -C "${CASE_REPO}" rebase -i --autosquash "${root_sha}" >/dev/null 2>&1
  REBASE_RC=$?
  if [ "${REBASE_RC}" -ne 0 ]; then
    git -C "${CASE_REPO}" rebase --abort >/dev/null 2>&1
    bad "${label}: git rebase --autosquash exited ${REBASE_RC}"
    return
  fi
  ok "${label}: git rebase --autosquash succeeded"
  count_after=$(git -C "${CASE_REPO}" rev-list --count HEAD)
  if [ "${count_after}" -eq $((count_before - 1)) ]; then
    ok "${label}: history shrank by one (${count_before} -> ${count_after})"
  else
    bad "${label}: history is ${count_after} commit(s), expected $((count_before - 1)) — the fixup did not squash"
  fi
  # grep -c, reading the count — never the pipeline status (the #682 SIGPIPE
  # trap under set -o pipefail).
  survivor_count=$(git -C "${CASE_REPO}" log --pretty=%s | grep -c "^${survivor_prefix} ")
  if [ "${survivor_count}" -ne 0 ]; then
    bad "${label}: ${survivor_count} '${survivor_prefix}' subject(s) survived the rebase"
  else
    ok "${label}: no '${survivor_prefix}' subject survived"
  fi
  # AC #5: the combined commit must keep the target's subject byte-identical —
  # the detached HEAD during rebase is what stops a reference being injected
  # into it. Checked against the TARGET subject specifically, not the whole log:
  # an ordinary `(#605)` commit deliberately sits alongside the fixup, and it is
  # supposed to carry the reference. grep -Fc (fixed string, read the count) so
  # the target's own `:` and spaces are not read as a pattern, and so the
  # pipeline's SIGPIPE never surfaces as the status (#682).
  local injected_count
  injected_count=$(git -C "${CASE_REPO}" log --pretty=%s | grep -Fc "${TARGET_SUBJECT} (#605)")
  if [ "${injected_count}" -ne 0 ]; then
    bad "${label}: a reference was injected into the target subject during the rebase"
  else
    ok "${label}: the target subject gained no reference during the rebase"
  fi
}

# ----- Cases ----------------------------------------------------------------
# A seed subject deliberately free of digits, so the only thing that can put a
# number in the subject is the hook.
SEED_SUBJECT='feat: add the thing'

for hook_shell in ${HOOK_SHELLS}; do

  # --- AC #1: the editor path now gets the reference, at parity with -m ---

  start_case "editor (${hook_shell}): a typed subject gains the branch reference"
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  commit_with_editor "${EDITOR_WRITE}" "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, editor append" "${SEED_SUBJECT} (#605)"

  start_case "parity (${hook_shell}): editor and -m produce the same subject"
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, -m append" "${SEED_SUBJECT} (#605)"

  # --- AC #2: one shared contract, exercised through the editor ---

  start_case "contract (${hook_shell}): editor-authored subjects follow the same branch shapes"

  new_case_repo 'reviews/586' "${hook_shell}"
  commit_with_editor "${EDITOR_WRITE}" "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, editor reviews/586" "${SEED_SUBJECT} (#586)"

  new_case_repo 'issue-458/global-capture-fab' "${hook_shell}"
  commit_with_editor "${EDITOR_WRITE}" "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, editor issue-458/global-capture-fab" "${SEED_SUBJECT} (#458)"

  new_case_repo '605-add-login' "${hook_shell}"
  commit_with_editor "${EDITOR_WRITE}" "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, editor 605-add-login" "${SEED_SUBJECT} (#605)"

  new_case_repo 'JVS-123' "${hook_shell}"
  commit_with_editor "${EDITOR_WRITE}" "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, editor JVS-123" "${SEED_SUBJECT} (#123)"

  # Shapes that must yield nothing, also via the editor.
  new_case_repo 'review-655' "${hook_shell}"
  commit_with_editor "${EDITOR_WRITE}" "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, editor review-655" "${SEED_SUBJECT}"

  new_case_repo 'worktree-agent-a0c916b19a98a11ae' "${hook_shell}"
  commit_with_editor "${EDITOR_WRITE}" "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, editor worktree-agent-<hex>" "${SEED_SUBJECT}"

  new_case_repo 'fix/0028-ambiguous-parameter' "${hook_shell}"
  commit_with_editor "${EDITOR_WRITE}" "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, editor fix/0028-ambiguous-parameter" "${SEED_SUBJECT}"

  new_case_repo 'feat/login-registration-ui-94' "${hook_shell}"
  commit_with_editor "${EDITOR_WRITE}" "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, editor feat/login-registration-ui-94" "${SEED_SUBJECT}"

  new_case_repo 'main' "${hook_shell}"
  commit_with_editor "${EDITOR_WRITE}" "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, editor main" "${SEED_SUBJECT}"

  # --- AC #3: already-referenced is not doubled ---

  start_case "guard (${hook_shell}): an editor subject already carrying the reference is not doubled"
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  commit_with_editor "${EDITOR_WRITE}" "${SEED_SUBJECT} (#605)"
  assert_subject "${hook_shell}, editor already referenced" "${SEED_SUBJECT} (#605)"

  start_case "guard (${hook_shell}): a -m subject already carrying the reference is not doubled"
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  commit_with -m "${SEED_SUBJECT} (#605)"
  assert_subject "${hook_shell}, -m already referenced" "${SEED_SUBJECT} (#605)"

  start_case "guard (${hook_shell}): a reference to a DIFFERENT issue is not stacked on"
  # The trailing-reference guard. A subject ending in some other issue's
  # reference must not gain this branch's on top of it.
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  commit_with -m 'feat: carried over (#500)'
  assert_subject "${hook_shell}, trailing reference to #500" 'feat: carried over (#500)'

  start_case "guard (${hook_shell}): amending across branches does not stack a second reference"
  # The cross-branch doubling regression (#679). A commit authored on one
  # numbered branch, amended on another, keeps its original reference and does
  # NOT gain the new branch's.
  new_case_repo 'fix/605-a' "${hook_shell}"
  commit_with -m 'feat: work'
  assert_subject "${hook_shell}, authored on fix/605-a" 'feat: work (#605)'
  git -C "${CASE_REPO}" checkout -q -b 'fix/999-b'
  commit_with --amend --no-edit
  assert_subject "${hook_shell}, amended on fix/999-b" 'feat: work (#605)'

  # --- AC #4: quitting the editor still ABORTS, across the config matrix ---
  # The abort here is the conventional-format validation rejecting a
  # comments-only file — not git's empty-message check. All six cells must
  # record zero commits.

  start_case "editor (${hook_shell}): quitting without saving aborts (default config)"
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  commit_with_editor "${EDITOR_QUIT}" ''
  assert_nothing_committed "${hook_shell}, quit, default"

  start_case "editor (${hook_shell}): quitting aborts under commit.verbose"
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  git -C "${CASE_REPO}" config commit.verbose true
  printf 'hello\n' > "${CASE_REPO}/f.txt"
  git -C "${CASE_REPO}" add f.txt
  commit_with_editor "${EDITOR_QUIT}" ''
  assert_nothing_committed "${hook_shell}, quit, commit.verbose"

  start_case "editor (${hook_shell}): quitting aborts under core.commentChar"
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  git -C "${CASE_REPO}" config core.commentChar ';'
  commit_with_editor "${EDITOR_QUIT}" ''
  assert_nothing_committed "${hook_shell}, quit, core.commentChar=';'"

  start_case "editor (${hook_shell}): quitting aborts under core.commentChar + commit.verbose"
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  git -C "${CASE_REPO}" config core.commentChar ';'
  git -C "${CASE_REPO}" config commit.verbose true
  printf 'hello\n' > "${CASE_REPO}/f.txt"
  git -C "${CASE_REPO}" add f.txt
  commit_with_editor "${EDITOR_QUIT}" ''
  assert_nothing_committed "${hook_shell}, quit, commentChar + verbose"

  start_case "editor (${hook_shell}): quitting aborts under core.commentString"
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  if [ "${COMMENT_STRING_SUPPORTED}" = yes ]; then
    git -C "${CASE_REPO}" config core.commentString '//'
    commit_with_editor "${EDITOR_QUIT}" ''
    assert_nothing_committed "${hook_shell}, quit, core.commentString='//'"
  else
    skip "${hook_shell}, quit, core.commentString: unsupported by $(git --version)"
  fi

  start_case "editor (${hook_shell}): quitting aborts under core.commentString + commit.verbose"
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  if [ "${COMMENT_STRING_SUPPORTED}" = yes ]; then
    git -C "${CASE_REPO}" config core.commentString '//'
    git -C "${CASE_REPO}" config commit.verbose true
    printf 'hello\n' > "${CASE_REPO}/f.txt"
    git -C "${CASE_REPO}" add f.txt
    commit_with_editor "${EDITOR_QUIT}" ''
    assert_nothing_committed "${hook_shell}, quit, commentString + verbose"
  else
    skip "${hook_shell}, quit, core.commentString + verbose: unsupported by $(git --version)"
  fi

  # --- AC #4 companion: a non-conventional subject typed in the editor is
  # still rejected, exactly as it is on the -m path. ---
  start_case "editor (${hook_shell}): a non-conventional typed subject is rejected"
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  commit_with_editor "${EDITOR_REPLACE}" 'just some words'
  assert_nothing_committed "${hook_shell}, non-conventional editor subject"

  # --- Validation reads the SUBJECT, not the whole file ---
  start_case "validation (${hook_shell}): a conventional BODY line does not rescue a non-conventional subject"
  # Validation greps the first non-blank line, not the whole message, so a
  # Conventional-Commits-shaped line in the body cannot let a bad subject
  # through (and cannot then acquire a reference).
  new_case_repo 'fix/605-x' "${hook_shell}"
  commit_with -m 'wip messing around' -m 'fix: only in the body'
  assert_nothing_committed "${hook_shell}, conventional body, non-conventional subject"

  start_case "validation (${hook_shell}): a hand-typed amend! subject passes validation and stays verbatim"
  # `amend!` is an accepted prefix alongside `fixup!`/`squash!` (git authors it
  # for --fixup=amend:/reword:), so it passes validation on its own first line
  # — with no conventional body to lean on — and append_issue_reference leaves
  # it untouched.
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  commit_with -m 'amend! chore: tidy imports'
  assert_subject "${hook_shell}, hand-typed amend! via -m" 'amend! chore: tidy imports'

  # --- AC #5: -m, merge, squash, amend behave as before ---

  start_case "merge (${hook_shell}): a conventional merge subject is left alone"
  # The MERGE_HEAD guard. `chore: merge side` passes validation (a plain
  # `Merge branch ...` does not, and is rejected as it is today), so without
  # the guard it would gain a reference. It must not.
  new_case_repo 'fix/605-x' "${hook_shell}"
  commit_with -m 'chore: seed'
  git -C "${CASE_REPO}" checkout -q -b side
  printf 'side\n' > "${CASE_REPO}/side.txt"
  git -C "${CASE_REPO}" add side.txt
  git -C "${CASE_REPO}" commit -q -m 'chore: side'
  git -C "${CASE_REPO}" checkout -q 'fix/605-x'
  printf 'trunk\n' > "${CASE_REPO}/trunk.txt"
  git -C "${CASE_REPO}" add trunk.txt
  git -C "${CASE_REPO}" commit -q -m 'chore: trunk'
  MERGE_OUT=$(git -C "${CASE_REPO}" merge --no-ff -m 'chore: merge side' side 2>&1)
  MERGE_RC=$?
  MERGE_SUBJECT=$(git -C "${CASE_REPO}" log -1 --pretty=%s)
  if [ "${MERGE_RC}" -eq 0 ]; then
    ok "${hook_shell}, merge: git merge succeeded"
  else
    bad "${hook_shell}, merge: git merge exited ${MERGE_RC}: ${MERGE_OUT}"
  fi
  if [ "${MERGE_SUBJECT}" = 'chore: merge side' ]; then
    ok "${hook_shell}, merge: subject untouched (\"${MERGE_SUBJECT}\")"
  else
    bad "${hook_shell}, merge: subject is \"${MERGE_SUBJECT}\", expected \"chore: merge side\""
  fi

  start_case "squash (${hook_shell}): a git merge --squash commit gets no reference"
  # The SQUASH_MSG guard. `git merge --squash` writes .git/SQUASH_MSG and stages
  # the change; the follow-up commit (editor path) must skip the append while
  # SQUASH_MSG is present — matching main, where prepare skips it too.
  new_case_repo 'fix/605-x' "${hook_shell}"
  commit_with -m 'chore: seed'
  git -C "${CASE_REPO}" checkout -q -b feature
  printf 'feat\n' > "${CASE_REPO}/feature.txt"
  git -C "${CASE_REPO}" add feature.txt
  git -C "${CASE_REPO}" commit -q -m 'chore: feature work'
  git -C "${CASE_REPO}" checkout -q 'fix/605-x'
  git -C "${CASE_REPO}" merge --squash feature >/dev/null 2>&1
  commit_with_editor "${EDITOR_REPLACE}" 'chore: squashed feature'
  assert_subject "${hook_shell}, merge --squash" 'chore: squashed feature'

  # --- Leading-blank subject (#679, blocker 5) ---
  start_case "editor (${hook_shell}): a subject typed below a blank line is referenced on its own line"
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  commit_with_editor "${EDITOR_WRITE_BELOW_BLANK}" 'feat: typed below blank'
  assert_subject "${hook_shell}, subject below blank line" 'feat: typed below blank (#605)'

  # --- Rebase reword on a detached HEAD (the ADR's load-bearing accident) ---

  start_case "rebase (${hook_shell}): rewording a referenced commit does not double its reference"
  new_case_repo 'fix/605-x' "${hook_shell}"
  printf 'a\n' > "${CASE_REPO}/a.txt"; git -C "${CASE_REPO}" add a.txt
  git -C "${CASE_REPO}" commit -q -m 'feat: one'
  printf 'b\n' > "${CASE_REPO}/b.txt"; git -C "${CASE_REPO}" add b.txt
  git -C "${CASE_REPO}" commit -q -m 'feat: two'
  GIT_SEQUENCE_EDITOR="${SEQ_REWORD_FIRST}" GIT_EDITOR=true \
    git -C "${CASE_REPO}" rebase -i HEAD~1 >/dev/null 2>&1
  REWORD_RC=$?
  REWORD_SUBJECT=$(git -C "${CASE_REPO}" log -1 --pretty=%s)
  if [ "${REWORD_RC}" -eq 0 ]; then
    ok "${hook_shell}, reword referenced: rebase succeeded"
  else
    bad "${hook_shell}, reword referenced: rebase exited ${REWORD_RC}"
    git -C "${CASE_REPO}" rebase --abort >/dev/null 2>&1
  fi
  if [ "${REWORD_SUBJECT}" = 'feat: two (#605)' ]; then
    ok "${hook_shell}, reword referenced: subject unchanged (\"${REWORD_SUBJECT}\")"
  else
    bad "${hook_shell}, reword referenced: subject is \"${REWORD_SUBJECT}\", expected \"feat: two (#605)\""
  fi

  start_case "rebase (${hook_shell}): rewording an unreferenced commit gains no reference (detached HEAD)"
  # The load-bearing case: seeded on `main` (unreferenced), reworded while
  # checked out on a numbered branch. Only the detached HEAD during rebase keeps
  # `feat: two` from gaining `(#605)` — this pins that accident.
  new_case_repo 'main' "${hook_shell}"
  printf 'a\n' > "${CASE_REPO}/a.txt"; git -C "${CASE_REPO}" add a.txt
  git -C "${CASE_REPO}" commit -q -m 'feat: one'
  printf 'b\n' > "${CASE_REPO}/b.txt"; git -C "${CASE_REPO}" add b.txt
  git -C "${CASE_REPO}" commit -q -m 'feat: two'
  git -C "${CASE_REPO}" checkout -q -b 'fix/605-x'
  GIT_SEQUENCE_EDITOR="${SEQ_REWORD_FIRST}" GIT_EDITOR=true \
    git -C "${CASE_REPO}" rebase -i HEAD~1 >/dev/null 2>&1
  REWORD_RC=$?
  REWORD_SUBJECT=$(git -C "${CASE_REPO}" log -1 --pretty=%s)
  if [ "${REWORD_RC}" -eq 0 ]; then
    ok "${hook_shell}, reword unreferenced: rebase succeeded"
  else
    bad "${hook_shell}, reword unreferenced: rebase exited ${REWORD_RC}"
    git -C "${CASE_REPO}" rebase --abort >/dev/null 2>&1
  fi
  if [ "${REWORD_SUBJECT}" = 'feat: two' ]; then
    ok "${hook_shell}, reword unreferenced: subject unchanged (\"${REWORD_SUBJECT}\")"
  else
    bad "${hook_shell}, reword unreferenced: subject is \"${REWORD_SUBJECT}\", expected \"feat: two\""
  fi

  # --- Missing lib: the feature degrades to a no-op, the commit still lands ---
  start_case "degrade (${hook_shell}): a missing lib still lets a conventional commit through"
  # Sourcing a special builtin that fails would abort under sh/dash and reject
  # the commit; the missing-lib guard bails before the `.` instead. Validation
  # still runs (it needs no lib), so a conventional -m commits with no reference.
  new_case_repo 'fix/605-x' "${hook_shell}"
  git -C "${CASE_REPO}" config core.hooksPath "$(hooks_dir_nolib_for "${hook_shell}")"
  commit_with -m 'feat: no lib present'
  assert_subject "${hook_shell}, missing lib" 'feat: no lib present'

  start_case "degrade (${hook_shell}): a missing lib does not disable validation"
  new_case_repo 'fix/605-x' "${hook_shell}"
  git -C "${CASE_REPO}" config core.hooksPath "$(hooks_dir_nolib_for "${hook_shell}")"
  commit_with -m 'not conventional at all'
  assert_nothing_committed "${hook_shell}, missing lib still validates"

  # --- Symlink layout: only resolver candidate 3 finds the lib ---
  start_case "resolver (${hook_shell}): the symlink hook layout still finds the shared lib"
  new_symlink_repo 'fix/605-x' "${hook_shell}"
  commit_with_editor "${EDITOR_WRITE}" "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, symlink layout" "${SEED_SUBJECT} (#605)"

  # --- Autosquash (#675): subjects git owns, collapsing cleanly ---

  start_case "autosquash (${hook_shell}): --fixup stays byte-identical, collapses, injects no reference"
  seed_autosquash_target "${hook_shell}"
  commit_with -m "${SEED_SUBJECT}"
  assert_subject "${hook_shell}, ordinary commit alongside a fixup" "${SEED_SUBJECT} (#605)"
  commit_with --fixup="${TARGET_SHA}"
  assert_subject "${hook_shell}, --fixup byte-identical" "fixup! ${TARGET_SUBJECT}"
  assert_autosquash_collapses "${hook_shell}, --fixup autosquash" 'fixup!'

  start_case "autosquash (${hook_shell}): --squash stays byte-identical and collapses"
  seed_autosquash_target "${hook_shell}"
  commit_with_editor "${EDITOR_QUIT}" '' --squash="${TARGET_SHA}"
  assert_subject "${hook_shell}, --squash byte-identical" "squash! ${TARGET_SUBJECT}"
  assert_autosquash_collapses "${hook_shell}, --squash autosquash" 'squash!'

  start_case "autosquash (${hook_shell}): --fixup=amend: and --fixup=reword: keep amend! verbatim"
  seed_autosquash_target "${hook_shell}"
  commit_with_editor "${EDITOR_QUIT}" '' --fixup=amend:"${TARGET_SHA}"
  assert_subject "${hook_shell}, --fixup=amend: byte-identical" "amend! ${TARGET_SUBJECT}"
  seed_autosquash_target "${hook_shell}"
  commit_with_editor "${EDITOR_QUIT}" '' --fixup=reword:"${TARGET_SHA}"
  assert_subject "${hook_shell}, --fixup=reword: byte-identical" "amend! ${TARGET_SUBJECT}"

  start_case "autosquash (${hook_shell}): a hand-typed fixup! subject is left verbatim"
  new_case_repo 'fix/605-converge-duplicate-tags' "${hook_shell}"
  commit_with -m 'fixup! chore: tidy imports'
  assert_subject "${hook_shell}, hand-typed fixup! via -m" 'fixup! chore: tidy imports'

done

report
