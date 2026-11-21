#!/usr/bin/env bash
# Self-test for jeeves-build against an isolated tree and lock on a builder.
# Leaves the builder's real checkout and lock alone; uses cheap commands only.
#
#   BUILDER_SSH=<ssh destination> selftest.sh <jeeves-build script> <jeeves repo dir>
#
# Extra ssh options (port, key) can go in BUILDER_SSH_OPTS.
set -u
SCRIPT=$1; REPO=$2
: "${BUILDER_SSH:?set BUILDER_SSH to the builder (an ssh destination or alias)}"
read -r -a _opts <<< "${BUILDER_SSH_OPTS:-}"
SSH=(ssh -o BatchMode=yes "${_opts[@]}" "$BUILDER_SSH")
vm() { "${SSH[@]}" "$@"; }
vm 'rm -rf ~/jb-selftest && mkdir -p ~/jb-selftest && cat > ~/jb-selftest/jeeves-build && chmod +x ~/jb-selftest/jeeves-build' < "$SCRIPT"

# Start a caller and kill its ssh client outright, as when an agent run is
# killed mid-build. The ssh process itself is backgrounded (not a function
# wrapping it), so $! is the real client.
# Checks first that the caller really holds the lock, so a later "lock
# released" pass cannot be vacuous.
kill_caller_during() {
  "${SSH[@]}" "$1" </dev/null >/dev/null 2>&1 &
  local client=$!
  sleep 3
  vm "$JB --no-sync --wait 1 -- true" </dev/null >/dev/null 2>&1
  check "  (caller holds the lock before it is killed)" 75 $?
  kill -9 "$client"
  wait "$client" 2>/dev/null
}
JB='env JEEVES_BUILD_TREE=$HOME/jb-selftest/tree JEEVES_BUILD_LOCK=$HOME/jb-selftest/lock JEEVES_BUILD_STAGE=$HOME/jb-selftest/stage $HOME/jb-selftest/jeeves-build'
cd "$REPO"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1 (want $2, got $3)"; fail=$((fail+1)); fi; }

vm "$JB --no-sync" </dev/null >/dev/null 2>&1;            check "no command -> 64" 64 $?
vm "$JB --no-sync -- true" </dev/null >/dev/null 2>&1;     check "--no-sync before any tree -> 65" 65 $?
git archive --format=tar HEAD | vm "$JB -- 'test -f pubspec.yaml'" >/dev/null 2>&1; check "first sync + command -> 0" 0 $?

vm 'mkdir -p ~/jb-selftest/tree/app/build ~/jb-selftest/tree/app/.dart_tool && touch ~/jb-selftest/tree/app/build/WARM ~/jb-selftest/tree/app/.dart_tool/WARM' </dev/null
before=$(vm 'stat -c %Y ~/jb-selftest/tree/app/pubspec.yaml' </dev/null)
sleep 2
git archive --format=tar HEAD | vm "$JB -- 'test -f build/WARM && test -f .dart_tool/WARM'" >/dev/null 2>&1; check "resync keeps build/ and .dart_tool/" 0 $?
after=$(vm 'stat -c %Y ~/jb-selftest/tree/app/pubspec.yaml' </dev/null)
check "unchanged file keeps its mtime" "$before" "$after"

# A file removed from the source must disappear from the tree.
vm 'touch ~/jb-selftest/tree/app/STALE_FROM_OLD_BRANCH' </dev/null
git archive --format=tar HEAD | vm "$JB -- 'test ! -e STALE_FROM_OLD_BRANCH'" >/dev/null 2>&1; check "stale files are deleted" 0 $?

vm "$JB --no-sync -- 'exit 3'" </dev/null >/dev/null 2>&1; check "exit code passthrough" 3 $?
tar -cf - -C /etc hosts | vm "$JB -- true" >/dev/null 2>&1;  check "non-Jeeves stream -> 65" 65 $?

# Lock: a holder blocks a second caller...
vm "$JB --no-sync -- 'sleep 8'" </dev/null >/dev/null 2>&1 &
sleep 3
vm "$JB --no-sync --wait 2 -- true" </dev/null >/dev/null 2>&1; check "second caller waits, then 75" 75 $?
wait
# ...but a daemon left behind by a build must not keep the lock.
vm "$JB --no-sync -- 'nohup sleep 20 >/dev/null 2>&1 & true'" </dev/null >/dev/null 2>&1
vm "$JB --no-sync --wait 2 -- true" </dev/null >/dev/null 2>&1; check "leftover daemon does not hold the lock" 0 $?
# ...and a caller killed mid-build releases it and stops its build.
kill_caller_during "$JB --no-sync -- 'sleep 30'"
vm "$JB --no-sync --wait 15 -- true" </dev/null >/dev/null 2>&1; check "killed caller releases the lock" 0 $?
left=$(vm 'pgrep -u "$USER" -f "^sleep 30$" | wc -l' </dev/null | tr -d ' ')
check "killed caller's build is stopped" 0 "$left"

# Callers that wrap the command in a shell (cd && ...) must get the same protection.
kill_caller_during "cd /tmp && $JB --no-sync -- 'sleep 31'"
vm "$JB --no-sync --wait 15 -- true" </dev/null >/dev/null 2>&1; check "killed caller via wrapper shell releases the lock" 0 $?

# A real exit status still comes back through the job wait.
vm "$JB --no-sync -- 'exit 7'" </dev/null >/dev/null 2>&1; check "exit code passthrough via job" 7 $?

echo "passed=$pass failed=$fail"
