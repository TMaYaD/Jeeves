#!/usr/bin/env bash
# Download the PowerSync WASM and web-worker assets needed to run Jeeves in
# the browser.  Must be re-run whenever the `powersync` version in
# app/pubspec.lock changes — `make setup` calls this automatically.
#
# Assets are intentionally NOT committed (see app/.gitignore).  This script
# makes the download reproducible by reading the exact pinned version from
# pubspec.lock so the wasm and worker always match the Dart package.
#
# Output:
#   app/web/sqlite3.wasm
#   app/web/powersync_db.worker.js

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
LOCK_FILE="$REPO_ROOT/app/pubspec.lock"
WEB_DIR="$REPO_ROOT/app/web"

if [ ! -f "$LOCK_FILE" ]; then
  echo "ERROR: pubspec.lock not found at $LOCK_FILE" >&2
  echo "Run 'flutter pub get' inside app/ first." >&2
  exit 1
fi

# Extract the exact resolved version of the powersync package.
# pubspec.lock format:
#   powersync:
#     ...
#     version: "2.0.1"
POWERSYNC_VERSION=$(awk '
  /^  powersync:$/ { found=1; next }
  found && /^    version:/ { gsub(/"/, "", $2); print $2; exit }
  found && /^  [^ ]/ { exit }
' "$LOCK_FILE")

if [ -z "$POWERSYNC_VERSION" ]; then
  echo "ERROR: could not extract powersync version from $LOCK_FILE" >&2
  exit 1
fi

BASE_URL="https://github.com/powersync-ja/powersync.dart/releases/download/powersync-v${POWERSYNC_VERSION}"

echo "Fetching PowerSync web assets for powersync v${POWERSYNC_VERSION}..."
mkdir -p "$WEB_DIR"

curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --progress-bar \
  "${BASE_URL}/sqlite3.wasm" \
  -o "$WEB_DIR/sqlite3.wasm"

curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --progress-bar \
  "${BASE_URL}/powersync_db.worker.js" \
  -o "$WEB_DIR/powersync_db.worker.js"

echo "Done. Assets written to $WEB_DIR/"
echo "  sqlite3.wasm"
echo "  powersync_db.worker.js"
