# 17. PowerSync configuration ships as a Dokku config var, not a mounted file

## Status

Accepted

## Context

Backend migrations deploy themselves — Backend CD pushes to Dokku and the
`Procfile`'s release phase runs Alembic. Sync rules did not: they lived in a
heredoc inside `infra/dokku/deploy-powersync.sh`, a script run by hand over
SSH as root, hand-synced against `infra/powersync/sync-config.yaml`. Alembic
`0026` shipped and moved every unclarified `todos` row into `captures` while
the running PowerSync instance still had no `captures` bucket; PowerSync
replicated the `todos` deletions down but had no path for the new rows, and
signed-in users watched the Inbox empty and stay empty until someone ran the
script. To close that, CI has to be able to publish rules.

The obvious delivery mechanism — write the YAML to
`/var/lib/dokku/data/storage/<app>/` and mount it at `/config` — needs root on
the Dokku host. Backend CD authenticates as the unprivileged `dokku` SSH user
and only ever runs `git push`. Handing CI a root key to update a 5KB config
file is a security downgrade out of all proportion to the problem.

## Decision

The configuration is delivered as `POWERSYNC_CONFIG_B64` — base64 of the whole
of `infra/powersync/sync-config.yaml` — set with `dokku config:set`, which the
existing `dokku` SSH user can already do. PowerSync's `Base64ConfigCollector`
runs ahead of its `FileSystemConfigCollector`, so the config var takes
precedence over `POWERSYNC_CONFIG_PATH`; both funnel through the same parser,
so `!env` tag substitution is identical either way.
`infra/dokku/publish-sync-config.sh` is the single publish path, called by both
Backend CD and the bootstrap script, and the storage mount is gone.

Local dev still mounts the file via Docker Compose. The same bytes reach both
environments by different routes — that divergence is the price of not giving
CI root.

Rejected: **root SSH from CI plus `scp`** — works, but grants CI root on the
host to update a config file. **Baking the config into a derived image pushed
to GHCR and deployed with `git:from-image`** — idempotence would come free from
the digest check, but it drags a Dockerfile, registry auth on the host, and a
build step into what is a text-file update. **`POWERSYNC_SYNC_CONFIG_B64`** (just
the rules rather than the whole config) — would mean splitting the YAML into a
base and a rules document, and there is nothing to split: the two environments'
configs are byte-identical.

## Consequences

Bucket definitions exist in exactly one file, and a change to that file
publishes itself on the next merge to `main`. `publish-sync-config.sh` writes
nothing when the published value already matches and nothing is masking it, so
the step is safe to fire on every deploy; when it does publish, the restart
makes the new rules live, and a failed readiness probe restores the previous
state rather than leaving production crash-looping unattended.

"Published" and "effective" are not automatically the same thing, and the
script has to work to keep them so. PowerSync reads several config-delivery
variables, and two of them (`POWERSYNC_SYNC_CONFIG_B64`,
`POWERSYNC_SYNC_RULES_B64`) override the rules from *inside* the config we
publish. While one is set, the published value is inert — so the script clears
them before publishing, not after, and treats clearing one as a rules change in
its own right: it restarts and re-probes even when `POWERSYNC_CONFIG_B64` is
unchanged. `POWERSYNC_CONFIG_PATH` is the opposite case — inert while our value
is set, and the only thing a first publish can roll back to — so it is kept
until readiness passes and dropped afterwards. Readiness therefore attests to
the rules that are actually being served, not merely to the ones we sent.

Two limits are worth stating plainly, because the automation looks like it
covers them and does not:

**This enforces co-deployment, not consistency.** A commit that adds a
migration and a table but forgets the bucket publishes an unchanged config and
ships a table with no replication path. Catching that needs a CI assertion
that every client-synced table has a bucket — not built here.

**The migration→publish window is bounded, not closed.** Migrations run in the
release phase of `git push`, which blocks; the publish step follows. The
ordering is right, but it is sequential rather than atomic, so for a
data-moving migration there is a window of seconds to minutes — plus PowerSync's
reprocessing time after the restart — where the new schema is live and the old
rules are still being served. That is the #184 condition again, now
self-clearing instead of indefinite.

Destructive and renaming migrations invert the safe order: rules must be
updated *before* the migration, in two phases. The pipeline cannot express
that; `infra/dokku/README.md` documents it as a manual procedure.
