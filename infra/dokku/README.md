# Jeeves — Dokku Production IaC

Two scripts, with different jobs:

| Script | When it runs | What it does |
|---|---|---|
| `publish-sync-config.sh` | every Backend CD, automatically | publishes `infra/powersync/sync-config.yaml` to the PowerSync app |
| `deploy-powersync.sh` | by hand, once per environment | bootstraps a PowerSync Dokku app from nothing |

Both are idempotent — safe to re-run at any time.

PowerSync is **product-scoped** — one instance per backend / source database.
Sync rules and JWT keys are tied to a single product, so multiple products
(jeeves, lease-manager, …) cannot share one PowerSync app. Name each
PowerSync app `<product>-powersync` (e.g. `jeeves-powersync`) to keep them
distinct on the same Dokku host. A future `dokku-powersync` plugin will
encode this convention as first-class commands ([#201][]).

[#201]: https://github.com/TMaYaD/Jeeves/issues/201

## Sync rules

`infra/powersync/sync-config.yaml` is the only place bucket definitions
exist. Local dev mounts it; production gets the same bytes as
`POWERSYNC_CONFIG_B64`, a Dokku config var, published by
`publish-sync-config.sh`. Nothing is mounted at `/config` in production —
see [ADR-0017](../../docs/adr/0017-sync-rules-as-dokku-config-var.md) for why
the config travels as an env var rather than a file.

For an **additive or backward-compatible** change — a new bucket, a widened
`SELECT`, a new column on a table clients already sync — editing that YAML and
merging to `main` is the whole procedure, with no manual step.

Changes that **remove or rename** something clients are syncing are the
exception: they need the two-phase, one-merge-per-phase procedure described
under [What this does and does not
guarantee](#what-this-does-and-does-not-guarantee) below. Publishing a bucket
removal in the same merge as the migration that drops its table takes the data
away from clients before they have anywhere else to read it.

```bash
# What CD runs, and what you can run by hand to force a republish:
DOKKU="ssh dokku@<dokku-host>" \
  infra/dokku/publish-sync-config.sh jeeves-powersync jeeves
```

The script compares the file against the published value and writes nothing
when they match, so a no-change deploy never restarts PowerSync.

Before it changes anything it resolves everything it needs to *verify* the
change: if it can't read the app's current config, can't tell whether the app
is deployed, or can't work out a readiness URL for one that is, it aborts while
there is still nothing to roll back. Then it sets the var — which restarts the
app — waits for a 2xx from `/probes/readiness`, and puts the previous state
back if readiness never comes. A redirect is not a 2xx: a vhost that has lost
its routing answers with one, and `curl -f` reports that as success.

Reading the current config goes through `config:keys`, not `config:get`, and
the reason is that `config:get` exits 1 both for a key that is not set and for
a lookup that failed. Treating the second as the first would let a transient
SSH error read as "nothing is set" — leaving a masking override in place, or
losing the value the rollback needs to restore. `config:keys` lists key names
(no values, so no secrets are pulled into the CI runner) and fails only when
dokku genuinely could not be reached. It is read once, before any write, so
every later presence question is answered against the app's pre-run state —
which is what the rollback paths want to know anyway.

PowerSync reads several config-delivery variables, and the script treats two
groups differently because they fail differently:

| Variable | Effect | When it's cleared |
|---|---|---|
| `POWERSYNC_SYNC_CONFIG_B64`, `POWERSYNC_SYNC_RULES_B64` | override the rules from *inside* the published config | **before** publishing |
| `POWERSYNC_CONFIG_PATH` | the mounted file the published config supersedes | **after** readiness passes |

The first group has to go first: while one is set the published rules are inert,
so publishing on top of it would change nothing and the probe would be
validating the wrong rules. Clearing one is itself a rules change, so it
restarts and re-probes even when the config is otherwise unchanged — that is
the one case where a "no-change" deploy legitimately restarts PowerSync. The
second is inert while our value is set, and is the only thing a first publish
can roll back to, so it survives until readiness passes.

Either way an override set by hand on the host heals on the next deploy instead
of persisting invisibly, and only keys that are actually set are touched.

## Backend CD

`.github/workflows/backend-cd.yml` runs on every successful Backend CI on
`main`, in this order:

1. A freshness check — skip everything below when `workflow_run.head_sha` is
   no longer `main`'s tip. Two Backend CI runs finish in whatever order their
   test jobs take, so a *successful* run need not be the *latest*; deploying a
   superseded one would force-push older code and republish older rules over
   migrations that have already run. The run for the newer commit deploys it.
2. `git push` to the Dokku remote — only when the commit touched `backend/`.
   Dokku's release phase runs `python -m app.migrate` (Alembic) before the new
   container takes traffic, and the push blocks until that finishes.
3. `publish-sync-config.sh` — always, regardless of what changed.

Migrations land before buckets, which is the order PowerSync's own
schema-change guidance prescribes. Both steps share one checkout pinned to
`workflow_run.head_sha`, so the rules published are always the rules from the
commit that was just deployed.

Backend CI's path filter includes `infra/powersync/**` and `infra/dokku/**`,
so an infra-only PR still reaches CD.

### What this does and does not guarantee

**Bounded, not atomic.** Between the migration finishing and the restarted
PowerSync serving the new rules there is a window of seconds to a couple of
minutes, plus reprocessing time. For a data-moving migration (`0026`-style,
rows relocated to a new table) users can see an empty surface during it. It
clears itself — the pre-automation version of this did not.

**Co-deployment, not consistency.** A PR that adds a migration and a table but
no bucket publishes an unchanged config and ships a table with nothing
replicating it. Nothing here catches that; review for it.

**Drops and renames need expand/contract, not a reordering.** The pipeline
publishes rules *after* migrations, which is right for additive changes and
wrong for removals — but "rules first" doesn't fix it either: rules naming a
column the migration hasn't created yet don't validate. The workable shape is
to never have the two disagree, by making every intermediate state valid on its
own. Renaming `todos.foo` to `todos.bar`:

| Merge | Migration | `sync-config.yaml` | State after |
|---|---|---|---|
| 1 | add `bar`, backfill from `foo`, keep `foo` | unchanged | both columns exist; rules still read `foo` |
| 2 | none | bucket selects `bar` and `foo` | clients sync both |
| 3 | none | drop `foo` from the bucket | nothing reads `foo` |
| 4 | drop `foo` | unchanged | rename complete |

Merges 3 and 4 are separate on purpose. Narrowing the bucket and dropping the
column in one merge means a published rule references a dropped column for as
long as the migration→publish window lasts. Splitting them keeps every
intermediate state valid on its own: after merge 3 the column exists but
nothing selects it, so merge 4 removes something already unused.

Two waits, neither of which a pipeline can automate. Between merges 2 and 3,
wait for clients to roll onto `bar` — an app version still reading `foo` breaks
when the bucket stops carrying it. Size that by how long you support old app
versions, not by how long PowerSync takes to reprocess. Between 3 and 4, wait
for the publish to land and PowerSync to finish reprocessing.

This procedure has not been exercised on this project yet — the sync rules have
only ever grown. Treat it as reasoned-through, not proven, and check the bucket
against the schema at each phase.

### Verifying a new synced table end-to-end

After merging a PR that adds a table (Drift schema + Alembic migration +
bucket in `sync-config.yaml`):

1. Watch the Backend CD run — the publish step should report
   `Publishing … → jeeves-powersync` rather than `sync config unchanged`.
2. `dokku logs jeeves-powersync --tail 100` on the host: no `SqlRuleError`.
3. On a signed-in client, create a row in the new table on device A and
   confirm it appears on device B.

## Fresh-environment bootstrap

`deploy-powersync.sh` sets up everything CI cannot: app creation, the postgres
link, `wal_level=logical`, domains, Let's Encrypt. Run it once per
environment, as root on the Dokku host. It needs the whole `infra/` directory,
not just the script — it reads `infra/powersync/sync-config.yaml` and calls
`publish-sync-config.sh`:

```bash
scp -r infra/ root@<dokku-host>:/root/jeeves-infra/
ssh root@<dokku-host> bash /root/jeeves-infra/dokku/deploy-powersync.sh \
  jeeves-powersync jeeves powersync.jeeves.loonyb.in
```

### Prerequisites

- Dokku server with the `postgres`, `resource`, and `letsencrypt` plugins
- The backend app already has `SECRET_KEY` set and a Postgres link
  (`dokku postgres:link <db> <backend-app>` injects `DATABASE_URL`)
- DNS for the PowerSync subdomain points at the Dokku host (A record;
  Cloudflare proxy is OK but turn it off for the initial Let's Encrypt
  challenge if you hit issues)

### What it does, in order — every step is idempotent

1. Create the dokku app, set ports `http:80:8080`, set 400m memory limit
2. **Auto-link the same Postgres service the backend uses** — derives the
   service name from the backend's `DATABASE_URL` hostname and runs
   `dokku postgres:link`. Without this the PowerSync container can't
   resolve `dokku-postgres-<svc>` and pgwire fails with no PG-level error.
3. **Configure the linked Postgres for logical replication** — runs
   `ALTER SYSTEM SET wal_level = logical;` and `dokku postgres:restart`
   if the current `wal_level` isn't already `logical`. dokku-postgres
   ships with PG's default (`replica`) and PowerSync refuses to start
   without logical replication. Setting persists in `postgresql.auto.conf`,
   so subsequent runs short-circuit. Note: the restart briefly disconnects
   every app linked to this Postgres service (the backend included).
4. Set PowerSync env: `PS_SECRET_KEY_B64` (derived from backend's
   `SECRET_KEY`, base64url with no padding or embedded newlines),
   `PS_DATA_SOURCE_URI`, `NODE_OPTIONS`
5. Publish `sync-config.yaml` via `publish-sync-config.sh`. On a fresh app
   this runs *before* there is any container — deliberately, since step 7's
   first start needs a config to read. The publisher detects the undeployed
   app (`ps:report --deployed`), sets `POWERSYNC_CONFIG_B64`, and skips the
   readiness probe and rollback it would otherwise do: there is nothing
   running to probe, and step 10's smoke test is what catches a bad config on
   this path. Everywhere else — CD, and re-runs against a live app — the probe
   and rollback do apply. (The publisher will not *silently* skip
   verification: if it cannot tell whether the app is deployed, or cannot
   resolve a readiness URL for one that is, it aborts before changing
   anything.)
6. `domains:set <ps-app> <domain>`
7. `git:from-image <ps-app> journeyapps/powersync-service:<pinned>` — env,
   network, config, domain are all in place first so the first start
   comes up healthy
8. `letsencrypt:enable <ps-app>`
9. Set `POWERSYNC_URL=https://<domain>` on the backend (restart only if
   the value changed)
10. Smoke-test `https://<domain>/probes/readiness`

### Re-running

To pull a newer PowerSync image, override `PS_IMAGE` and re-run. Pass it
through `sudo env` — sudoers defaults to `env_reset`, so the more natural
`PS_IMAGE=… sudo bash …` silently drops the variable and redeploys the pinned
default, which looks like success:

```bash
sudo env PS_IMAGE=journeyapps/powersync-service:1.23.3@sha256:... \
  bash deploy-powersync.sh jeeves-powersync jeeves powersync.jeeves.loonyb.in
```

Check the deploy log's `[7/10] Deploy image` line to confirm the digest you
asked for is the one that went out. (If the host's sudoers uses `env_keep` or
`SETENV`, the plain form works too — `sudo env` is correct either way.)

For point operations, re-running the whole script is fine — every step
short-circuits to a no-op when state is already correct. If you want surgical
control, the underlying `dokku` commands are documented in the script's
section headers.

### Migrating an environment bootstrapped before ADR-0017

The first CD run sets `POWERSYNC_CONFIG_B64`, which takes precedence
immediately, and `publish-sync-config.sh` unsets `POWERSYNC_CONFIG_PATH` once
readiness passes. The old storage mount is then inert, but still attached —
remove it once:

```bash
dokku storage:unmount jeeves-powersync \
  /var/lib/dokku/data/storage/jeeves-powersync:/config
```

## Tests

`tests/` runs both scripts against a stubbed `dokku` and `curl`
(`tests/stubs/`), which is the only way to exercise these paths without a real
Dokku host:

- `test-publish-sync-config.sh` — the unchanged-config no-op, stale-override
  healing, the fail-closed pre-flight (unreadable config, unknown deployment
  state, unresolvable probe target), the readiness rollback, and the
  compensating restore when a write fails mid-sequence.
- `test-deploy-powersync.sh` — the bootstrap ordering invariant: env vars, then
  publish, then `git:from-image`. A fresh environment whose image starts before
  its config is published comes up with nothing to read.

These live in `.github/workflows/backend-ci.yml` rather than an infra-specific
workflow, alongside a job that boots the pinned PowerSync image from
`POWERSYNC_CONFIG_B64` against a migrated Postgres — proving the config parses
and every bucket's SQL is valid against the schema the migrations produce.

That placement is deliberate. Backend CD triggers on Backend CI's conclusion,
so putting the validation anywhere else would leave the publish ungated: CD
would fire on Backend CI going green while the infra workflow was still running
or already red. Sharing the workflow makes the gate structural — same commit,
no polling, no race.
