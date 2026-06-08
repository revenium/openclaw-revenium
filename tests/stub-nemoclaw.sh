#!/usr/bin/env bash
# stub-nemoclaw.sh — Argv-capturing nemoclaw stub for integration tests.
#
# Phase 13 hermetic test harness companion. Place a symlink named "nemoclaw"
# on PATH pointing at this script (or ln -sf directly).
# Set STUB_NEMOCLAW_ARGV_FILE to the path of a file where captured args are
# appended (one arg per line per invocation).
#
# Usage:
#   export STUB_NEMOCLAW_ARGV_FILE="$(mktemp)"
#   mkdir -p /tmp/test-nem-bin
#   ln -sf "$(pwd)/tests/stub-nemoclaw.sh" /tmp/test-nem-bin/nemoclaw
#   export PATH=/tmp/test-nem-bin:$PATH
#   # ... run script under test ...
#   grep -- "policy-add" "${STUB_NEMOCLAW_ARGV_FILE}"
#
# Environment switches:
#
#   STUB_NEMOCLAW_CURL_HTTP_CODE (default "403")
#     Controls the http_code value echoed when the exec payload contains an
#     http_code probe to api.revenium.ai. Set to "000" to simulate a proxy
#     block (CONNECT tunnel failed). Set to "403" (default) to simulate open
#     egress with a server-side auth rejection, proving the proxy allows it.
#
#   STUB_NEMOCLAW_SHA256_MATCH (default "1")
#     When "0", the sha256/tarball exec path echoes "CHECKSUM_MISMATCH:badhash"
#     to stderr and exits 2 (aborted install). When "1" (default), echoes the
#     pinned tarball sha256 followed by CLI_DELIVERED_OK.
#
#   STUB_NEMOCLAW_METER_FAIL (set/non-empty)
#     When set, the meter completion exec path echoes a non-2xx/bad JSON body
#     to stderr and exits 1 (meter probe failed). When unset (default), echoes
#     a 2xx success body.
#
# SECURITY (T-13-SC): this stub only string-COMPAREs positional args and
# captures them with `printf '%s\n'`. It NEVER `eval`s or string-interpolates
# captured argv into a shell command.

# No -e: we manage exits explicitly per subcommand dispatch
set -uo pipefail

# ---------------------------------------------------------------------------
# 1. Argv capture (always first — every token is assertable)
# ---------------------------------------------------------------------------
if [[ -n "${STUB_NEMOCLAW_ARGV_FILE:-}" ]]; then
  for arg in "$@"; do
    printf '%s\n' "${arg}" >> "${STUB_NEMOCLAW_ARGV_FILE}"
  done
fi

# ---------------------------------------------------------------------------
# 2. Subcommand dispatch
#    argv layout: nemoclaw <sandbox> <subcommand> [subcommand-args...]
#    $1 = sandbox name, $2 = subcommand (policy-add, exec, policy-list, ...)
# ---------------------------------------------------------------------------

# policy-add — print a "Policy version loaded." confirmation and exit 0.
# Handles: nemoclaw <sandbox> policy-add --from-file <file> [--yes|--dry-run]
if [[ "${2:-}" == "policy-add" ]]; then
  echo "Policy version loaded."
  exit 0
fi

# policy-list — print an empty preset list and exit 0.
if [[ "${2:-}" == "policy-list" ]]; then
  echo "Active presets: (none)"
  exit 0
fi

# exec — dispatch based on the exec payload content.
# Detects payload type by string-comparing captured argv with grep -qF.
if [[ "${2:-}" == "exec" ]]; then
  # Capture the combined exec payload (all remaining args after "exec")
  # into a single string for pattern inspection.
  # SECURITY: only string-comparison (grep -qF), never eval.
  _payload_file=$(mktemp)
  for arg in "$@"; do
    printf '%s\n' "${arg}" >> "${_payload_file}"
  done

  # --- HTTP code probe (api.revenium.ai egress check) ---
  # Pattern: payload contains "http_code" AND "api.revenium.ai"
  if grep -qF "http_code" "${_payload_file}" && grep -qF "api.revenium.ai" "${_payload_file}"; then
    rm -f "${_payload_file}"
    echo "${STUB_NEMOCLAW_CURL_HTTP_CODE:-403}"
    exit 0
  fi

  # --- SHA256 / tarball delivery ---
  # Pattern: payload contains "sha256sum" or "SHA256" (tarball verify + deliver)
  if grep -qFi "sha256" "${_payload_file}"; then
    rm -f "${_payload_file}"
    if [[ "${STUB_NEMOCLAW_SHA256_MATCH:-1}" == "0" ]]; then
      echo "CHECKSUM_MISMATCH:badhash" >&2
      exit 2
    else
      # Emit the pinned tarball sha256 followed by CLI_DELIVERED_OK
      echo "cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67  rev.tgz"
      echo "CLI_DELIVERED_OK"
      exit 0
    fi
  fi

  # --- Meter completion probe ---
  # Pattern: payload contains "meter completion" or "meter" AND "completion"
  if grep -qF "meter completion" "${_payload_file}" || \
     ( grep -qF "meter" "${_payload_file}" && grep -qF "completion" "${_payload_file}" ); then
    rm -f "${_payload_file}"
    if [[ -n "${STUB_NEMOCLAW_METER_FAIL:-}" ]]; then
      echo '{"error":"unauthorized"}' >&2
      exit 1
    else
      echo '{"status":"ok","metered":true}'
      exit 0
    fi
  fi

  rm -f "${_payload_file}"
  # Default exec: exit 0 (unrecognized payload — pass through)
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Default — any other subcommand exits 0 (sandbox-list, help, etc.)
# ---------------------------------------------------------------------------
exit 0
