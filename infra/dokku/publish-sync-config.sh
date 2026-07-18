#!/usr/bin/env bash
# Publish the PowerSync configuration to a Dokku app.
#
# `infra/powersync/sync-config.yaml` is the single source of truth for the
# PowerSync config — replication source, bucket definitions, client auth.
# This script delivers that exact file to the Dokku app as
# POWERSYNC_CONFIG_B64, the base64-of-the-whole-config env var PowerSync's
# Base64ConfigCollector reads ahead of POWERSYNC_CONFIG_PATH.
#
# Delivering via config var rather than a mounted file is what lets CI publish
# with the ordinary `dokku` SSH user — writing to /var/lib/dokku/data/storage
# needs root on the host.  See docs/adr/0017-sync-rules-as-dokku-config-var.md.
#
# Idempotent: when the published value already matches the file, nothing is set
# and the app is not restarted.  Safe to run on every deploy.
#
# Usage:
#   ./publish-sync-config.sh <powersync-app> [backend-app]
#   e.g.: ./publish-sync-config.sh jeeves-powersync jeeves
#
# Optional env overrides:
#   DOKKU             how to invoke dokku.  Default `dokku` (the local binary,
#                     for bootstrap on the host); CI sets `ssh dokku@<host>`.
#   PS_CONFIG_FILE    config to publish (default: ../powersync/sync-config.yaml
#                     relative to this script)
#   PS_READINESS_URL  readiness endpoint override.  Normally derived from
#                     <backend-app>'s POWERSYNC_URL — the exact URL clients
#                     use — falling back to the app's own first vhost.
set -euo pipefail

# ----- Tunables --------------------------------------------------------------
# Readiness polling after a config change.  `dokku config:set` restarts the
# app; PowerSync then re-reads the rules and reconnects to Postgres before it
# reports ready.  60s total is generous for a container that is already warm.
PS_READINESS_ATTEMPTS="${PS_READINESS_ATTEMPTS:-12}"
PS_READINESS_INTERVAL_SECONDS="${PS_READINESS_INTERVAL_SECONDS:-5}"
# Per-request ceiling: the probe is a liveness signal, not a slow query.
PS_READINESS_TIMEOUT_SECONDS="${PS_READINESS_TIMEOUT_SECONDS:-10}"
# The rollback re-probe is shorter — the app was healthy on this config a
# moment ago, and the script exits non-zero either way.
PS_ROLLBACK_READINESS_ATTEMPTS="${PS_ROLLBACK_READINESS_ATTEMPTS:-6}"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 <powersync-app> [backend-app]" >&2
  echo "  e.g.: $0 jeeves-powersync jeeves" >&2
  exit 2
fi

PS_APP="$1"
BACKEND_APP="${2:-}"

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PS_CONFIG_FILE="${PS_CONFIG_FILE:-${SCRIPT_DIR}/../powersync/sync-config.yaml}"

# DOKKU may be a multi-word command (`ssh dokku@host`), so word-split it into
# an array rather than re-splitting on every call.
read -r -a DOKKU_CMD <<<"${DOKKU:-dokku}"
dokku_cmd() { "${DOKKU_CMD[@]}" "$@"; }

config_value() { dokku_cmd config:get "${PS_APP}" "$1" 2>/dev/null || true; }

# Two kinds of leftover key, and the difference decides *when* each is cleared.
#
# CONTENT overrides replace `sync_config.content` from inside the config we
# publish.  While one is set, publishing new buckets changes nothing a client
# can see — so they have to go *before* config:set, or the readiness probe
# green-lights rules that are not the ones we shipped.  Clearing one changes
# the effective rules, so it counts as a change in its own right: it forces a
# restart and a probe even when POWERSYNC_CONFIG_B64 itself is unchanged.
CONTENT_OVERRIDE_KEYS=(POWERSYNC_SYNC_CONFIG_B64 POWERSYNC_SYNC_RULES_B64)
#
# The FALLBACK key points at the storage-mounted file the base64 value
# supersedes.  It is inert while POWERSYNC_CONFIG_B64 is set, and it is the
# only thing a first publish can roll back to, so it survives until readiness
# passes and is dropped after.
LEGACY_FALLBACK_KEY=POWERSYNC_CONFIG_PATH

# Prior values are captured so a rollback can put them back.
CLEARED_OVERRIDES=()

# $1: `--no-restart` when a config:set follows and will carry the restart,
#     anything else to restart here.
clear_content_overrides() {
  local restart_mode="$1" key value
  local keys=()
  for key in "${CONTENT_OVERRIDE_KEYS[@]}"; do
    value=$(config_value "${key}")
    if [ -n "${value}" ]; then
      keys+=("${key}")
      CLEARED_OVERRIDES+=("${key}=${value}")
    fi
  done
  if [ "${#keys[@]}" -eq 0 ]; then
    return 0
  fi
  echo "    clearing content overrides that would mask the published rules: ${keys[*]}"
  if [ "${restart_mode}" = "--no-restart" ]; then
    dokku_cmd config:unset --no-restart "${PS_APP}" "${keys[@]}" >/dev/null
  else
    dokku_cmd config:unset "${PS_APP}" "${keys[@]}" >/dev/null
  fi
}

restore_content_overrides() {
  local restart_mode="$1"
  if [ "${#CLEARED_OVERRIDES[@]}" -eq 0 ]; then
    return 0
  fi
  echo "       restoring cleared content overrides" >&2
  if [ "${restart_mode}" = "--no-restart" ]; then
    dokku_cmd config:set --no-restart "${PS_APP}" "${CLEARED_OVERRIDES[@]}" >/dev/null
  else
    dokku_cmd config:set "${PS_APP}" "${CLEARED_OVERRIDES[@]}" >/dev/null
  fi
}

# Safe to do with --no-restart: the key is already inert at this point, so
# removing it changes nothing the running container is using.
drop_legacy_fallback() {
  if [ -z "$(config_value "${LEGACY_FALLBACK_KEY}")" ]; then
    return 0
  fi
  echo "    dropping superseded ${LEGACY_FALLBACK_KEY}"
  dokku_cmd config:unset --no-restart "${PS_APP}" "${LEGACY_FALLBACK_KEY}" >/dev/null
}

# Prints `true` or `false`; non-zero exit means dokku could not be asked.
# The distinction matters: a failed lookup treated as "not deployed" would
# silently downgrade the publish from verified to unverified.
app_deployed_state() {
  local out
  out=$(dokku_cmd ps:report "${PS_APP}" --deployed 2>/dev/null) || return 1
  case "${out}" in
    *true*)  printf 'true' ;;
    *false*) printf 'false' ;;
    *)       return 1 ;;
  esac
}

resolve_readiness_url() {
  local url=""
  if [ -n "${PS_READINESS_URL:-}" ]; then
    printf '%s' "${PS_READINESS_URL%/}"
    return 0
  fi
  if [ -n "${BACKEND_APP}" ]; then
    url=$(dokku_cmd config:get "${BACKEND_APP}" POWERSYNC_URL 2>/dev/null || true)
  fi
  if [ -z "${url}" ]; then
    url=$(dokku_cmd domains:report "${PS_APP}" --domains-app-vhosts 2>/dev/null \
      | awk 'NF {print $1; exit}')
    [ -n "${url}" ] && url="https://${url}"
  fi
  printf '%s' "${url%/}"
}

probe_readiness() {
  local url="$1" attempts="$2" last="" code="" attempt
  for attempt in $(seq 1 "${attempts}"); do
    sleep "${PS_READINESS_INTERVAL_SECONDS}"
    if last=$(curl -fsS --max-time "${PS_READINESS_TIMEOUT_SECONDS}" \
         -w "HTTP %{http_code}" -o /dev/null "${url}" 2>&1); then
      # `curl -f` fails on >=400 but *succeeds* on a 3xx, and a vhost that has
      # lost its routing answers with a redirect.  Accepting that would mean
      # signing off a publish nothing actually verified, so require a 2xx.
      code="${last##* }"
      case "${code}" in
        2??)
          echo "    ready (${last})"
          return 0
          ;;
        *)
          last="${last} — not 2xx (redirect or wrong vhost, not PowerSync)"
          ;;
      esac
    fi
    echo "    attempt ${attempt}/${attempts}: ${last}"
  done
  return 1
}

# ----- Read the source of truth ----------------------------------------------
# Hard-fail rather than publish an empty config: a missing or truncated file
# would take the whole sync layer down on the restart that follows.
if [ ! -f "${PS_CONFIG_FILE}" ]; then
  echo "ERROR: config file not found: ${PS_CONFIG_FILE}" >&2
  exit 1
fi
if [ ! -s "${PS_CONFIG_FILE}" ]; then
  echo "ERROR: config file is empty: ${PS_CONFIG_FILE}" >&2
  exit 1
fi

# `tr -d '\n'` rather than `base64 -w0`: BSD base64 has no -w.
NEW_B64=$(base64 < "${PS_CONFIG_FILE}" | tr -d '\n')
CUR_B64=$(dokku_cmd config:get "${PS_APP}" POWERSYNC_CONFIG_B64 2>/dev/null || true)

CONFIG_CHANGED=false
[ "${NEW_B64}" != "${CUR_B64}" ] && CONFIG_CHANGED=true

# ----- Pre-flight -------------------------------------------------------------
# Everything needed to *verify* the publish is resolved before anything is
# changed, so an unresolvable probe target aborts while there is still nothing
# to roll back.  Resolving after config:set would leave the only alternatives
# as "publish blind and report success" or "fail with the app already changed".
if ! DEPLOYED=$(app_deployed_state); then
  echo "ERROR: could not determine whether ${PS_APP} is deployed." >&2
  echo "       Refusing to publish a config that cannot then be verified." >&2
  exit 1
fi

READINESS_URL=""
if [ "${DEPLOYED}" = "true" ]; then
  READINESS_URL=$(resolve_readiness_url)
  if [ -z "${READINESS_URL}" ]; then
    echo "ERROR: no readiness URL for ${PS_APP} — no POWERSYNC_URL on" >&2
    echo "       '${BACKEND_APP:-<unset>}' and no vhost on the app." >&2
    echo "       Set PS_READINESS_URL to publish anyway." >&2
    exit 1
  fi
fi

# ----- Publish ----------------------------------------------------------------
# Content overrides go first: leaving one in place would mask whatever we
# publish, and the probe below would then be verifying the wrong rules.  When a
# config:set follows it carries the restart; when it doesn't, clearing the
# override *is* the change and has to restart on its own.
if [ "${CONFIG_CHANGED}" = true ]; then
  clear_content_overrides --no-restart
else
  clear_content_overrides restart
fi

if [ "${CONFIG_CHANGED}" = false ] && [ "${#CLEARED_OVERRIDES[@]}" -eq 0 ]; then
  echo "==> ${PS_APP}: sync config unchanged — nothing published, no restart"
  drop_legacy_fallback
  exit 0
fi

if [ "${CONFIG_CHANGED}" = true ]; then
  echo "==> Publishing ${PS_CONFIG_FILE} → ${PS_APP} (POWERSYNC_CONFIG_B64)"
  dokku_cmd config:set "${PS_APP}" "POWERSYNC_CONFIG_B64=${NEW_B64}" >/dev/null
else
  echo "==> ${PS_APP}: published config was already current but masked by an override"
  echo "    the override is gone, so the published rules are now the effective ones"
fi

# ----- Verify the app came back on the new config -----------------------------
# A not-yet-deployed app has no container to probe.  This is the bootstrap
# path: the config has to be in place *before* the image is deployed, or the
# first container start comes up with no config at all — the deploy and its own
# smoke test follow in deploy-powersync.sh.
if [ "${DEPLOYED}" != "true" ]; then
  echo "    ${PS_APP} has no deployed container yet — skipping readiness probe"
  drop_legacy_fallback
  exit 0
fi

echo "==> Readiness: ${READINESS_URL}/probes/readiness"
if probe_readiness "${READINESS_URL}/probes/readiness" "${PS_READINESS_ATTEMPTS}"; then
  drop_legacy_fallback
  echo "==> Done: ${PS_APP} is serving the published sync rules"
  exit 0
fi

# ----- Roll back --------------------------------------------------------------
# An unattended pipeline that publishes an invalid config would otherwise leave
# production crash-looping with nobody at the keyboard.  Restoring costs a
# second restart and a second reprocess; that is the right price.
echo "ERROR: ${PS_APP} did not become ready after the config change." >&2

# Whatever this run changed gets put back.  Where a POWERSYNC_CONFIG_B64
# restore follows, the override restore rides along with --no-restart and the
# B64 write carries the single restart; where it doesn't, restoring the
# override is itself the rollback and has to restart.
if [ "${CONFIG_CHANGED}" = true ] && [ -n "${CUR_B64}" ]; then
  restore_content_overrides --no-restart
  echo "==> Rolling back to the previous sync config" >&2
  dokku_cmd config:set "${PS_APP}" "POWERSYNC_CONFIG_B64=${CUR_B64}" >/dev/null
elif [ "${CONFIG_CHANGED}" = true ] && [ -n "$(config_value "${LEGACY_FALLBACK_KEY}")" ]; then
  # First publish into an environment bootstrapped before ADR-0017: there is no
  # previous base64 value, but the mounted file this one supersedes is still
  # configured and is a genuine known-good state.  Dropping our value (with the
  # restart, not --no-restart) hands the app back to the mounted file.  This
  # works only because drop_legacy_fallback runs *after* readiness — the
  # fallback is still intact at this point.
  restore_content_overrides --no-restart
  echo "==> Rolling back to the mounted config at ${LEGACY_FALLBACK_KEY}" >&2
  dokku_cmd config:unset "${PS_APP}" POWERSYNC_CONFIG_B64 >/dev/null
elif [ "${#CLEARED_OVERRIDES[@]}" -gt 0 ]; then
  # Nothing to restore for POWERSYNC_CONFIG_B64 — either it never changed, or
  # there is no earlier value and no mounted fallback.  The override we cleared
  # is the last state known to have served traffic, so put it back.
  echo "==> Rolling back to the content override that was masking the config" >&2
  restore_content_overrides restart
else
  echo "       No previous config to roll back to — no earlier POWERSYNC_CONFIG_B64," >&2
  echo "       no ${LEGACY_FALLBACK_KEY}, no cleared override.  Leaving the new value" >&2
  echo "       in place rather than unsetting it and leaving no config at all." >&2
  echo "       Inspect: dokku logs ${PS_APP} --tail 100" >&2
  exit 1
fi

if probe_readiness "${READINESS_URL}/probes/readiness" "${PS_ROLLBACK_READINESS_ATTEMPTS}"; then
  echo "       Rolled back — ${PS_APP} is ready on the previous config." >&2
else
  echo "       Rollback did not restore readiness — manual intervention needed." >&2
  echo "       Inspect: dokku logs ${PS_APP} --tail 100" >&2
fi
exit 1
