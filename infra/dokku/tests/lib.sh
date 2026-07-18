#!/usr/bin/env bash
# Shared assertions for the infra tests.  Sourced, not executed.
#
# Expects DOKKU_STUB_LOG and CURL_STUB_LOG to be set by the caller.

FAILURES=0

start_case() {
  printf '\n%s\n' "$1"
  : > "${DOKKU_STUB_LOG}"
  : > "${CURL_STUB_LOG}"
}

ok()  { printf '  ok   — %s\n' "$1"; }
bad() { printf '  FAIL — %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

dump_log() { printf '\n    %s' "$(cat "${DOKKU_STUB_LOG}")"; }

assert_rc() {
  local expected="$1" actual="$2" what="$3"
  if [ "${actual}" -eq "${expected}" ]; then
    ok "${what} (exit ${actual})"
  else
    bad "${what}: expected exit ${expected}, got ${actual}"
  fi
}

assert_logged() {
  if grep -q -- "$1" "${DOKKU_STUB_LOG}"; then
    ok "$2"
  else
    bad "$2 — no '$1' in:$(dump_log)"
  fi
}

assert_not_logged() {
  if grep -q -- "$1" "${DOKKU_STUB_LOG}"; then
    bad "$2 — unexpected '$1' in:$(dump_log)"
  else
    ok "$2"
  fi
}

first_line_of() { grep -n -m1 -- "$1" "${DOKKU_STUB_LOG}" | cut -d: -f1; }

# Order matters for the bootstrap: the config has to be published before the
# image is deployed, or the first container start has no config to read.
assert_logged_before() {
  local earlier="$1" later="$2" what="$3" a b
  a=$(first_line_of "${earlier}")
  b=$(first_line_of "${later}")
  if [ -z "${a}" ]; then bad "${what} — '${earlier}' never logged:$(dump_log)"; return; fi
  if [ -z "${b}" ]; then bad "${what} — '${later}' never logged:$(dump_log)"; return; fi
  if [ "${a}" -lt "${b}" ]; then
    ok "${what}"
  else
    bad "${what} — '${earlier}' (line ${a}) is not before '${later}' (line ${b})"
  fi
}

# Asserts the app's stored POWERSYNC_CONFIG_B64 decodes to the given file.
assert_published() {
  local app="$1" expected_file="$2" what="$3" want stored
  want=$(base64 < "${expected_file}" | tr -d '\n')
  stored=$(grep -m1 '^POWERSYNC_CONFIG_B64=' "${DOKKU_STUB_STATE}/${app}.env" 2>/dev/null || true)
  if [ "${stored#*=}" = "${want}" ]; then
    ok "${what}"
  else
    bad "${what}: published value does not decode to ${expected_file}"
  fi
}

assert_config_absent() {
  local app="$1" key="$2" what="$3"
  if grep -q "^${key}=" "${DOKKU_STUB_STATE}/${app}.env" 2>/dev/null; then
    bad "${what}: ${key} is still set on ${app}"
  else
    ok "${what}"
  fi
}

report() {
  echo
  if [ "${FAILURES}" -eq 0 ]; then
    echo "All checks passed."
    exit 0
  fi
  echo "${FAILURES} check(s) failed."
  exit 1
}
