# Jeeves — Infrastructure

Local development stack using Docker Compose, the server-version computation
Backend CD runs (`ci/`), and the `jeeves-builder` Android build VM.

## Services

| Service    | Port  | Description                                        |
|------------|-------|----------------------------------------------------|
| postgres   | 5432  | PostgreSQL — the op log and the server-owned tables |
| backend    | 8000  | FastAPI service                                    |
| redis      | 6379  | Auth nonce/rate-limit counters, escrow and member-auth state |

## Start

```bash
cd infra
# Optional: set a custom secret key (defaults to insecure-dev-key for local dev)
export SECRET_KEY=your-dev-secret
docker compose up -d
```

## Run migrations

```bash
cd backend
alembic upgrade head
```

## Verify the backend is up

```bash
curl http://localhost:8000/health
```

The response carries the running `SERVER_VERSION` — the check that distinguishes
"deployed" from "working" after a release.

## Stop

```bash
docker compose down
# To also remove volumes (destroys data):
docker compose down -v
```

## One-time PowerSync replication-slot cleanup

Alembic 0034 drops the `powersync` publication, but a publication and a
replication slot are separate objects: `DROP PUBLICATION` leaves the slot
behind, and destroying the PowerSync Dokku app does not drop it either. An
orphaned logical slot has no consumer and reserves WAL for ever, so it must be
dropped by hand — once per database that ever ran PowerSync.

**Production**, immediately after the deploy that carries 0034 (the Dokku
Postgres service still runs `wal_level=logical`, so the drop needs no restart):

```bash
dokku postgres:connect jeeves-db
```

```sql
SELECT slot_name, wal_status, pg_size_pretty(
  pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots;
SELECT pg_drop_replication_slot('powersync');
```

**Local dev** with a persisted `postgres_data` volume needs the extra step,
because this stack's compose no longer passes `wal_level=logical`: Postgres
refuses to start while a logical slot exists under a lower `wal_level`, exiting
with `FATAL: logical replication slot "powersync" exists, but "wal_level" <
"logical"`. Bring it up once on the old setting, drop the slot, then go back:

```bash
podman compose run --rm --no-deps -d --name pg-slotfix postgres \
  postgres -c wal_level=logical -c max_replication_slots=10
timeout 30 bash -c \
  'until podman exec pg-slotfix pg_isready -U jeeves -d jeeves >/dev/null 2>&1; do sleep 1; done' \
  || { echo "pg-slotfix did not become ready within 30s" >&2; podman rm -f pg-slotfix; exit 1; }
podman exec pg-slotfix psql -U jeeves -d jeeves \
  -c "SELECT pg_drop_replication_slot('powersync')"
podman rm -f pg-slotfix
podman compose up -d postgres
```

Volumes created after #556 never had a slot; `podman compose down -v` followed by
a fresh `up` is the other way out in dev, and destroys all data.

## Recovering from schema/version drift

**Symptom:** the backend container crash-loops and `podman compose logs backend`
shows a "Schema/version drift detected" message (from `python -m app.migrate`,
the startup migration runner) or a raw `DuplicateColumnError` /
`DuplicateTableError`.

This happens when the persisted `postgres_data` volume's schema no longer
matches the revision recorded in its `alembic_version` table — e.g. after
switching branches or worktrees with divergent migration histories. The runner
deliberately never auto-stamps the version table (see
`docs/adr/0012-no-auto-stamp-on-migration-drift.md`): a schema that merely
looks migrated may genuinely be behind, and stamping it would silently skip
migrations.

Inspect the recorded revision:

```bash
podman compose exec postgres psql -U jeeves -c "SELECT version_num FROM alembic_version"
```

Recovery options, in order of preference:

1. **Stamp the revision the database actually matches.** Take a backup first:

   ```bash
   podman compose exec postgres pg_dump -U jeeves jeeves > jeeves-backup.sql
   ```

   Then verify — for every migration up to and including the revision you
   intend to stamp — that both its schema changes *and* its data effects
   (backfills, data moves) are already present in the database; comparing
   schema alone can stamp past an unapplied data migration. Only after that
   review, record the revision without re-running migrations:

   ```bash
   cd backend && alembic stamp <revision>
   ```

   Restarting the backend then applies only the genuinely pending migrations.

2. **Reset the volume** (dev only — **destroys all data**):

   ```bash
   podman compose down -v
   ```

## The `jeeves-builder` Android build VM

A VirtualBox guest on the Mac that runs the Android toolchain the host cannot:
Ubuntu 24.04, 2 vCPU, 4 GB RAM, Temurin JDK 17 at `~/jdk17`, Android SDK at
`~/Android/sdk`, Flutter at `~/flutter`. Both versions track the pins CI uses —
`java-version: 17` in the workflows and `app/.fvmrc` for Flutter — so a mismatch
here means one of those moved.

### Start, stop, reach

```bash
VBoxManage startvm jeeves-builder --type headless   # SSH normally answers in ~20s
ssh -i ~/.ssh/id_ed25519 -p 2222 paperclipai@127.0.0.1
VBoxManage controlvm jeeves-builder acpipowerbutton  # graceful shutdown
```

SSH arrives through a NAT port-forward on host port 2222; there is no other
route in. `VBoxManage controlvm jeeves-builder savestate` is **not** a stop —
a saved VM resumes rather than boots, so cloud-init never re-runs and
`VBoxManage list runningvms` omits it while it sits saved.

The guest trusts the host key in `~/.ssh/id_ed25519` because the cloud-init seed
ISO carries its public half. Regenerating that host key locks the VM out, and
re-seeding does not fix it: cloud-init skips `users:` for a user that already
exists, so a replacement key has to be installed from `runcmd`.

### Memory cap and rollback

The VM runs at **4096 MB** with its 8 GB guest swapfile. VirtualBox commits the
whole cap to the host at boot, so the configured cap drops 4 GB from the original 8 GB on
the 16 GB host; the host-memory recovery itself was not measured. Two rounds of integer-GB search from 2 to 6 GB, on
commit `0a4951f` with real profile APK builds, set the number.

**Guest heap setting.** The guest's `~/.gradle/gradle.properties` holds two
lines and nothing else:

```
org.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=4G -XX:ReservedCodeCacheSize=512m -XX:+HeapDumpOnOutOfMemoryError
kotlin.daemon.jvmargs=-Xmx1g
```

It caps the Gradle and Kotlin daemons at 2 GB and 1 GB. The repository allows
each daemon 8 GB (the Kotlin daemon inherits it), and the first round showed the
idle daemons holding 2.8 to 4.1 GB at every cap, which paged out and back in on
every second build. The file lives only in the guest: a rebuilt VM needs it
recreated, and the repository's own `-Xmx8G` is unchanged for CI and developers.
If a Java `OutOfMemoryError` appears on a guest that is not short of memory,
raise these two `-Xmx` values, not the cap.

**How the cap was measured.** A series is one fresh boot at a cap, then three
clean builds with Gradle's build cache off: A on new daemons, B and C warm on the
same daemon (the builder keeps its daemon between builds). A build passed when it
completed, nothing was killed for memory, memory stall time stayed at or under
10% (`some`) and 5% (`full`), and wall time stayed within 1.5 times the 6 GB
baseline's when host CPU and memory probes were sane before and after. The
baseline's warm builds took 360.5 s on average, so the warm limit was 540.75 s.
Swap-in is recorded, not judged. The per-build table is in the pull request
description.

At 4 GB, two of three series passed; the failing one missed only wall time while
the host's CPU share dipped. One 3 GB series failed on warm build time with sane
probes; the other had no probes between builds, so its slow builds are not counted
as a failure and the 3 GB result rests on one series. 2 GB failed. No build had an
OOM kill, and the worst stall at 4 GB was 5.6% `some`. A 4 GB warm build swaps 0.6
to 1.1 GB; the swapfile sits on the Mac's own disk, so this costs the host some
disk traffic.

**What this does not show.** One pinned commit and the APK build only (not
`flutter test`); wall time moves with host load; only host CPU was probed, not
host swap traffic or memory pressure, per build; the builder lock was not held
continuously during the experiment.

**Raise the cap** by 1 GB if a build shows an OOM kill, a stopped daemon or
memory stall above the limits, and check the build again.

**Rollback** to the former 6144 MB is one power transition. Take the builder lock
(`tools/builder_run.py`) and hold it through the idle check, shutdown, resize,
restart and verification, so no build starts in between. Check a one-minute guest
load below 0.5; wait up to 180 seconds for genuine `poweroff` after ACPI
shutdown. Do not force shutdown or use saved state.

```bash
VBoxManage controlvm jeeves-builder acpipowerbutton
# Poll showvminfo until VMState="poweroff" before proceeding.
VBoxManage modifyvm jeeves-builder --memory 6144
VBoxManage startvm jeeves-builder --type headless
```

Check SSH, guest memory and the 8 GB `/swapfile` after boot.

### Build

`~/.jeeves_env` exports `JAVA_HOME`, `ANDROID_HOME`/`ANDROID_SDK_ROOT` and
`PATH`, and is sourced from both `~/.bashrc` and `~/.profile`. The `.bashrc`
line sits *above* Ubuntu's non-interactive early-return, so `ssh host '<cmd>'`
gets the toolchain too — move it below and every non-login command loses `java`.

Fetch and push on the Mac; the VM compiles the source synced to it. Use a clean
export of a pinned commit when the host checkout is shared between runs. Sync
that tree first, or the build compiles whatever was synced last. The excludes keep `.git` out and leave the
guest's build output and caches alone, so the next build stays warm:

```bash
rsync -a --delete \
  --exclude=.git --exclude=build/ --exclude=.dart_tool/ --exclude=.gradle/ \
  -e 'ssh -p 2222 -i ~/.ssh/id_ed25519' \
  <mac-jeeves-checkout>/ paperclipai@127.0.0.1:~/jeeves/
```

Then, on the guest, the same command `pr-apk.yml` runs:

```bash
cd ~/jeeves/app
flutter pub get && \
  dart run build_runner build --delete-conflicting-outputs && \
  flutter build apk --profile --split-per-abi --target-platform android-arm64 --flavor dev
```

### How it compares to GitHub

Same command, same Flutter and JDK, against `pr-apk.yml`'s `build-and-distribute`
job (which restores Gradle and pub caches, so its APK step is always warm):

| Step | GitHub | VM, cold | VM, warm |
|------|-------:|---------:|---------:|
| `flutter pub get` | 5s | 23s | — |
| `dart run build_runner build` | 45s | 59s | — |
| `flutter build apk …` | 118s | 3,123s | 110s |

**Warm, the VM matches GitHub.** The 26× gap is cold-cache work — downloading the
Gradle distribution, resolving dependencies, installing CMake and dexing every
external library — not throughput, and Dart-side work is only ~1.3× slower even
cold. So the thing to protect is the Gradle cache and daemon: leave the VM
running between builds rather than starting clean. The cold column is a first
build on empty caches, separate from the clean rebuilds measured above.
Treat all three columns as ceilings rather than benchmarks
anyway; the host is a dual-core i5 shared with the agent fleet, and when it
runs short of memory it swaps, which stops the guest for tens of seconds at a
time. The guest's own CPU share holds up through that — measured at 92–98% of
a core with steal time at zero — so a slow timing here says more about what
else the Mac was doing than about the VM.

### Two traps

**The NIC must stay `virtio`.** The emulated E1000 reset large transfers
mid-stream, which is what made this VM look unusable — `flutter --version` died
on its `git fetch --tags`. `VBoxManage modifyvm jeeves-builder --nictype1 virtio`
fixes it, and needs the VM powered off (port-forward edits do not; adapter
changes do). When diagnosing a stalled download, check a second host before
blaming the NIC: `cloud-images.ubuntu.com` throttles to near-zero here while
`dl.google.com` saturates the link.

**`cmdline-tools/latest` is pinned to 19.0 deliberately.** Revision 23.0
replaces `sdkmanager` with the new Android CLI, which dropped `--licenses`;
Flutter still shells out to it and reports "Android license status unknown"
against an SDK whose licences are fine. 19.0 keeps the real `sdkmanager`, so
`flutter doctor --android-licenses` works. The newer CLI is kept alongside at
`cmdline-tools/23.0`.

`flutter doctor` is clean apart from Chrome, which is absent on purpose — this
guest builds Android, not web.

## Backend CD

`.github/workflows/backend-cd.yml` runs on every successful Backend CI on
`main`:

1. A freshness check — skip when `workflow_run.head_sha` is no longer `main`'s
   tip. Two Backend CI runs finish in whatever order their test jobs take, so a
   *successful* run need not be the *latest*; deploying a superseded one would
   force-push older code over migrations that have already run. The run for the
   newer commit deploys it.
2. `git push` to the Dokku remote, only when the commit touched `backend/`.
   Dokku's release phase runs `python -m app.migrate` (Alembic) before the new
   container takes traffic, and the push blocks until that finishes.

Migrations are therefore never hand-run, and a merge to `main` is a deploy.
There is no separate sync-rules publish step: the op log ships as ordinary
backend code (ADR-0026), so schema and sync behaviour move in the same push.

`ci/compute-server-version.sh` derives the version that push injects as
`SERVER_VERSION`, from the conventional commits since the last `server/` tag
A `!` commit or `BREAKING CHANGE:` footer bumps the inner major.
Its test harness is `ci/tests/test-compute-server-version.sh`, run by Backend
CI's `infra-shell` job alongside `shellcheck`.
