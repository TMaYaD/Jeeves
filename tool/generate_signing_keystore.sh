#!/usr/bin/env bash
# Generates a Java keystore containing two RSA key entries — alias `release`
# and alias `dev` — and prints the keystore's base64 encoding to stdout.
#
# The output is suitable for both ANDROID_RELEASE_KEYSTORE_BASE64 and
# ANDROID_DEV_KEYSTORE_BASE64 GitHub secrets consumed by
# .github/actions/setup-android-signing. Set the matching `*-key-alias` inputs
# to `release` and `dev` respectively.
#
# Usage:
#   tool/generate_signing_keystore.sh <keystore-pw> <release-key-pw> <dev-key-pw> > keystore.b64
#
# Subject DN is read from $KEYSTORE_DN (default: a generic Jeeves DN).
set -euo pipefail

if [ "$#" -ne 3 ]; then
  cat >&2 <<'EOF'
Usage: generate_signing_keystore.sh <keystore-password> <release-key-password> <dev-key-password>

Generates a JKS keystore with two key entries (alias `release` and alias `dev`)
and writes its base64 encoding to stdout. Status messages go to stderr.

Override the certificate subject by exporting KEYSTORE_DN before running.
EOF
  exit 1
fi

storepass="$1"
release_keypass="$2"
dev_keypass="$3"
dn="${KEYSTORE_DN:-CN=Jeeves, OU=Mobile, O=loonyb.in, L=Unknown, ST=Unknown, C=US}"

if ! command -v keytool >/dev/null 2>&1; then
  echo "keytool not found on PATH; install a JDK (e.g. apt install default-jdk)." >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
keystore="$tmpdir/keystore.jks"

echo "Generating release key (alias=release)..." >&2
keytool -genkeypair \
  -alias release \
  -keyalg RSA -keysize 4096 \
  -validity 36500 \
  -dname "$dn" \
  -keystore "$keystore" -storetype JKS \
  -storepass "$storepass" -keypass "$release_keypass" >&2

echo "Generating dev key (alias=dev)..." >&2
keytool -genkeypair \
  -alias dev \
  -keyalg RSA -keysize 4096 \
  -validity 36500 \
  -dname "$dn" \
  -keystore "$keystore" -storetype JKS \
  -storepass "$storepass" -keypass "$dev_keypass" >&2

echo "Keystore contents:" >&2
keytool -list -keystore "$keystore" -storepass "$storepass" >&2

# Emit a single-line base64 blob so it pastes cleanly into a GitHub secret.
# `base64 -w0` is GNU; fall back to stripping newlines for BSD/macOS.
if base64 --help 2>&1 | grep -q -- '-w'; then
  base64 -w0 "$keystore"
else
  base64 "$keystore" | tr -d '\n'
fi
echo
