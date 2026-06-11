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
# SECURITY (T-13-SC / T-16-SC): this stub only string-COMPAREs positional
# args and captures them with `printf '%s\n'`. It NEVER `eval`s or
# string-interpolates captured argv into a shell command.
#
# Additional environment switches (Phase 16):
#
#   STUB_NEMOCLAW_SKILL_INSTALL_RC (default "0")
#     Controls the exit code of a `nemoclaw <sandbox> skill install <dir>`
#     invocation. Set to "1" to simulate a failed skill install.
#
#   STUB_NEMOCLAW_SKILL_NOT_READY (set/non-empty)
#     When set, the `openclaw skills list` exec payload echoes a non-matching
#     line ("No skills installed.") and exits 0. When unset (default), echoes
#     the ready line.
#
#   STUB_NEMOCLAW_SKILLS_LIST_OUTPUT (default "✓ ready  💰 revenium")
#     Override the default output for the `openclaw skills list` exec path.
#
# Enforcement-plugin gate switches (Gate A / Gate B — v2026.5.22 probe shapes):
#
#   STUB_NEMOCLAW_PROMPT_CHARS (default "1637")
#     promptChars value echoed by the `openclaw agent --json` probe (Gate A).
#     Set below 1500 (e.g. "649") to simulate the no-injection baseline so Gate A
#     fails.
#
#   STUB_NEMOCLAW_PLUGIN_STATUS (default "loaded")
#     The `Status:` value echoed by `openclaw plugins inspect` (Gate B). Set to a
#     non-"loaded" value (e.g. "error") to simulate an untrusted/inert plugin.
#
#   STUB_NEMOCLAW_PLUGIN_CONV_ACCESS (default "true")
#     The `allowConversationAccess:` value echoed by `openclaw plugins inspect`
#     (Gate B). Set "false" to simulate allowConversationAccess not taking effect.

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
# 1b. Reject newline/CR in any argv element — mirrors real NemoClaw gRPC exec,
#     which returns InvalidArgument: "command argument N contains newline or
#     carriage return characters". A heredoc passed as a single `sh -lc` arg
#     embeds newlines and is rejected by the real CLI; enforcing it here makes
#     the no-multiline-argv constraint hermetically testable (Phase 13
#     live-smoke finding — caught at the credential-write step).
# ---------------------------------------------------------------------------
_argn=0
for arg in "$@"; do
  _argn=$((_argn + 1))
  case "${arg}" in
    *$'\n'*|*$'\r'*)
      echo "Error:   × status: InvalidArgument, message: \"command argument ${_argn} contains newline or carriage return characters\"" >&2
      exit 1
      ;;
  esac
done

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

# share — nemoclaw <sandbox> share mount <src> <dst>
# Exits STUB_SSHFS_RC (default 0) to simulate mount success/failure
# independently of the sshfs stub (GROUP A/B need mount to fail via nemoclaw).
if [[ "${2:-}" == "share" ]]; then
  exit "${STUB_SSHFS_RC:-0}"
fi

# skill install — nemoclaw <sandbox> skill install <dir>
# Exits STUB_NEMOCLAW_SKILL_INSTALL_RC (default 0) to simulate success/failure.
if [[ "${2:-}" == "skill" && "${3:-}" == "install" ]]; then
  exit "${STUB_NEMOCLAW_SKILL_INSTALL_RC:-0}"
fi

# status — nemoclaw <sandbox> status
# Prints a status block with an `Id:` (the sandbox instance UUID), which
# post-install-nemoclaw.sh greps to scope the provisioning ledger per-sandbox.
#   STUB_NEMOCLAW_SANDBOX_UUID  (default a fixed zero UUID) — the id to emit.
#   STUB_NEMOCLAW_STATUS_NO_ID  (set/non-empty) — omit the Id line so the script
#                               falls back to scoping the ledger by sandbox name.
if [[ "${2:-}" == "status" ]]; then
  echo "  Sandbox: ${1:-unknown}"
  if [[ -z "${STUB_NEMOCLAW_STATUS_NO_ID:-}" ]]; then
    echo "  Id: ${STUB_NEMOCLAW_SANDBOX_UUID:-00000000-0000-0000-0000-000000000000}"
  fi
  echo "  Name: ${1:-unknown}"
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
    _hc="${STUB_NEMOCLAW_CURL_HTTP_CODE:-403}"
    echo "${_hc}"
    # Proxy block: real curl writes "000" AND exits non-zero (CONNECT tunnel
    # failed), so `nemoclaw exec` propagates a non-zero exit. Mirror that here so
    # GROUP-A exercises the egress-detection path that keys on the exec exit code,
    # not just stdout (CR-01/WR-01). Open egress (4xx) keeps a zero exit.
    [[ "${_hc}" == "000" ]] && exit 1
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

  # --- openclaw skills list (skill discovery assertion, D-02) ---
  # Pattern: payload contains "openclaw skills list"
  # SECURITY: string-compare only, never eval (T-16-SC).
  if grep -qF "openclaw skills list" "${_payload_file}"; then
    rm -f "${_payload_file}"
    if [[ -n "${STUB_NEMOCLAW_SKILL_NOT_READY:-}" ]]; then
      echo "No skills installed."
      exit 0
    else
      echo "${STUB_NEMOCLAW_SKILLS_LIST_OUTPUT:-✓ ready  💰 revenium}"
      exit 0
    fi
  fi

  # --- openclaw agents list (Gate A: derive the default agent id) ---
  # Pattern: payload contains "openclaw agents list" (note the plural "agents").
  # Mirrors v2026.5.22 output so install_enforcement_plugin()'s awk derivation
  # resolves the "(default)" agent. Must precede the "openclaw agent" --json
  # handler below ("openclaw agents list" contains "openclaw agent" as a
  # substring but never "--json", so order is defensive clarity).
  # SECURITY: string-compare only (T-16-SC).
  if grep -qF "openclaw agents list" "${_payload_file}"; then
    rm -f "${_payload_file}"
    echo "Agents:"
    echo "- main (default)"
    exit 0
  fi

  # --- openclaw agent --json (Gate A: promptChars check for enforcement plugin) ---
  # Pattern: payload contains "openclaw agent" AND "--json" (literal dashes).
  # The real v2026.5.22 probe is `openclaw agent --agent <id> --json --message ping`;
  # this matches regardless of the --agent target. Returns a stub JSON body with
  # promptChars above the 1500 threshold so Gate A passes in the hermetic suite.
  # STUB_NEMOCLAW_PROMPT_CHARS (default 1637) overrides the value for negative tests.
  # SECURITY: string-compare only (T-16-SC).
  if grep -qF "openclaw agent" "${_payload_file}" && grep -qF -- "--json" "${_payload_file}"; then
    rm -f "${_payload_file}"
    echo "{\"currentTurn\":{\"promptChars\":${STUB_NEMOCLAW_PROMPT_CHARS:-1637},\"completionChars\":0}}"
    exit 0
  fi

  # --- openclaw plugins inspect (Gate B: loaded + allowConversationAccess) ---
  # Pattern: payload contains "openclaw plugins inspect".
  # Mirrors v2026.5.22 inspect output: "Status: loaded" + a Policy block with
  # "allowConversationAccess: true" (hook names are NO LONGER enumerated in this
  # OpenClaw version — Gate B asserts loaded + allowConversationAccess instead).
  # Switches for negative tests:
  #   STUB_NEMOCLAW_PLUGIN_STATUS       (default "loaded") — set e.g. "error" to fail Gate B's load check
  #   STUB_NEMOCLAW_PLUGIN_CONV_ACCESS  (default "true")   — set "false" to fail Gate B's access check
  # SECURITY: string-compare only (T-16-SC).
  if grep -qF "openclaw plugins inspect" "${_payload_file}"; then
    rm -f "${_payload_file}"
    echo "Revenium Enforcement"
    echo "id: revenium-enforcement"
    echo "Status: ${STUB_NEMOCLAW_PLUGIN_STATUS:-loaded}"
    echo "Policy:"
    echo "  allowConversationAccess: ${STUB_NEMOCLAW_PLUGIN_CONV_ACCESS:-true}"
    exit 0
  fi

  # --- python3 --version (Gate C: python3 preflight for write-marker.sh) ---
  # Pattern: payload contains "python3 --version"
  if grep -qF "python3 --version" "${_payload_file}"; then
    rm -f "${_payload_file}"
    echo "Python 3.11.0"
    exit 0
  fi

  # --- write-marker.sh smoke test (Gate D) ---
  # Pattern: payload contains "write-marker.sh"
  # Creates a stub .jsonl file in the expected mount location so the ls check passes.
  # SECURITY: only the stub-controlled path is written to; no user input evaluated.
  if grep -qF "write-marker.sh" "${_payload_file}"; then
    rm -f "${_payload_file}"
    exit 0
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
      # Mirror the REAL authenticated-success shape: the created metered-event
      # resource object (id + resourceType + signature), NOT a {"status":200}
      # envelope (Phase 13 live-smoke: id 36597852-…, resourceType metered-event).
      echo '{"id":"stub-00000000-0000-0000-0000-000000000000","label":"metered-event","resourceType":"metered-event","signature":"stubsig00000000","created":"2026-01-01T00:00:00.000Z","updated":"2026-01-01T00:00:00.000Z"}'
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
