# infra/builder — provision a Jeeves Android build machine

An Ansible playbook that turns any Ubuntu/Debian x86_64 machine — a VM, a
cloud instance, a spare box — into a machine that builds and tests the Jeeves
Flutter app, plus `jeeves-build`, the one entry point for running a build on
it. Use it when your own machine cannot run the Android toolchain, or should
not carry the load.

It knows nothing about any particular machine: no host names, addresses,
users, networks or hypervisors. Those belong to whoever runs it, in their own
inventory. Keep it that way — machine-specific setup does not go in this repo.

## Requirements

- Target: Ubuntu or Debian on x86_64, reachable by SSH as a user with sudo.
  About 15 GB of disk for the toolchain and caches; 8 GB RAM or more is
  comfortable.
- Controller: `ansible-core` (2.15+), run from a checkout of this repo — the
  playbook reads the Flutter version from `app/.fvmrc` and checks the SDK
  platforms against `compileSdk` in `app/android/app/build.gradle.kts`, so the
  machine always matches what CI builds.

## Provision

```sh
cat > ~/builder.ini <<'EOF'   # your inventory, outside the repo
[builder]
my-builder ansible_host=<address> ansible_user=<user>
EOF
ansible-playbook -i ~/builder.ini infra/builder/playbook.yml
```

A first run takes 20–30 minutes (Android SDK, NDK, Flutter). Re-running is
safe and changes nothing when the machine is already up to date; re-run it
after `app/.fvmrc` or `compileSdk` move.

What it installs, for the connecting user: Temurin JDK 17 (apt), the Android
SDK in `~/Android/sdk` (cmdline-tools pinned to 19.0 — see the defaults file
for why), Flutter in `~/flutter`, a toolchain env file sourced by both login
and non-interactive SSH shells, Gradle daemon heaps sized to the machine's
RAM, swap if the machine has none, and `/usr/local/bin/jeeves-build`.

Every `builder_*` default in `roles/jeeves_builder/defaults/main.yml` can be
overridden from your inventory (e.g. `builder_swapfile_size=""`,
`builder_gradle_xmx_gb=4`).

## Build

From a checkout, ship a source tree and run one command, as one locked step:

```sh
# a commit
git -C "$(git rev-parse --show-toplevel)" archive --format=tar HEAD \
  | ssh <builder> "jeeves-build -- 'flutter test test/path_test.dart'"

# the working tree, uncommitted and untracked files included (index untouched)
top=$(git rev-parse --show-toplevel) && idx=$(mktemp -u) \
  && GIT_INDEX_FILE=$idx git -C "$top" read-tree HEAD \
  && GIT_INDEX_FILE=$idx git -C "$top" add -A \
  && tree=$(GIT_INDEX_FILE=$idx git -C "$top" write-tree) && rm -f "$idx" \
  && git -C "$top" archive --format=tar "$tree" \
  | ssh <builder> "jeeves-build -- 'flutter pub get && flutter analyze'"
```

Quote the command twice, as above. `ssh` joins its arguments into one string
and the remote shell parses it again, so one layer of quotes is lost on the
way: with only `'…'`, a compound command such as `a && b` runs just `a`
under `jeeves-build`, and `b` runs afterwards in the login directory, outside
the lock.

`jeeves-build` holds one lock for sync *and* build, so concurrent callers
queue instead of overwriting each other's source mid-build. It rsyncs into
`~/jeeves/`, keeping `build/`, `.dart_tool/` and `~/.gradle` so builds stay
warm (a cold APK build is many times slower than a warm one), runs the command
in `~/jeeves/app` through a login shell, and stops the build if the caller's
SSH session ends, so an abandoned build cannot hold the machine.

Exit codes: the command's own; `64` usage; `65` not a Jeeves tree; `75` lock
wait timed out (nothing ran — retry). `ssh` itself exits `255` when the
machine is unreachable. `jeeves-build --help` has the details.

The commands to run are the project's own — the same ones CI runs, e.g.
`flutter pub get && dart run build_runner build --delete-conflicting-outputs && flutter test`.
CI stays the test of record.

## Test

`.github/workflows/builder-ci.yml` provisions a bare `ubuntu:24.04`
container as a non-default user, re-runs to check idempotence, and pushes
this repo through `jeeves-build`. `tests/selftest.sh` exercises
`jeeves-build` (lock, sync, warm-output preservation, exit codes, disconnect
handling) against a real builder:

```sh
BUILDER_SSH=<builder> bash infra/builder/tests/selftest.sh \
  infra/builder/roles/jeeves_builder/files/jeeves-build .
```
