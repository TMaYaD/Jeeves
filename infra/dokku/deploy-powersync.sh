#!/usr/bin/env bash
# Fresh-environment bootstrap for a PowerSync Dokku app.
# Run as root on the Dokku host.  Idempotent — safe to re-run.
#
# This is the bootstrap path only: everything CI cannot do (app creation,
# postgres linking, wal_level, domains, Let's Encrypt).  Once an environment
# exists, sync-rule changes publish themselves — Backend CD runs
# publish-sync-config.sh on every deploy.
#
# Needs the whole infra/ directory on the host, not just this file:
#   scp -r infra/ root@<dokku-host>:/root/jeeves-infra/
#   sudo bash /root/jeeves-infra/dokku/deploy-powersync.sh \
#     <powersync-app> <backend-app> <domain>
#   e.g.: ... jeeves-powersync jeeves powersync.jeeves.loonyb.in
#
# Optional env overrides:
#   PS_IMAGE   PowerSync image to deploy
#              (default: pinned by digest below)
#
# What it does, in order (each step idempotent):
#   1. Create the dokku app, set ports + resource limit
#   2. Pull SECRET_KEY from <backend-app>; derive postgres service from its
#      DATABASE_URL and link the same postgres service to the powersync app
#      (this puts the powersync container on the postgres docker network and
#      injects DATABASE_URL automatically)
#   3. Configure the linked postgres for logical replication
#      (`wal_level=logical`); restarts the postgres service if needed
#   4. Set PowerSync env: PS_SECRET_KEY_B64 (base64url, no padding, no
#      newlines), PS_DATA_SOURCE_URI, NODE_OPTIONS
#   5. Publish infra/powersync/sync-config.yaml via publish-sync-config.sh
#   6. Add the public domain
#   7. Deploy the PowerSync image (env/network/domain are in place first so
#      the first container start comes up healthy)
#   8. Enable Let's Encrypt
#   9. Wire <backend-app>: set POWERSYNC_URL, restart only if changed
#  10. Smoke-test the public endpoint
set -euo pipefail

if [ $# -ne 3 ]; then
  echo "Usage: $0 <powersync-app> <backend-app> <domain>" >&2
  echo "  e.g.: $0 jeeves-powersync jeeves powersync.jeeves.loonyb.in" >&2
  exit 2
fi

PS_APP="$1"
BACKEND_APP="$2"
PS_DOMAIN="$3"
PS_IMAGE="${PS_IMAGE:-journeyapps/powersync-service:1.23.0@sha256:6405a437bf527957c99e670497a537903af8e1469724b70d030a74aaef5241fa}"
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)

# ----- Preconditions ---------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: must run as root (or via sudo)." >&2
  exit 1
fi
if ! command -v dokku >/dev/null 2>&1; then
  echo "ERROR: dokku not found in PATH." >&2
  exit 1
fi

echo "==> Bootstrap target: ${PS_APP} (backend: ${BACKEND_APP}, domain: ${PS_DOMAIN})"

# ----- 1. Create app + ports + resource --------------------------------------
echo "==> [1/10] App + ports + resource limit"
if dokku apps:exists "${PS_APP}" >/dev/null 2>&1; then
  echo "    App ${PS_APP} already exists"
else
  dokku apps:create "${PS_APP}"
fi
if ! dokku ports:list "${PS_APP}" 2>/dev/null | grep -qE "^http[[:space:]]+80[[:space:]]+8080$"; then
  dokku ports:set "${PS_APP}" http:80:8080
fi
if dokku resource:limit --memory 400m "${PS_APP}" 2>/dev/null; then
  echo "    Resource limit set (400m)"
else
  echo "    WARN: resource:limit failed (plugin not installed?)"
fi

# ----- 2. Link the same postgres service that the backend uses ---------------
# Without the link, the powersync container isn't on the postgres docker
# network and can't resolve the `dokku-postgres-<svc>` hostname — pgwire
# then fails with an opaque "postgres query failed" (no PG-level error,
# because the connection never reaches Postgres).
echo "==> [2/10] Link postgres service (auto-derived from ${BACKEND_APP})"
SECRET_KEY=$(dokku config:get "${BACKEND_APP}" SECRET_KEY 2>/dev/null || true)
BACKEND_DB_URL=$(dokku config:get "${BACKEND_APP}" DATABASE_URL 2>/dev/null || true)
if [ -z "${SECRET_KEY}" ]; then
  echo "ERROR: ${BACKEND_APP} has no SECRET_KEY set." >&2
  exit 1
fi
if [ -z "${BACKEND_DB_URL}" ]; then
  echo "ERROR: ${BACKEND_APP} has no DATABASE_URL — link a postgres service to it first." >&2
  exit 1
fi
# Hostname looks like `dokku-postgres-<service-name>` — strip the prefix.
PG_HOST=$(printf '%s' "${BACKEND_DB_URL}" | sed -E 's|^[a-z+]+://[^@]+@([^:/]+).*|\1|')
PG_SERVICE="${PG_HOST#dokku-postgres-}"
if [ "${PG_SERVICE}" = "${PG_HOST}" ]; then
  echo "ERROR: could not derive postgres service from DATABASE_URL hostname '${PG_HOST}'." >&2
  echo "       Expected hostname of the form 'dokku-postgres-<service>'." >&2
  exit 1
fi
echo "    Postgres service: ${PG_SERVICE}"
# dokku-postgres considers an app "linked" iff *any* env var holds the postgres
# connection string — it doesn't verify the docker network alias actually
# exists.  A prior failed run can leave DATABASE_URL or PS_DATA_SOURCE_URI set
# (via config:set) without a real link; postgres:link then bails with "Already
# linked as <VAR>" and the network alias never gets added, so the container
# can't resolve dokku-postgres-<svc>.  Use the Links field of postgres:info as
# the source of truth, and clear any phantom *_URL vars before linking.
if dokku postgres:info "${PG_SERVICE}" 2>/dev/null | awk '/^[[:space:]]*Links:/' | grep -qw "${PS_APP}"; then
  echo "    ${PS_APP} already linked to ${PG_SERVICE}"
else
  dokku config:unset --no-restart "${PS_APP}" DATABASE_URL PS_DATA_SOURCE_URI >/dev/null 2>&1 || true
  dokku postgres:link "${PG_SERVICE}" "${PS_APP}" --no-restart
fi

# ----- 3. Configure postgres for logical replication -------------------------
# PowerSync's WAL-streaming replicator needs `wal_level=logical`; dokku-postgres
# ships with the PG default (`replica`) and PowerSync fails fast at startup with
# "wal_level must be set to 'logical'".  ALTER SYSTEM writes to
# postgresql.auto.conf so the change persists across restarts, and a server
# restart is required for wal_level to take effect.
#
# This restarts the postgres service, which briefly disconnects every linked
# app (backend included).  The cost is one-time: subsequent runs short-circuit.
echo "==> [3/10] Configure postgres for logical replication"
# psql output via `dokku postgres:connect` includes the column header, a dash
# separator, the value row, and a row count.  Extract just the value row.
pg_wal_level() {
  echo "SHOW wal_level;" | dokku postgres:connect "$1" 2>/dev/null \
    | awk '/^[[:space:]]+(replica|logical|minimal)[[:space:]]*$/ {print $1; exit}'
}
PG_WAL_LEVEL=$(pg_wal_level "${PG_SERVICE}")
if [ "${PG_WAL_LEVEL}" = "logical" ]; then
  echo "    wal_level already 'logical'"
else
  echo "    wal_level is '${PG_WAL_LEVEL:-unknown}' — switching to 'logical' and restarting ${PG_SERVICE}"
  echo "ALTER SYSTEM SET wal_level = logical;" | dokku postgres:connect "${PG_SERVICE}" >/dev/null
  dokku postgres:restart "${PG_SERVICE}"
  # Wait for the restarted service to accept connections again before the
  # later steps try to talk to it (or return success too eagerly).  Track the
  # probe explicitly so a silent timeout reports "didn't come back" rather
  # than misleading the operator with a downstream `wal_level=unknown` error.
  PG_READY=0
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    sleep 3
    if echo "SELECT 1;" | dokku postgres:connect "${PG_SERVICE}" >/dev/null 2>&1; then
      PG_READY=1
      break
    fi
  done
  if [ "${PG_READY}" -ne 1 ]; then
    echo "ERROR: ${PG_SERVICE} did not accept connections within 30s after restart." >&2
    echo "       Inspect with: dokku postgres:info ${PG_SERVICE} ; dokku postgres:logs ${PG_SERVICE} --tail 100" >&2
    exit 1
  fi
  PG_WAL_LEVEL=$(pg_wal_level "${PG_SERVICE}")
  if [ "${PG_WAL_LEVEL}" != "logical" ]; then
    echo "ERROR: wal_level is '${PG_WAL_LEVEL:-unknown}' after restart — expected 'logical'." >&2
    exit 1
  fi
  echo "    wal_level set to 'logical'"
fi

# ----- 4. Set PowerSync env vars ---------------------------------------------
# sync-config.yaml's JWKS block reads PS_SECRET_KEY_B64 (base64url, no padding).
# Strip embedded newlines: GNU base64 wraps at 76 cols; both GNU and BSD add a
# trailing newline.  Either would corrupt PS_SECRET_KEY_B64 and silently break
# every JWT validation with `invalid token signature`.
SECRET_KEY_B64=$(printf '%s' "${SECRET_KEY}" | base64 | tr -d '\n=' | tr '/+' '_-')

# PS_DATA_SOURCE_URI uses the link-injected DATABASE_URL (now visible after
# the postgres:link above).  Re-fetch in case the link rewrote it.
DATABASE_URL=$(dokku config:get "${PS_APP}" DATABASE_URL 2>/dev/null || true)
if [ -z "${DATABASE_URL}" ]; then
  echo "ERROR: ${PS_APP} has no DATABASE_URL after postgres:link." >&2
  exit 1
fi

echo "==> [4/10] Set env vars on ${PS_APP}"
dokku config:set --no-restart "${PS_APP}" \
  NODE_OPTIONS="--max-old-space-size=400" \
  PS_SECRET_KEY_B64="${SECRET_KEY_B64}" \
  PS_DATA_SOURCE_URI="${DATABASE_URL}" > /dev/null
# Drop legacy keys if present (no-op on fresh deploys).
dokku config:unset --no-restart "${PS_APP}" \
  JEEVES_SECRET_KEY SECRET_KEY PS_JEEVES_SECRET_KEY PS_JEEVES_SECRET_KEY_B64 \
  >/dev/null 2>&1 || true

# ----- 5. Publish the sync config --------------------------------------------
# Same script CI runs on every deploy, reading the same
# infra/powersync/sync-config.yaml.  Nothing is mounted at /config: the config
# travels as POWERSYNC_CONFIG_B64 (see the script header and ADR-0017).  On a
# fresh app there is no container yet, so it publishes and skips the readiness
# probe — the deploy and smoke test below cover that.
# Invoked via `bash` rather than directly: a plain `scp -r` of infra/ masks the
# source modes by the remote umask, so the exec bit is not guaranteed to
# survive the copy documented in the header.
echo "==> [5/10] Publish sync config"
bash "${SCRIPT_DIR}/publish-sync-config.sh" "${PS_APP}" "${BACKEND_APP}"

# ----- 6. Public domain -------------------------------------------------------
echo "==> [6/10] Domain ${PS_DOMAIN}"
if ! dokku domains:report "${PS_APP}" --domains-app-vhosts 2>/dev/null | grep -qw "${PS_DOMAIN}"; then
  dokku domains:set "${PS_APP}" "${PS_DOMAIN}"
else
  echo "    Domain already configured"
fi

# ----- 7. Deploy the PowerSync image -----------------------------------------
# git:from-image exits non-zero with "No changes detected" when the image
# digest already matches the deployed one — that's a success state for
# idempotence, not a failure.  Capture output and treat that case as a no-op.
echo "==> [7/10] Deploy image"
PS_DEPLOY_OUT=$(dokku git:from-image "${PS_APP}" "${PS_IMAGE}" 2>&1) || PS_DEPLOY_RC=$?
printf '%s\n' "${PS_DEPLOY_OUT}"
if [ "${PS_DEPLOY_RC:-0}" -ne 0 ]; then
  if printf '%s' "${PS_DEPLOY_OUT}" | grep -q "No changes detected"; then
    echo "    Image unchanged — already deployed"
  else
    exit "${PS_DEPLOY_RC}"
  fi
fi
unset PS_DEPLOY_OUT PS_DEPLOY_RC

# ----- 8. Let's Encrypt ------------------------------------------------------
echo "==> [8/10] Let's Encrypt"
# Always run letsencrypt:enable, even when a cert is already issued: other
# dokku operations (config:set restart, ps:rebuild, domains:set) regenerate
# the nginx vhost and can drop the SSL listener binding, leaving the host
# serving the default vhost cert instead of this app's letsencrypt cert.
# letsencrypt:enable is idempotent — it rewrites the vhost SSL config and
# only re-issues the cert if it's near expiry.
#
# dokku-letsencrypt stores email via plugn properties (not app config), so
# there's no reliable pre-check.  Trust letsencrypt:enable to fail with
# its own clear message if no email is set.  LETSENCRYPT_EMAIL from the
# script env seeds the per-app value when present.
if [ -n "${LETSENCRYPT_EMAIL:-}" ]; then
  dokku letsencrypt:set "${PS_APP}" email "${LETSENCRYPT_EMAIL}"
fi
dokku letsencrypt:enable "${PS_APP}"

# ----- 9. Wire backend ------------------------------------------------------
echo "==> [9/10] Wire ${BACKEND_APP} → POWERSYNC_URL"
PS_URL="https://${PS_DOMAIN}"
CURRENT_URL=$(dokku config:get "${BACKEND_APP}" POWERSYNC_URL 2>/dev/null || true)
if [ "${CURRENT_URL}" != "${PS_URL}" ]; then
  dokku config:set "${BACKEND_APP}" POWERSYNC_URL="${PS_URL}"
else
  echo "    POWERSYNC_URL already set, skipping restart"
fi

# ----- Smoke test ------------------------------------------------------------
# Two checks, both real:
#   (1) container is running (`dokku ps:report`)
#   (2) external HTTPS reaches PowerSync's readiness probe with a valid cert
#
# (2) catches the regressions we hit during bring-up: nginx vhost rebuilds
# can drop the SSL binding so the host serves a different cert + routes to
# the wrong app.  We probe via public DNS with full cert verification so a
# bad SSL binding fails loudly.  Retry briefly because the container can
# need a few seconds after deploy to be ready.
echo ""
echo "==> [10/10] Smoke test: container status"
SMOKE_OK=0
for attempt in 1 2 3 4 5 6; do
  sleep 5
  if dokku ps:report "${PS_APP}" 2>/dev/null | grep -qE "^[[:space:]]*Status web 1:[[:space:]]+running"; then
    SMOKE_OK=1
    break
  fi
  echo "    attempt ${attempt}: web 1 not yet running"
done
if [ "${SMOKE_OK}" -ne 1 ]; then
  echo "WARN: container not running after retries.  Inspect with:"
  echo "  dokku logs ${PS_APP} --tail 100"
  echo "  dokku ps:report ${PS_APP}"
  exit 1
fi
echo "    OK (web 1 running)"

echo "==> [10/10] Smoke test: ${PS_URL}/probes/readiness"
SMOKE_OK=0
SMOKE_LAST=""
for attempt in 1 2 3 4 5 6; do
  sleep 5
  if SMOKE_LAST=$(curl -fsS --max-time 10 \
       -w "HTTP %{http_code}" -o /dev/null \
       "${PS_URL}/probes/readiness" 2>&1); then
    # `curl -f` fails on >=400 but succeeds on a 3xx, and a lost SSL binding or
    # a vhost falling through to the default app answers with a redirect —
    # exactly the regressions this smoke test exists to catch.  Require a 2xx.
    case "${SMOKE_LAST##* }" in
      2??)
        SMOKE_OK=1
        break
        ;;
      *)
        SMOKE_LAST="${SMOKE_LAST} — not 2xx (redirect or wrong vhost)"
        ;;
    esac
  fi
  echo "    attempt ${attempt}: ${SMOKE_LAST}"
done
if [ "${SMOKE_OK}" -eq 1 ]; then
  echo "    OK (${SMOKE_LAST})"
  echo "==> Done: ${PS_APP} deployed and reachable at ${PS_URL}"
else
  echo "WARN: external HTTPS smoke test failed (last: ${SMOKE_LAST})."
  echo "  - cert mismatch usually means the nginx vhost lost its SSL binding;"
  echo "    re-run this script or 'dokku letsencrypt:enable ${PS_APP}'"
  echo "  - 404 from a different app means routing fell through to the default vhost"
  echo "  - inspect:  dokku logs ${PS_APP} --tail 100"
  exit 1
fi
