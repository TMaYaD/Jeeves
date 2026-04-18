#!/usr/bin/env bash
# Configure environment variables and storage mount for the PowerSync Dokku app.
# Idempotent: safe to re-run at any time.
#
# Required environment variables (set before running):
#   JEEVES_SECRET_KEY   — shared JWT secret (same as backend)
#   DATABASE_URL        — Postgres connection string for PowerSync bucket storage
#                         e.g. postgresql://user:pass@host:5432/dbname
set -euo pipefail

APP=powersync
CONFIG_STORAGE=/var/lib/dokku/data/storage/${APP}

: "${JEEVES_SECRET_KEY:?ERROR: JEEVES_SECRET_KEY must be set}"
: "${DATABASE_URL:?ERROR: DATABASE_URL must be set}"

echo "==> Configuring Dokku app: ${APP}"

# Set environment variables on the app (--no-restart allows batching).
# PS_DATA_SOURCE_URI is the PowerSync-required name for the Postgres URI
# (PowerSync only substitutes variables prefixed with PS_).
dokku config:set --no-restart "${APP}" \
  POWERSYNC_CONFIG_PATH=/config/sync-config.yaml \
  NODE_OPTIONS="--max-old-space-size=400" \
  PS_JEEVES_SECRET_KEY="${JEEVES_SECRET_KEY}" \
  DATABASE_URL="${DATABASE_URL}" \
  PS_DATA_SOURCE_URI="${DATABASE_URL}" > /dev/null
echo "    Environment variables set"

# Create storage directory for sync-config.yaml if it doesn't exist.
if [ ! -d "${CONFIG_STORAGE}" ]; then
  mkdir -p "${CONFIG_STORAGE}"
  echo "    Created storage directory ${CONFIG_STORAGE}"
fi

# Mount the config directory into the container.
if ! dokku storage:list "${APP}" 2>/dev/null | grep -qE ":/config$"; then
  dokku storage:mount "${APP}" "${CONFIG_STORAGE}:/config"
  echo "    Mounted ${CONFIG_STORAGE} -> /config"
else
  echo "    Storage mount already configured"
fi

# Copy the sync-config.yaml to the storage mount.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_CONFIG="${SCRIPT_DIR}/../powersync/sync-config.yaml"
if [ -f "${SYNC_CONFIG}" ]; then
  cp "${SYNC_CONFIG}" "${CONFIG_STORAGE}/sync-config.yaml"
  echo "    Copied sync-config.yaml to ${CONFIG_STORAGE}"
else
  echo "    WARNING: ${SYNC_CONFIG} not found — copy it manually to ${CONFIG_STORAGE}/sync-config.yaml"
fi

echo "==> Done: ${APP} configured"
