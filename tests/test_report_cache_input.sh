#!/usr/bin/env bash
# =============================================================================
# test_report_cache_input.sh: report.sh sends the input token count each
# provider's own usage object reports.
#
# OpenClaw's pi-ai usage object stores `input` with the cache read (and any
# cache write) already taken out, for every provider. Revenium takes the cache
# read out of the input itself on OpenAI-family models (OpenAI, Azure OpenAI,
# xAI, Groq, Gemini), so those must be sent input + cacheRead. Anthropic's
# input already leaves the cache out and is sent as stored.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPORT_SH="${REPO_ROOT}/scripts/report.sh"
STUB_SH="${SCRIPT_DIR}/stub-revenium.sh"

# shellcheck source=lib/mk-session-store.sh
. "${SCRIPT_DIR}/lib/mk-session-store.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

TMP_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-rci-home.XXXXXX")
TMP_FAKE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-rci-fakehome.XXXXXX")
ARGV_FILE=$(mktemp "${TMPDIR:-/tmp}/test-rci-argv.XXXXXX")
cleanup() { rm -rf "${TMP_HOME}" "${TMP_FAKE_HOME}" "${ARGV_FILE}" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "${TMP_HOME}/skills/revenium" "${TMP_FAKE_HOME}/.local/bin"
echo '{}' > "${TMP_HOME}/revenium-offsets.json"
touch "${TMP_HOME}/revenium-reported.ledger"
ln -sf "${STUB_SH}" "${TMP_FAKE_HOME}/.local/bin/revenium"
export STUB_REVENIUM_ARGV_FILE="${ARGV_FILE}"

DB="${TMP_HOME}/agents/main/agent/openclaw-agent.sqlite"
mk_store "${DB}"

# usage_event <seq> <response_id> <model> <input> <cacheRead> <cacheWrite> <timestamp>
usage_event() {
  local seq="$1" rid="$2" model="$3" input="$4" read="$5" write="$6" ts="$7"
  local output=50
  printf '{"type":"message","id":"msg-%s","parentId":"parent-%s","timestamp":"%s","message":{"role":"assistant","content":[{"type":"text","text":"ok"}],"api":"openai-completions","provider":"openai","model":"%s","usage":{"input":%s,"output":%s,"cacheRead":%s,"cacheWrite":%s,"totalTokens":%s},"stopReason":"stop","timestamp":1790224153946,"responseId":"%s","responseModel":"%s","__openclaw":{"runId":"run-1"}}}' \
    "${seq}" "${seq}" "${ts}" "${model}" "${input}" "${output}" "${read}" "${write}" \
    "$((input + output + read + write))" "${rid}" "${model}"
}

SID="eeeeeeee-5555-5555-5555-000000000005"
mk_session "${DB}" "${SID}" "agent:main:${SID}" "" 100
mk_event "${DB}" "${SID}" 0 "$(usage_event 0 resp-gpt gpt-5.1 1000 4000 0 2026-01-01T10:00:00.000Z)"
mk_event "${DB}" "${SID}" 1 "$(usage_event 1 resp-gemini gemini-2.5-pro 200 800 0 2026-01-01T10:01:00.000Z)"
mk_event "${DB}" "${SID}" 2 "$(usage_event 2 resp-grok grok-4 300 700 0 2026-01-01T10:02:00.000Z)"
mk_event "${DB}" "${SID}" 3 "$(usage_event 3 resp-write gpt-5.1 100 600 50 2026-01-01T10:03:00.000Z)"
mk_event "${DB}" "${SID}" 4 "$(usage_event 4 resp-claude claude-sonnet-4-6 74 4000 100 2026-01-01T10:04:00.000Z)"

OPENCLAW_HOME="${TMP_HOME}" HOME="${TMP_FAKE_HOME}" bash "${REPORT_SH}" >/dev/null 2>&1 || true

# Each `meter completion` call appends its argv one per line; pair each
# --transaction-id with the --input-tokens and --cache-read-tokens of that call.
sent() {
  local rid="$1" flag="$2"
  awk -v rid="${rid}" -v flag="${flag}" '
    /^meter$/ { inmeter = 1; val = ""; id = ""; next }
    prev == flag { val = $0 }
    prev == "--transaction-id" { id = $0 }
    { prev = $0 }
    inmeter && id == rid && val != "" { print val; exit }
  ' "${ARGV_FILE}"
}

expect() {
  local rid="$1" flag="$2" want="$3" why="$4"
  local got
  got="$(sent "${rid}" "${flag}")"
  if [[ "${got}" == "${want}" ]]; then
    pass "${why}"
  else
    fail "${why}: ${flag} expected ${want}, got '${got}'"
  fi
}

expect resp-gpt     --input-tokens      5000 "OpenAI input includes the cache read"
expect resp-gpt     --cache-read-tokens 4000 "OpenAI cache read is still sent on its own"
expect resp-gemini  --input-tokens      1000 "Gemini input includes the cache read"
expect resp-grok    --input-tokens      1000 "xAI input includes the cache read"
expect resp-write   --input-tokens      700  "OpenAI input adds the read but not the cache write"
expect resp-claude  --input-tokens      74   "Anthropic input stays without the cache"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
