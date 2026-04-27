# Jeeves — Dokku Production IaC

`deploy-powersync.sh` is a one-shot bootstrap for a PowerSync Dokku app.
Idempotent — safe to re-run at any time.

PowerSync is **product-scoped** — one instance per backend / source database.
Sync rules and JWT keys are tied to a single product, so multiple products
(jeeves, lease-manager, …) cannot share one PowerSync app. Name each
PowerSync app `<product>-powersync` (e.g. `jeeves-powersync`) to keep them
distinct on the same Dokku host. A future `dokku-powersync` plugin will
encode this convention as first-class commands ([#201][]).

[#201]: https://github.com/TMaYaD/Jeeves/issues/201

## Prerequisites

- Dokku server with the `postgres`, `resource`, and `letsencrypt` plugins
- The backend app already has `SECRET_KEY` set and a Postgres link
  (`dokku postgres:link <db> <backend-app>` injects `DATABASE_URL`)
- DNS for the PowerSync subdomain points at the Dokku host (A record;
  Cloudflare proxy is OK but turn it off for the initial Let's Encrypt
  challenge if you hit issues)

## Usage

Copy the script to the host and run it as root:

```bash
scp infra/dokku/deploy-powersync.sh root@<dokku-host>:/root/
ssh root@<dokku-host> bash /root/deploy-powersync.sh \
  jeeves-powersync jeeves powersync.jeeves.loonyb.in
```

What it does, in order — every step is idempotent:

1. Storage dir + `sync-config.yaml` (heredoc'd in the script) + chown to
   the herokuish UID
2. Create the dokku app, set ports `http:80:8080`, set 400m memory limit
3. **Auto-link the same Postgres service the backend uses** — derives the
   service name from the backend's `DATABASE_URL` hostname and runs
   `dokku postgres:link`. Without this the PowerSync container can't
   resolve `dokku-postgres-<svc>` and pgwire fails with no PG-level error.
4. Set PowerSync env: `PS_SECRET_KEY_B64` (derived from backend's
   `SECRET_KEY`, base64url with no padding or embedded newlines),
   `PS_DATA_SOURCE_URI`, `NODE_OPTIONS`, `POWERSYNC_CONFIG_PATH`
5. Mount `/var/lib/dokku/data/storage/<ps-app>` at `/config`
6. `domains:set <ps-app> <domain>`
7. `git:from-image <ps-app> journeyapps/powersync-service:<pinned>` — env,
   network, storage, domain are all in place first so the first start
   comes up healthy
8. `letsencrypt:enable <ps-app>`
9. Set `POWERSYNC_URL=https://<domain>` on the backend (restart only if
   the value changed)
10. Smoke-test `https://<domain>/probes/readiness`

## Re-running

To pull a newer PowerSync image, override `PS_IMAGE` and re-run:

```bash
PS_IMAGE=journeyapps/powersync-service:1.21.0@sha256:... \
  sudo bash deploy-powersync.sh jeeves-powersync jeeves powersync.jeeves.loonyb.in
```

For point operations (just rotate the secret, just reconfigure the
sync rules) re-running the whole script is fine — every step short-circuits
to a no-op when state is already correct. If you want surgical control,
the underlying `dokku` commands are documented in the script's section
headers.

## Sync rules

The script embeds `sync-config.yaml` as a heredoc so it can be `scp`'d as
a single file. The local-dev source of truth lives at
`infra/powersync/sync-config.yaml` — keep the two in sync until the
`dokku-powersync` plugin (#201) lands and the duplication goes away.

## Backend CD

The backend is deployed via `.github/workflows/backend-cd.yml` using
`git push` to the Dokku remote (Dokku's `build-dir` config scopes the
build to the backend directory). PowerSync is a pre-built image — it
doesn't need a code deploy, only `deploy-powersync.sh` when a new image
version is desired.
