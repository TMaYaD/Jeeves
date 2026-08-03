# shellcheck shell=sh

# Shared issue-reference contract for the commit-message hooks.
#
# This library is the one place the repo's branch-name -> issue-reference
# contract is written down. Two hooks source it, on the two paths git can take
# to build a subject:
#
#   * prepare-commit-msg — the `-m`/`-F` path, where git already holds the
#     message before any editor opens ($COMMIT_SOURCE = "message").
#   * commit-msg — the editor path, where the subject exists only AFTER the
#     editor closes, and $COMMIT_SOURCE is not passed to the hook at all.
#
# Because both callers land in append_issue_reference, the accepted branch
# shapes and the bare-digits output are ONE contract, not two drifting ones
# (#679). Every reason NOT to append that can be read from the file or the
# branch lives in this function, so a caller only decides whether its path is
# append-eligible at all (the merge/squash question commit-msg answers from
# MERGE_HEAD / SQUASH_MSG), never how to append.

# Prints a bare GitHub issue number, or nothing at all. Accepted branch shapes:
#
#   <type>/<number>[-<slug>]   fix/605-converge-duplicate-tags, reviews/586
#   issue-<number>/<slug>      issue-458/global-capture-fab
#   JVS-<number>[-<slug>]      JVS-123
#   <number>[-<slug>]          605-add-login
#
# The number is always anchored to the *start* of the last path segment, and
# what this prints is always bare digits — no prefix ever reaches the message,
# which is what makes `(#review-655)` and `(#proxy-3048)` structurally
# impossible rather than merely unlikely (#666).
#
# Three rules that look like they could be simplified away, and must not be:
#
#   * A leading zero disqualifies. GitHub issue numbers never carry one; this
#     repo's migration and ADR numbers always do, so `fix/0028-ambiguous-
#     parameter` would otherwise link commits to issue #28. It has to be an
#     anchor-adjacent example: `fix/alembic-0028-...` and `docs/...-adr-0044`
#     are already rejected by the anchor, before this rule is ever consulted.
#   * The `issue-*/*` arm must stay ABOVE the `*/*` arm. Swap them and
#     `issue-458/global-capture-fab` silently yields nothing.
#   * A trailing number is deliberately NOT accepted (`feat/login-ui-94`).
#     That convention was abandoned in April 2026, and the tail of a branch
#     name is exactly where versions, ADR numbers and dependabot bumps live.
#
# Known residuals, accepted and unguarded:
#
#   * A date-prefixed branch such as `chore/2026-08-audit` is structurally
#     identical to `<type>/<number>-<slug>` and appends `(#2026)`.
#     Distinguishing it needs a heuristic worse than the disease. Don't name
#     branches that way.
#   * The `-m` cleanup-mode residual, described at message_body below, is a
#     property of the `prepare-commit-msg` (`$COMMIT_SOURCE`=message) caller
#     only. On the editor path git cleans up with `strip`, which drops comment
#     lines exactly as this hook does, so the mismatch cannot arise there.
issue_number_from_branch() {
    branch=$1
    case $branch in
        JVS-*)     rest=${branch#JVS-} ;;
        issue-*/*) rest=${branch#issue-} ;;
        */*)       rest=${branch##*/} ;;
        *)         rest=$branch ;;
    esac
    number=${rest%%[!0-9]*}
    [ -n "$number" ] || return 1
    case $number in 0*) return 1 ;; esac
    # The digits must be followed by a separator or nothing — never by more
    # branch name, so `fix/605_underscore` is rejected rather than truncated.
    case ${rest#"$number"} in ''|-*|/*) ;; *) return 1 ;; esac
    printf '%s' "$number"
}

# Everything in the message file that git will keep as the message, given as an
# argument so either hook can pass its own $1. On the `-m` path a plain -m
# leaves the file holding nothing but the message, but `-m ... -e` (and the
# editor path) has git append its status block and, under commit.verbose, the
# staged diff. Two things are dropped:
#
#   * Everything from the scissors line down. Under `commit.verbose` git puts
#     the staged diff there, un-commented — so without this a `#605` inside the
#     diff reads as an existing reference and suppresses a legitimate append,
#     which is the one plausible way to lose a reference on this path.
#
#     Git's scissors line is comment-PREFIXED, so anchoring the trim on `#`
#     loses it the moment the comment character changes — and then the entire
#     diff is scanned. The pattern therefore matches the `---- >8 ----` run and
#     ignores whatever precedes it, which holds identically under `#`,
#     `core.commentChar`, `core.commentString` and `core.commentChar=auto`.
#   * Comment lines, so git's own `# On branch fix/605-...` status block is not
#     scanned for a reference. `git stripspace --strip-comments` is git's own
#     plumbing for exactly this: run in the repository, it reads
#     `core.commentChar` / `core.commentString` itself. Nothing is interpolated
#     into a pattern and no prefix is escaped — a hand-rolled
#     `grep -v "^$prefix"` would need both, because git's candidate list
#     contains `$`, which raw in a BRE is the end-of-line anchor and would
#     silently strip every blank line instead.
#
#     What that buys, concretely: under `core.commentChar=';'` on a branch
#     named `fix/605-#605`, git's own status line `; On branch fix/605-#605`
#     survived a hard-coded `^#` filter, and the guard below read the `#605`
#     in it as an existing reference — silently suppressing a legitimate
#     append. That needed no unusual message, only an unusual config.
#
#     `core.commentChar=auto` is the one spelling stripspace does not resolve:
#     it falls back to the default `#` rather than running git-commit's
#     per-message candidate scan. Measured on git 2.55: `-m '#605 subject' -e`
#     under `auto` makes git write its status block with `;`, while stripspace
#     strips the `#` line. So under `auto` this behaves exactly as the old
#     hard-coded `^#` did — no better, no worse — and reimplementing the
#     candidate scan is the only exact fix. `auto` is not a value anyone here
#     sets, and the residual runs the safe way (below).
#
#     If stripspace exits non-zero, this yields NO text, so the guard finds no
#     reference and the append proceeds. That direction is deliberate: this
#     function feeds only the already-referenced guard and never the message
#     that gets written, so its worst case is a visible duplicate `(#605)` in
#     the subject. Failing the other way would silently drop the reference the
#     hook exists to add, and silence is the failure mode #666 was filed for.
#
# The residual runs one way: scanning text git will discard can only ever
# SUPPRESS an append, never fabricate a commit. On the editor path the file
# holds only comments before the subject is typed, so its worst case there is
# the same suppression — and commit-msg never even reaches this function on a
# comments-only file, because the conventional-format validation rejects it
# first.
message_body() {
    stripped=$(sed -e '/-\{8,\} >8 -\{8,\}$/,$d' "$1" \
        | git stripspace --strip-comments 2>/dev/null) || return 0
    printf '%s\n' "$stripped"
}

# Appends `(#NNN)` to the commit subject when the branch names an issue and the
# message does not already carry the reference. Idempotent and caller-agnostic:
# every guard reads intrinsic state (the file's first non-blank line, the
# branch, the existing message), so prepare-commit-msg and commit-msg get the
# same answer on the same commit.
append_issue_reference() {
    file=$1

    # The subject is the first NON-BLANK line, not line 1. On the `-m` path
    # line 1 is always the subject, so this is line 1 there and prepare's
    # output is byte-for-byte what it always was. On the editor path a
    # developer may leave blank lines above the subject; git takes the first
    # non-blank line as the subject, and appending to line 1 there would strand
    # the reference on the blank line and corrupt the recorded subject (#679).
    subject=$(awk 'NF { print; exit }' "$file")

    # Guard: leave git's autosquash subjects byte-identical.
    #
    # `git commit --fixup <sha>`, `--squash <sha>`, `--fixup=amend:<sha>` and
    # `--fixup=reword:<sha>` reach prepare-commit-msg with $COMMIT_SOURCE =
    # "message" — the very value a plain `-m` produces — so its guard lets them
    # through. But git has built these subjects itself as `fixup! <target>` /
    # `squash! <target>` / `amend! <target>` (both amend: and reword: emit
    # `amend!`), and `git rebase --autosquash` matches them against the
    # target's subject byte-for-byte. Appending ` (#NNN)` breaks that match, so
    # the fixup never squashes and survives the rebase as a standalone commit
    # (#675). These are exactly the prefixes git's own autosquash recognises; a
    # subject shaped like one is git's to own, so leave it verbatim. Neither
    # caller's out-of-band signals ($COMMIT_SOURCE for prepare, none at all for
    # commit-msg) can tell these apart from `-m`/a hand-typed subject, so the
    # subject prefix is the only signal — and matching only these three
    # git-authored prefixes means a non-match costs nothing.
    case $subject in
        'fixup! '*|'squash! '*|'amend! '*) return 0 ;;
    esac

    # Branch -> issue number. On a detached HEAD — which is where git parks you
    # mid-rebase, including autosquash — `git symbolic-ref` fails, the branch is
    # empty, and no number is produced. That accident is what keeps a
    # rebase-reword/autosquash-combine from acquiring a spurious reference, so a
    # future git that stopped detaching HEAD there would need a real guard here.
    branch=$(git symbolic-ref --short HEAD 2>/dev/null)
    number=$(issue_number_from_branch "$branch")

    # Guard: the branch name carries no issue number. This is the silent,
    # successful no-op path — most ad-hoc and generated branches land here.
    [ -n "$number" ] || return 0

    # Guard: the message already references this issue. `#` is its own left
    # boundary and the right boundary is a non-digit or end of line, so `#605`
    # does not match `#6051`, and a bare `605` in prose does not match at all.
    # $number is digits by construction, so nothing regex-significant is
    # interpolated.
    if message_body "$file" | grep -qE "#${number}([^0-9]|$)"; then
        return 0
    fi

    # Guard: the subject already ends with a reference of this hook's own
    # shape. This is what stops a second `(#NNN)` stacking on when a commit
    # authored on one numbered branch is amended — or otherwise re-committed —
    # on another: the already-referenced guard above only looks for THIS
    # branch's number, so `feat: work (#605)` amended on `fix/999-b` would
    # otherwise become `feat: work (#605) (#999)` (#679). A `-m` subject that
    # genuinely ends in a hand-written `(#N)` is treated the same way, and not
    # doubled.
    if printf '%s\n' "$subject" | grep -qE ' \(#[0-9]+\)$'; then
        return 0
    fi

    # Append the reference to the end of the first non-blank line. A single awk
    # pass copies the file verbatim except for that one line; `d` fires once so
    # only the subject is touched. The temp file is created BESIDE the target,
    # not in $TMPDIR: $TMPDIR is often a different filesystem, where `mv` is a
    # copy-plus-unlink rather than an atomic rename — so a same-directory temp is
    # what makes the swap atomic and keeps a half-written file from ever being
    # seen. If the awk fails, or the mv fails, the temp is removed so a failed
    # write leaves nothing behind.
    tmp=$(mktemp "$file.XXXXXX") || return 0
    if awk -v ref=" (#${number})" '!d && NF { print $0 ref; d=1; next } { print }' \
        "$file" > "$tmp"; then
        mv "$tmp" "$file" || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
}
