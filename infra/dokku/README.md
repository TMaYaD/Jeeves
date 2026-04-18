# Jeeves — Dokku Production IaC

Scripts for provisioning and configuring the PowerSync service on Dokku.
All scripts are idempotent and safe to re-run.

## Scripts

| Script | Purpose |
|--------|---------|
| `provision-powersync.sh` | Create the Dokku app and deploy `journeyapps/powersync-service` |
| `configure-powersync.sh` | Set env vars, mount config volume, copy `sync-config.yaml` |
| `link-services.sh` | Set `JEEVES_POWERSYNC_URL` on the backend and restart both apps |

## Prerequisites

- Dokku server accessible via SSH
- Dokku `resource` plugin installed (`dokku plugin:install https://github.com/dokku/dokku-resource-cmd.git` if needed)
- Required secrets available as environment variables (see below)

## Required environment variables

| Variable | Description |
|----------|-------------|
| `JEEVES_SECRET_KEY` | Shared JWT secret — must match the backend |
| `DATABASE_URL` | Postgres connection string for PowerSync bucket storage |

## Deployment order

Run the scripts in this order (once per environment setup):

```bash
# 1. Create the Dokku app and deploy the image
./provision-powersync.sh

# 2. Configure env vars, copy sync config, mount volume
JEEVES_SECRET_KEY=<secret> DATABASE_URL=<pg-url> ./configure-powersync.sh

# 3. Wire backend → PowerSync URL and restart both apps
./link-services.sh
```

After the initial setup, subsequent image updates only require re-running
`provision-powersync.sh` (which calls `dokku git:from-image` to pull the
latest image).

## Backend CD

The backend is deployed via `.github/workflows/backend-cd.yml` using
`git push` to the Dokku remote (Dokku's `build-dir` config scopes the
build to the backend directory). PowerSync is a pre-built image — it does not need a
code deploy, only `provision-powersync.sh` when a new image version is
desired.
