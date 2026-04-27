#!/usr/bin/env bash
# Configure environment variables and storage mount for the PowerSync Dokku app.
# Idempotent: safe to re-run at any time.
#
# Required environment variables (set before running):
#   SECRET_KEY      — shared JWT secret (same as backend)
#   DATABASE_URL    — Postgres connection string for PowerSync bucket storage
#                     e.g. postgresql://user:pass@host:5432/dbname
set -euo pipefail

APP=powersync
CONFIG_STORAGE=/var/lib/dokku/data/storage/${APP}

: "${SECRET_KEY:?ERROR: SECRET_KEY must be set}"
: "${DATABASE_URL:?ERROR: DATABASE_URL must be set}"

echo "==> Configuring Dokku app: ${APP}"

# sync-config.yaml's JWKS block reads `PS_SECRET_KEY_B64` (base64url-encoded,
# no padding) — symmetric JWKs declare the key material as a base64url string.
# Strip embedded newlines too: GNU `base64` wraps at 76 columns by default, and
# both GNU and BSD `base64` add a trailing newline.  Either would corrupt the
# encoded value (e.g. `openssl rand -hex 32` produces an 88-char base64 string
# that GNU would split across two lines), and PowerSync would silently fail
# every JWT validation with `invalid token signature`.
SECRET_KEY_B64=$(printf '%s' "${SECRET_KEY}" | base64 | tr -d '\n=' | tr '/+' '_-')

# Set environment variables on the app (--no-restart allows batching).
# PS_DATA_SOURCE_URI is the PowerSync-required name for the Postgres URI
# (PowerSync only substitutes variables prefixed with PS_).
dokku config:set --no-restart "${APP}" \
  POWERSYNC_CONFIG_PATH=/config/sync-config.yaml \
  NODE_OPTIONS="--max-old-space-size=400" \
  PS_SECRET_KEY_B64="${SECRET_KEY_B64}" \
  DATABASE_URL="${DATABASE_URL}" \
  PS_DATA_SOURCE_URI="${DATABASE_URL}" > /dev/null

# Remove legacy keys if present (safe on re-runs).
# PS_JEEVES_SECRET_KEY was the old name AND was set to the raw secret rather
# than the base64url-encoded form sync-config.yaml expects — drop it outright.
dokku config:unset --no-restart "${APP}" \
  JEEVES_SECRET_KEY SECRET_KEY PS_JEEVES_SECRET_KEY PS_JEEVES_SECRET_KEY_B64 \
  >/dev/null 2>&1 || true
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
