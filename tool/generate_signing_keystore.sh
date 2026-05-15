#!/usr/bin/env bash
# Generates a Java keystore containing two RSA key entries — alias `release`
# and alias `dev` — and uploads the eight Android signing secrets the
# .github/actions/setup-android-signing composite action expects (see #301).
#
# Usage:
#   tool/generate_signing_keystore.sh [OPTIONS] <store-pw> <release-key-pw> <dev-key-pw>
#
# Options:
#   --repo OWNER/REPO   Target repo for `gh secret set`. Defaults to whichever
#                       repo `gh` detects from the current working directory.
#   --no-secrets        Don't touch GitHub. Print the base64 blob to stdout.
#   -h, --help          Show this help.
#
# Secrets written (default mode):
#   ANDROID_RELEASE_KEYSTORE_BASE64   = <base64 of keystore>
#   ANDROID_RELEASE_KEYSTORE_PASSWORD = <store-pw>
#   ANDROID_RELEASE_KEY_ALIAS         = release
#   ANDROID_RELEASE_KEY_PASSWORD      = <release-key-pw>
#   ANDROID_DEV_KEYSTORE_BASE64       = <base64 of keystore>  (same blob)
#   ANDROID_DEV_KEYSTORE_PASSWORD     = <store-pw>
#   ANDROID_DEV_KEY_ALIAS             = dev
#   ANDROID_DEV_KEY_PASSWORD          = <dev-key-pw>
#
# Override the certificate subject DN by exporting KEYSTORE_DN.
#
# Note: passwords appear in argv, which is world-readable in /proc on a busy
# host. On a single-user dev machine this is fine; for shared hosts, pipe a
# wrapper that calls `read -s`.
set -euo pipefail

usage() {
  sed -n 's/^# \{0,1\}//;6,29p' "$0"
}

repo=""
set_secrets=true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --no-secrets) set_secrets=false; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) break ;;
  esac
done

if [ "$#" -ne 3 ]; then
  usage >&2
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
if [ "$set_secrets" = "true" ] && ! command -v gh >/dev/null 2>&1; then
  echo "gh not found on PATH; install GitHub CLI or pass --no-secrets." >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
# JKS, not PKCS12: keytool's PKCS12 writer silently forces every key password
# to equal the store password ("Different store and key passwords not
# supported for PKCS12 KeyStores. Ignoring user-specified -keypass value."),
# which would collapse the three-password contract this script offers down
# to one. JKS preserves distinct per-key passwords.
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

if base64 --help 2>&1 | grep -q -- '-w'; then
  b64="$(base64 -w0 "$keystore")"
else
  b64="$(base64 "$keystore" | tr -d '\n')"
fi

if [ "$set_secrets" = "false" ]; then
  printf '%s\n' "$b64"
  exit 0
fi

repo_args=()
[ -n "$repo" ] && repo_args=(--repo "$repo")

set_secret() {
  local name="$1" value="$2"
  printf '%s' "$value" | gh secret set "$name" "${repo_args[@]}"
  echo "  set $name" >&2
}

echo "Writing 8 secrets via gh${repo:+ to $repo}..." >&2
set_secret ANDROID_RELEASE_KEYSTORE_BASE64    "$b64"
set_secret ANDROID_RELEASE_KEYSTORE_PASSWORD  "$storepass"
set_secret ANDROID_RELEASE_KEY_ALIAS          "release"
set_secret ANDROID_RELEASE_KEY_PASSWORD       "$release_keypass"
set_secret ANDROID_DEV_KEYSTORE_BASE64        "$b64"
set_secret ANDROID_DEV_KEYSTORE_PASSWORD      "$storepass"
set_secret ANDROID_DEV_KEY_ALIAS              "dev"
set_secret ANDROID_DEV_KEY_PASSWORD           "$dev_keypass"

echo "Done." >&2
