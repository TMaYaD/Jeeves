#!/usr/bin/env bash
# Ordering regression test for deploy-powersync.sh's bootstrap flow.
#
# The invariant under test is that the sync config is published *after* the
# PowerSync env vars are set and *before* `git:from-image` deploys the image.
# Get that order wrong and a fresh environment's first container start has no
# config to read — the failure is at bring-up time, on a host, with nothing in
# CI to catch it.  The publisher itself is covered separately in
# test-publish-sync-config.sh; this exercises the real wiring between the two
# scripts rather than mocking the publisher out.
#
# Both bootstrap shapes are covered, because they take different paths through
# the publisher: a fresh app has no container, so the publish is unverified by
# design and the script's own smoke test is the only check; a re-run against a
# live app goes through readiness probing and rollback.
#
# Usage: ./test-deploy-powersync.sh
set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DEPLOY="${TESTS_DIR}/../deploy-powersync.sh"
REPO_CONFIG="${TESTS_DIR}/../../powersync/sync-config.yaml"

PS_APP="test-powersync"
BACKEND_APP="test-backend"
PS_DOMAIN="powersync.example.test"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/state"

# stubs/bootstrap is layered on top for `id` (the script demands root) and
# `sleep` (its retry loops would otherwise cost ~60s of real waiting).
export PATH="${TESTS_DIR}/stubs/bootstrap:${TESTS_DIR}/stubs:${PATH}"
export DOKKU_STUB_STATE="${WORK}/state"
export DOKKU_STUB_LOG="${WORK}/dokku.log"
export CURL_STUB_LOG="${WORK}/curl.log"

export PS_READINESS_INTERVAL_SECONDS=0
export PS_READINESS_ATTEMPTS=2

# shellcheck source=infra/dokku/tests/lib.sh
. "${TESTS_DIR}/lib.sh"

export DOKKU_STUB_PS_REPORT_RC=0
export DOKKU_STUB_WAL_LEVEL=logical
export CURL_STUB_RC=0

run_bootstrap() {
  local rc=0
  "${DEPLOY}" "${PS_APP}" "${BACKEND_APP}" "${PS_DOMAIN}" >"${WORK}/out.txt" 2>&1 || rc=$?
  if [ "${rc}" -ne 0 ]; then
    printf '  (bootstrap output)\n'
    sed 's/^/    /' "${WORK}/out.txt"
  fi
  return "${rc}"
}

# The ordering assertions are the point of this file and apply to both shapes.
assert_bootstrap_ordering() {
  assert_logged_before "config:set --no-restart ${PS_APP} NODE_OPTIONS" \
    "config:set ${PS_APP} POWERSYNC_CONFIG_B64" \
    "env vars are set before the config is published"
  assert_logged_before "config:set ${PS_APP} POWERSYNC_CONFIG_B64" "git:from-image" \
    "config is published before the image is deployed"
  assert_logged_before "git:from-image" "letsencrypt:enable" \
    "image is deployed before Let's Encrypt"
  # Nothing should mount storage any more — that is what made the old flow
  # need root, and root is what CI does not have.
  assert_not_logged "storage:mount" "bootstrap mounts no storage"
}

echo "deploy-powersync.sh"

# ----- Case 1: a fresh environment -------------------------------------------
# Nothing exists yet: no app, no postgres link, no domain, no container.  The
# publish still has to happen before the image deploy, and the publisher has to
# take its undeployed-app path rather than trying to probe a container that
# isn't there.
start_case "fresh bootstrap (app does not exist yet)"
rm -f "${DOKKU_STUB_STATE}"/*.env
cat > "${DOKKU_STUB_STATE}/${BACKEND_APP}.env" <<EOF
SECRET_KEY=test-secret
DATABASE_URL=postgres://u:p@dokku-postgres-jeeves-db:5432/jeeves
EOF
export DOKKU_STUB_APP_EXISTS=false
export DOKKU_STUB_DEPLOYED=false
export DOKKU_STUB_VHOSTS=""
export DOKKU_STUB_PG_LINKS=""

rc=0; run_bootstrap || rc=$?
assert_rc 0 "${rc}" "fresh bootstrap completes"
assert_logged "apps:create ${PS_APP}" "the app is created"
assert_logged "postgres:link" "postgres is linked"
assert_logged "config:set ${PS_APP} POWERSYNC_CONFIG_B64" \
  "the sync config is published into the new app"
assert_published "${PS_APP}" "${REPO_CONFIG}" "published value is the repo's sync-config.yaml"
assert_bootstrap_ordering
assert_logged_before "postgres:link" "config:set ${PS_APP} POWERSYNC_CONFIG_B64" \
  "postgres is linked before the config is published"
assert_logged "domains:set ${PS_APP} ${PS_DOMAIN}" "the domain is set"
# The publisher must not probe a container that does not exist.  The one curl
# in this run is the bootstrap's own smoke test, after the deploy.
probes=$(grep -c '' "${CURL_STUB_LOG}")
if [ "${probes}" -eq 1 ]; then
  ok "publisher skips readiness on an undeployed app (only the smoke test probes)"
else
  bad "expected 1 probe (the smoke test), saw ${probes}: $(cat "${CURL_STUB_LOG}")"
fi

# ----- Case 2: a re-run against a live environment ---------------------------
# The documented path for an image bump.  Everything already exists, so the
# publisher goes through readiness probing, and a pre-ADR-0017 leftover gets
# cleaned up on the way.
start_case "bootstrap re-run against an existing environment"
rm -f "${DOKKU_STUB_STATE}"/*.env
cat > "${DOKKU_STUB_STATE}/${BACKEND_APP}.env" <<EOF
SECRET_KEY=test-secret
DATABASE_URL=postgres://u:p@dokku-postgres-jeeves-db:5432/jeeves
POWERSYNC_URL=https://${PS_DOMAIN}
EOF
# A leftover mount path from a pre-ADR-0017 bootstrap, so the cleanup is
# observable in this flow too.
cat > "${DOKKU_STUB_STATE}/${PS_APP}.env" <<EOF
DATABASE_URL=postgres://u:p@dokku-postgres-jeeves-db:5432/jeeves
POWERSYNC_CONFIG_PATH=/config/sync-config.yaml
EOF
export DOKKU_STUB_APP_EXISTS=true
export DOKKU_STUB_DEPLOYED=true
export DOKKU_STUB_VHOSTS="${PS_DOMAIN}"
export DOKKU_STUB_PG_LINKS="${PS_APP}"

rc=0; run_bootstrap || rc=$?
assert_rc 0 "${rc}" "re-run completes"
assert_not_logged "apps:create" "an existing app is not recreated"
assert_logged "config:set ${PS_APP} POWERSYNC_CONFIG_B64" \
  "the sync config is published to the powersync app"
assert_published "${PS_APP}" "${REPO_CONFIG}" "published value is the repo's sync-config.yaml"
assert_bootstrap_ordering

# BACKEND_APP is threaded through to the publisher: it is what resolves the
# readiness URL, and it is looked up before the image deploy — the later
# POWERSYNC_URL read in the wire-backend step happens after it.
assert_logged_before "config:get ${BACKEND_APP} POWERSYNC_URL" "git:from-image" \
  "backend app is passed to the publisher (readiness URL resolved pre-deploy)"

# The mount-era config path is cleaned up as part of the same run.
assert_config_absent "${PS_APP}" "POWERSYNC_CONFIG_PATH" \
  "legacy POWERSYNC_CONFIG_PATH is dropped"

report
