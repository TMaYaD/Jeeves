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
vm() { ssh -o BatchMode=yes "${_opts[@]}" "$BUILDER_SSH" "$@"; }
vm 'rm -rf ~/jb-selftest && mkdir -p ~/jb-selftest && cat > ~/jb-selftest/jeeves-build && chmod +x ~/jb-selftest/jeeves-build' < "$SCRIPT"

# End the sshd session serving the command matching $1 — only that session.
# This is what sshd does itself when a caller disconnects. Some user-mode NAT
# setups never pass the disconnect through to the server, so the test does it
# explicitly rather than depending on the network in between.
drop_session() {
  vm "p=\$(pgrep -u \$USER -n -f '^sleep $1\$'); while [ -n \"\$p\" ] && [ \"\$p\" -gt 1 ]; do p=\$(ps -o ppid= -p \$p | tr -d ' '); case \$(ps -o comm= -p \$p) in sshd*) kill \$p; exit 0;; esac; done; exit 1" </dev/null
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
# ...and a dropped ssh connection releases it.
vm "$JB --no-sync -- 'sleep 30'" </dev/null >/dev/null 2>&1 &
holder=$!; sleep 3; drop_session 30; wait $holder 2>/dev/null
vm "$JB --no-sync --wait 15 -- true" </dev/null >/dev/null 2>&1; check "dropped connection releases the lock" 0 $?
left=$(vm 'pgrep -u "$USER" -f "^sleep 30$" | wc -l' </dev/null | tr -d ' ')
check "dropped connection stops the build" 0 "$left"

# Callers that wrap the command in a shell (cd && ...) must get the same protection.
vm "cd /tmp && $JB --no-sync -- 'sleep 31'" </dev/null >/dev/null 2>&1 &
holder=$!; sleep 3; drop_session 31; wait $holder 2>/dev/null
vm "$JB --no-sync --wait 15 -- true" </dev/null >/dev/null 2>&1; check "dropped connection via wrapper shell releases the lock" 0 $?

# A real exit status still comes back through the job wait.
vm "$JB --no-sync -- 'exit 7'" </dev/null >/dev/null 2>&1; check "exit code passthrough via job" 7 $?

echo "passed=$pass failed=$fail"
