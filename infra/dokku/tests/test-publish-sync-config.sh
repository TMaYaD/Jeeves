#!/usr/bin/env bash
# Tests for publish-sync-config.sh.
#
# The behaviours worth protecting are the ones with no other safety net: the
# unchanged-config no-op (it is why the publish step is safe to fire on every
# deploy), the stale-override cleanup that makes "self-heals host drift" true,
# the fail-closed pre-flight, and the readiness rollback (it is what stops an
# unattended pipeline leaving production on a bad config).
#
# `dokku` and `curl` are stubbed at the process boundary — see stubs/dokku.
#
# Usage: ./test-publish-sync-config.sh
set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PUBLISH="${TESTS_DIR}/../publish-sync-config.sh"

PS_APP="test-powersync"
BACKEND_APP="test-backend"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/state"

export PATH="${TESTS_DIR}/stubs:${PATH}"
export DOKKU_STUB_STATE="${WORK}/state"
export DOKKU_STUB_LOG="${WORK}/dokku.log"
export CURL_STUB_LOG="${WORK}/curl.log"

# Keep the retry loops instant — the tunables are env-overridable precisely so
# the timing can be collapsed here.
export PS_READINESS_INTERVAL_SECONDS=0
export PS_READINESS_ATTEMPTS=2
export PS_ROLLBACK_READINESS_ATTEMPTS=1

# shellcheck source=infra/dokku/tests/lib.sh
. "${TESTS_DIR}/lib.sh"

# ----- Fixtures ---------------------------------------------------------------
CONFIG="${WORK}/sync-config.yaml"
cp "${TESTS_DIR}/../../powersync/sync-config.yaml" "${CONFIG}"
EDITED="${WORK}/sync-config-edited.yaml"
{ cat "${CONFIG}"; printf '\n# an added bucket would look like this\n'; } > "${EDITED}"
EMPTY="${WORK}/empty.yaml"
: > "${EMPTY}"

reset_state() { rm -f "${DOKKU_STUB_STATE}"/*.env; }
seed_backend_url() {
  printf 'POWERSYNC_URL=https://powersync.example.test\n' \
    > "${DOKKU_STUB_STATE}/${BACKEND_APP}.env"
}
seed_ps_config() { printf '%s\n' "$1" >> "${DOKKU_STUB_STATE}/${PS_APP}.env"; }

publish() {
  local rc=0
  PS_CONFIG_FILE="$1" "${PUBLISH}" "${PS_APP}" "${BACKEND_APP}" >/dev/null 2>&1 || rc=$?
  return "${rc}"
}

echo "publish-sync-config.sh"

# 1. First publish on a clean, not-yet-deployed app (the bootstrap path).
#    The config must land *before* the image is deployed, so "not deployed"
#    is a legitimate state to publish into, not an error.
start_case "first publish (not yet deployed)"
reset_state
export DOKKU_STUB_DEPLOYED=false
export DOKKU_STUB_PS_REPORT_RC=0
export CURL_STUB_RC=0
rc=0; publish "${CONFIG}" || rc=$?
assert_rc 0 "${rc}" "first publish succeeds"
assert_logged "config:set ${PS_APP} POWERSYNC_CONFIG_B64" "first publish sets the config var"
assert_published "${PS_APP}" "${CONFIG}" "published value is the config file"

# 2. Re-publishing the same file must not restart the app — this is the
#    property that makes the CD step safe to run on every merge.  The inert
#    legacy fallback is still tidied away, with --no-restart, since removing it
#    changes nothing the running container is using.
start_case "unchanged, with only an inert legacy fallback"
seed_ps_config "POWERSYNC_CONFIG_PATH=/config/sync-config.yaml"
rc=0; publish "${CONFIG}" || rc=$?
assert_rc 0 "${rc}" "unchanged publish succeeds"
assert_not_logged "config:set" "unchanged publish issues no config:set (no restart)"
assert_logged "config:unset --no-restart ${PS_APP} POWERSYNC_CONFIG_PATH" \
  "the inert fallback is dropped without a restart"
assert_config_absent "${PS_APP}" "POWERSYNC_CONFIG_PATH" "stale config path is gone"
assert_published "${PS_APP}" "${CONFIG}" "published value is untouched"

# 3. With nothing stale left, the no-op path writes nothing at all.
start_case "unchanged with nothing to heal writes nothing"
rc=0; publish "${CONFIG}" || rc=$?
assert_rc 0 "${rc}" "unchanged publish succeeds"
assert_not_logged "config:set" "no config:set"
assert_not_logged "config:unset" "no config:unset"

# 3b. A content override is a different animal from the legacy fallback: it
#     replaces sync_config.content from inside our config, so while it is set
#     the published rules are not the effective ones.  Clearing it *is* a rules
#     change, so it has to restart and be verified even though
#     POWERSYNC_CONFIG_B64 itself never moved.
start_case "unchanged but masked by a content override"
reset_state
seed_backend_url
export DOKKU_STUB_DEPLOYED=true
export CURL_STUB_RC=0
printf 'POWERSYNC_CONFIG_B64=%s\n' "$(base64 < "${CONFIG}" | tr -d '\n')" \
  >> "${DOKKU_STUB_STATE}/${PS_APP}.env"
seed_ps_config "POWERSYNC_SYNC_CONFIG_B64=c3RhbGUtcnVsZXM="
rc=0; publish "${CONFIG}" || rc=$?
assert_rc 0 "${rc}" "publish succeeds"
assert_not_logged "config:set" "nothing is republished — the config never changed"
assert_logged "config:unset ${PS_APP} POWERSYNC_SYNC_CONFIG_B64" \
  "the masking override is cleared"
assert_not_logged "config:unset --no-restart ${PS_APP} POWERSYNC_SYNC_CONFIG_B64" \
  "clearing it restarts, since it changes the effective rules"
assert_config_absent "${PS_APP}" "POWERSYNC_SYNC_CONFIG_B64" "the override is gone"
if [ "$(grep -c '' "${CURL_STUB_LOG}")" -gt 0 ]; then
  ok "the resulting rules are verified by a readiness probe"
else
  bad "no readiness probe ran after the effective rules changed"
fi

# 3c. When the config *is* changing too, the override must go first — clearing
#     it afterwards would mean the probe validated rules we didn't publish.
start_case "content override is cleared before the config is published"
reset_state
seed_backend_url
seed_ps_config "POWERSYNC_SYNC_CONFIG_B64=c3RhbGUtcnVsZXM="
rc=0; publish "${CONFIG}" || rc=$?
assert_rc 0 "${rc}" "publish succeeds"
assert_logged_before "config:unset --no-restart ${PS_APP} POWERSYNC_SYNC_CONFIG_B64" \
  "config:set ${PS_APP} POWERSYNC_CONFIG_B64" \
  "the override is cleared before the config is set"

# 3d. If clearing the override turns out to break readiness, the override goes
#     back — it was the last state known to have served traffic.
start_case "override cleared, readiness fails, override restored"
reset_state
seed_backend_url
printf 'POWERSYNC_CONFIG_B64=%s\n' "$(base64 < "${CONFIG}" | tr -d '\n')" \
  >> "${DOKKU_STUB_STATE}/${PS_APP}.env"
seed_ps_config "POWERSYNC_SYNC_CONFIG_B64=c3RhbGUtcnVsZXM="
unset CURL_STUB_RC
export CURL_STUB_RC_SEQUENCE="22 22 0"
rc=0; publish "${CONFIG}" || rc=$?
assert_rc 1 "${rc}" "failed readiness fails the publish"
assert_logged "config:set ${PS_APP} POWERSYNC_SYNC_CONFIG_B64" \
  "the cleared override is restored, with a restart"
if grep -q '^POWERSYNC_SYNC_CONFIG_B64=c3RhbGUtcnVsZXM=$' "${DOKKU_STUB_STATE}/${PS_APP}.env"; then
  ok "the override is restored to its original value"
else
  bad "the override was not restored to its original value"
fi
unset CURL_STUB_RC_SEQUENCE
export CURL_STUB_RC=0
export DOKKU_STUB_DEPLOYED=false

# 4. An edited config publishes again.
start_case "changed config republishes"
rc=0; publish "${EDITED}" || rc=$?
assert_rc 0 "${rc}" "changed publish succeeds"
assert_logged "config:set ${PS_APP} POWERSYNC_CONFIG_B64" "changed publish sets the config var"
assert_published "${PS_APP}" "${EDITED}" "published value is the edited file"

# 5/6. A missing or empty config must never reach the app: publishing one would
#      take the sync layer down on the restart that follows.
start_case "missing config file"
rc=0; publish "${WORK}/does-not-exist.yaml" || rc=$?
assert_rc 1 "${rc}" "missing config file fails"
assert_not_logged "config:set" "missing config file publishes nothing"

start_case "empty config file"
rc=0; publish "${EMPTY}" || rc=$?
assert_rc 1 "${rc}" "empty config file fails"
assert_not_logged "config:set" "empty config file publishes nothing"

# 7. A dokku lookup failure must not be read as "not deployed" — that would
#    silently downgrade the publish from verified to unverified.  It happens
#    before config:set, so there is nothing to roll back.
start_case "fail-closed: cannot determine deployment state"
reset_state
seed_backend_url
export DOKKU_STUB_PS_REPORT_RC=1
rc=0; publish "${CONFIG}" || rc=$?
assert_rc 1 "${rc}" "unreachable ps:report fails the publish"
assert_not_logged "config:set" "nothing is published when the state is unknown"
export DOKKU_STUB_PS_REPORT_RC=0

# 8. Same for an unresolvable probe target on a deployed app: refuse rather
#    than publish blind and report success.
start_case "fail-closed: no readiness URL"
reset_state
export DOKKU_STUB_DEPLOYED=true
export DOKKU_STUB_VHOSTS=""
rc=0; publish "${CONFIG}" || rc=$?
assert_rc 1 "${rc}" "unresolvable readiness URL fails the publish"
assert_not_logged "config:set" "nothing is published when it cannot be verified"

# 9. On a deployed app the probe runs, and the superseded delivery keys are
#    dropped only once readiness is green.
start_case "deployed, readiness green"
reset_state
seed_backend_url
seed_ps_config "POWERSYNC_CONFIG_PATH=/config/sync-config.yaml"
export CURL_STUB_RC=0
rc=0; publish "${CONFIG}" || rc=$?
assert_rc 0 "${rc}" "publish with green readiness succeeds"
assert_logged "config:unset --no-restart ${PS_APP} POWERSYNC_CONFIG_PATH" "superseded delivery keys are dropped without a restart"
assert_logged_before "config:set ${PS_APP} POWERSYNC_CONFIG_B64" \
  "config:unset --no-restart ${PS_APP}" "keys are dropped after the publish, not before"
if grep -q "powersync.example.test/probes/readiness" "${CURL_STUB_LOG}"; then
  ok "readiness URL comes from the backend app's POWERSYNC_URL"
else
  bad "readiness URL not derived from POWERSYNC_URL: $(cat "${CURL_STUB_LOG}")"
fi

# 9b. A vhost that has lost its routing answers with a redirect, and `curl -f`
#     reports that as success.  Treating it as ready would sign off a publish
#     nothing verified — the probe has to insist on a 2xx.
start_case "a redirect is not readiness"
reset_state
seed_backend_url
printf 'POWERSYNC_CONFIG_B64=%s\n' "$(base64 < "${CONFIG}" | tr -d '\n')" \
  >> "${DOKKU_STUB_STATE}/${PS_APP}.env"
export CURL_STUB_HTTP_CODE=302
rc=0; publish "${EDITED}" || rc=$?
assert_rc 1 "${rc}" "a 302 does not count as ready"
assert_published "${PS_APP}" "${CONFIG}" "the publish is rolled back"
unset CURL_STUB_HTTP_CODE

# 10. Readiness failure with a known-good previous value: restore it, and
#     confirm the restored config is itself probed — the rollback is only
#     meaningful if we check it took.  PS_READINESS_ATTEMPTS=2 fail, then the
#     single rollback probe succeeds.
start_case "readiness fails, previous config restored"
seed_ps_config "POWERSYNC_CONFIG_PATH=/config/sync-config.yaml"
unset CURL_STUB_RC
export CURL_STUB_RC_SEQUENCE="22 22 0"
rc=0; publish "${EDITED}" || rc=$?
assert_rc 1 "${rc}" "failed readiness fails the publish"
assert_published "${PS_APP}" "${CONFIG}" "previous config is restored on rollback"
assert_not_logged "config:unset" "no keys are dropped when readiness fails"
probes=$(grep -c '' "${CURL_STUB_LOG}")
if [ "${probes}" -eq 3 ]; then
  ok "the restored config is re-probed (2 failed + 1 rollback probe)"
else
  bad "expected 3 readiness probes, saw ${probes}"
fi
unset CURL_STUB_RC_SEQUENCE

# 11. First publish into an environment bootstrapped before ADR-0017: no
#     previous base64 value, but the mounted config it supersedes is still
#     configured and is a real known-good state to fall back to.
start_case "readiness fails, rolls back to the mounted config"
reset_state
seed_backend_url
seed_ps_config "POWERSYNC_CONFIG_PATH=/config/sync-config.yaml"
export CURL_STUB_RC_SEQUENCE="22 22 0"
rc=0; publish "${CONFIG}" || rc=$?
assert_rc 1 "${rc}" "failed readiness fails the publish"
assert_logged "config:unset ${PS_APP} POWERSYNC_CONFIG_B64" \
  "our config is dropped so the mounted file takes over again"
# The restart is the rollback: without it the container keeps running on the
# config we just proved unhealthy.
assert_not_logged "config:unset --no-restart ${PS_APP} POWERSYNC_CONFIG_B64" \
  "the rollback restarts the app rather than deferring"
assert_config_absent "${PS_APP}" "POWERSYNC_CONFIG_B64" "the bad config is gone"
if grep -q "^POWERSYNC_CONFIG_PATH=" "${DOKKU_STUB_STATE}/${PS_APP}.env"; then
  ok "POWERSYNC_CONFIG_PATH is left intact as the fallback"
else
  bad "POWERSYNC_CONFIG_PATH was removed — nothing left to fall back to"
fi
unset CURL_STUB_RC_SEQUENCE

# 12. Readiness failure with nothing to roll back to at all: fail loudly
#     rather than leave the app with no config whatsoever.
start_case "readiness fails, nothing to roll back to"
reset_state
seed_backend_url
export CURL_STUB_RC=22
rc=0; publish "${CONFIG}" || rc=$?
assert_rc 1 "${rc}" "failed readiness with no prior value fails the publish"
assert_published "${PS_APP}" "${CONFIG}" "new value is left in place, not unset"
assert_not_logged "config:unset" "no keys are dropped when readiness fails"

report
