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
Ubuntu 24.04, 2 vCPU, 6 GB RAM, Temurin JDK 17 at `~/jdk17`, Android SDK at
`~/Android/sdk`, Flutter at `~/flutter`. Both versions track the pins CI uses —
`java-version: 17` in the workflows and `app/.fvmrc` for Flutter — so a mismatch
here means one of those moved.

### Start, stop, reach

```bash
VBoxManage startvm jeeves-builder --type headless   # SSH answers in ~20s
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

### The 2 vCPU / 6 GB caps, and how to change them

Both caps are deliberate, and both are held against a 4-core 16 GB host that the
agent fleet already oversubscribes. **VirtualBox commits the whole memory cap to
the host the moment the guest boots, not as the guest grows into it** — a
freshly-booted guest using 440 MB still costs the host the full cap. So the
number is not a ceiling the guest might one day reach; it is the rent, paid up
front, every boot. On a host with 16 GB that is the difference between the VM
taking a third and taking a half.

Changing either needs the VM genuinely powered off — `savestate` will not do,
and a running VM refuses:

```bash
VBoxManage controlvm jeeves-builder acpipowerbutton     # wait for poweroff
VBoxManage modifyvm jeeves-builder --memory 6144        # or --cpus 2
VBoxManage startvm jeeves-builder --type headless
```

To roll back to the previous 8 GB, run the same three lines with `--memory 8192`.

6 GB was sized off a measured build rather than guessed: the full `pr-apk.yml`
command peaks at **1.6 GB of anonymous memory and 3.4 GB including page cache,
with no swap**, so an ordinary build has most of a cache's worth of headroom.
The evidence would support 4 GB; what argues against it is `-Xmx8G` in
`app/android/gradle.properties`, which lets the Gradle daemon keep growing past
a 4 GB guest before it collects hard.

### Build

`~/.jeeves_env` exports `JAVA_HOME`, `ANDROID_HOME`/`ANDROID_SDK_ROOT` and
`PATH`, and is sourced from both `~/.bashrc` and `~/.profile`. The `.bashrc`
line sits *above* Ubuntu's non-interactive early-return, so `ssh host '<cmd>'`
gets the toolchain too — move it below and every non-login command loses `java`.

Then the same command `pr-apk.yml` runs:

```bash
cd ~/jeeves/app
flutter pub get && dart run build_runner build --delete-conflicting-outputs
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
running between builds rather than starting clean, and a `flutter clean` costs
close to an hour. Treat all three columns as ceilings rather than benchmarks
anyway; the host is a dual-core i5 that is CPU-oversubscribed, so a busy thread
sees a fraction of a core.

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
