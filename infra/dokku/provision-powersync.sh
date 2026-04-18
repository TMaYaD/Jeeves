#!/usr/bin/env bash
# Provision the PowerSync Dokku app from the official pre-built image.
# Idempotent: safe to re-run at any time.
set -euo pipefail

APP=powersync
IMAGE=journeyapps/powersync-service:1.20.5

echo "==> Provisioning Dokku app: ${APP}"

# Create app if it doesn't already exist.
if ! dokku apps:list 2>/dev/null | grep -qx "${APP}"; then
  dokku apps:create "${APP}"
  echo "    Created app ${APP}"
else
  echo "    App ${APP} already exists, skipping create"
fi

# Deploy from pre-built Docker image (no git push needed).
dokku git:from-image "${APP}" "${IMAGE}"
echo "    Deployed image ${IMAGE}"

# Map container port 8080 to HTTP 80.
if ! dokku ports:list "${APP}" 2>/dev/null | grep -q "80:8080"; then
  dokku ports:set "${APP}" http:80:8080
  echo "    Set port mapping http:80:8080"
fi

# Set NODE memory limit (~80% of available RAM; adjust as needed).
dokku resource:limit --memory 400m "${APP}" || true
echo "    Resource limit set"

echo "==> Done: ${APP} provisioned"
