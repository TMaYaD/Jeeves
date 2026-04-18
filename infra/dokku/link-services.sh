#!/usr/bin/env bash
# Wire the backend app to know the PowerSync URL, and restart both apps.
# Idempotent: safe to re-run at any time.
#
# Assumptions:
#   - The PowerSync Dokku app is named "powersync"
#   - The backend Dokku app is named "jeeves"
#   - Both apps have a global virtual-host domain configured
set -euo pipefail

BACKEND_APP=jeeves
POWERSYNC_APP=powersync

echo "==> Linking services: ${POWERSYNC_APP} -> ${BACKEND_APP}"

# Resolve the PowerSync public domain (first global vhost, in case multiple are returned).
PS_DOMAINS=$(dokku domains:report "${POWERSYNC_APP}" --domains-global-vhosts 2>/dev/null | head -1 | tr -d '[:space:]')
PS_DOMAIN="${PS_DOMAINS%%,*}"

if [ -z "${PS_DOMAIN}" ]; then
  echo "ERROR: Could not determine domain for ${POWERSYNC_APP}."
  echo "       Run: dokku domains:add ${POWERSYNC_APP} <your-domain>"
  exit 1
fi

PS_URL="https://${PS_DOMAIN}"
echo "    PowerSync URL: ${PS_URL}"

# Set the PowerSync URL on the backend.
dokku config:set --no-restart "${BACKEND_APP}" \
  JEEVES_POWERSYNC_URL="${PS_URL}"
echo "    Set JEEVES_POWERSYNC_URL on ${BACKEND_APP}"

# Restart both apps to pick up the new config.
dokku ps:restart "${POWERSYNC_APP}"
dokku ps:restart "${BACKEND_APP}"
echo "    Restarted ${POWERSYNC_APP} and ${BACKEND_APP}"

echo "==> Done: services linked"
