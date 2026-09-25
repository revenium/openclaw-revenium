#!/usr/bin/env bash
# =============================================================================
# test_report_tool_argv.sh — Integration tests for report.sh tool registry
# and tool-event metering (TOOLEV-01..04)
#
# Phase 19 (D-01/D-19): rebuilt on the synthetic-SQLite fixture harness
# (tests/lib/mk-session-store.sh) — report.sh's toolCall scan now reads
# store_tool_calls directly instead of scanning a transcript file. Every
# pre-existing GROUP below is unchanged in INTENT; only the fixture
# construction changed (mk_session/mk_assistant_event/mk_toolcall_pair
# instead of writing JSONL lines). GROUP TR is new — the five <behavior>
# cases from the plan's tracer task.
#
# Strategy:
#   Build one synthetic SQLite store per group at the real
#   agents/<agentId>/agent/openclaw-agent.sqlite layout (store_db_paths'
#   glob is exercised, not bypassed). The canonical fixture (GROUPs T/I/X/P)
#   holds:
#     - One TOOL_CALL completion (resp-001, stopReason toolUse, 150 tokens)
#     - One CHAT completion (resp-002, stopReason stop, 380 tokens)
#     - One toolCall (toolu_test001, name=read) with toolResult 250ms later
#   Real live-store evidence (sample-rows.txt) shows the toolCall-bearing
#   assistant row and the usage-bearing completion row are NOT necessarily
#   the same row (an agentic loop's tool-invoking turn and its token-usage
#   summary can be separate transcript_events rows) — the fixture models
#   this as two distinct events rather than conflating them into one, which
#   is also why store_tool_calls' correlation is a real SQL JOIN keyed on
#   toolCallId rather than a same-message assumption.
#   - Tool registry should register "read" as CUSTOM (BUILTIN is not a valid API enum)
#   - Tool-event should emit for toolu_test001 with --duration-ms 250 --success
#
# SECURITY (T-04-09 / V5):
#   - This test never `eval`s or string-interpolates captured argv.
#   - All argv assertions use grep or awk on the argv capture file.
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

# ---------------------------------------------------------------------------
# count_grep <pattern> <file>
#   Returns the count of matching lines in <file>.
#   Uses "; exit 0" to prevent grep -c exit-1 (no match) from triggering
#   || echo 0 double-output bug (test_report_jobs_argv.sh pattern).
# ---------------------------------------------------------------------------
count_grep() {
  local pattern="$1" file="${2:-/dev/null}"
  local r
  r=$(grep -c "${pattern}" "${file}" 2>/dev/null; exit 0)
  echo "${r:-0}"
}

# ---------------------------------------------------------------------------
# argv_vals <flag> <argv_file>
#   Given a flag (e.g. "--name") and an argv file, prints the value(s) that
#   follow the flag in the file. Uses awk to find the flag line and print next.
# ---------------------------------------------------------------------------
argv_vals() {
  local flag="$1" afile="${2:-/dev/null}"
  awk -v flag="${flag}" '$0==flag{getline;print}' "${afile}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# count_adjacent <token1> <token2> <file>
#   Count consecutive lines where line[i]==token1 and line[i+1]==token2.
#   Used to count "tools\ncreate" or "meter\ntool-event" pairs.
# ---------------------------------------------------------------------------
count_adjacent() {
  local t1="$1" t2="$2" afile="$3"
  awk -v t1="${t1}" -v t2="${t2}" '
    prev==t1 && $0==t2 {count++}
    {prev=$0}
    END {print count+0}
  ' "${afile}" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# Helper: build a fresh tmp OPENCLAW_HOME and return the path.
# Usage: TMP_HOME=$(make_openclaw_home)
# Creates:
#   skills/revenium/markers/
#   revenium-offsets.json ({})
#   revenium-reported.ledger (empty)
#   revenium-jobs.ledger (empty)
#   revenium-tools.ledger (empty)
#   revenium-tool-events.ledger (empty)
#   skills/revenium/config.json ({"organizationName":"TestOrg"})
# The SQLite store itself is built separately (build_canonical_fixture /
# build_toolcall_pair) at agents/main/agent/openclaw-agent.sqlite.
# ---------------------------------------------------------------------------
make_openclaw_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-rpt-tools-home.XXXXXX")
  mkdir -p "${d}/skills/revenium/markers"
  echo '{}' > "${d}/revenium-offsets.json"
  touch "${d}/revenium-reported.ledger"
  touch "${d}/revenium-jobs.ledger"
  touch "${d}/revenium-tools.ledger"
  touch "${d}/revenium-tool-events.ledger"
  echo '{"organizationName":"TestOrg"}' > "${d}/skills/revenium/config.json"
  echo "${d}"
}

# db_for <openclaw_home> — the real glob layout store_db_paths matches.
db_for() {
  echo "$1/agents/main/agent/openclaw-agent.sqlite"
}

# ---------------------------------------------------------------------------
# Fake HOME setup: stub on PATH via fake HOME/.local/bin/revenium
# All test groups share a single fake HOME so HOME= is always settable.
# ---------------------------------------------------------------------------
TMP_FAKE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-rpt-tools-fakehome.XXXXXX")
TMP_LOCAL_BIN="${TMP_FAKE_HOME}/.local/bin"
mkdir -p "${TMP_LOCAL_BIN}"
ln -sf "${STUB_SH}" "${TMP_LOCAL_BIN}/revenium"

cleanup() {
  rm -rf "${TMP_FAKE_HOME}" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# run_report <OPENCLAW_HOME> <ARGV_FILE> [KEY=VALUE ...]
#   Runs report.sh with the stub on PATH; swallows exit code.
#   Extra KEY=VALUE args are prepended to the env. Assumes the SQLite store
#   under <OPENCLAW_HOME> was already built by the caller.
# ---------------------------------------------------------------------------
run_report() {
  local openclaw_home="$1"
  local _argv_file="$2"
  shift 2
  STUB_REVENIUM_ARGV_FILE="${_argv_file}" \
  OPENCLAW_HOME="${openclaw_home}" \
  HOME="${TMP_FAKE_HOME}" \
  env "$@" \
  bash "${REPORT_SH}" 2>&1 || true
}

# ---------------------------------------------------------------------------
# mk_user_event <db> <sid> <seq> <text> — a bare user-message event, matching
# the shape report.sh's system_prompt/user_msgs_file jq filters expect
# (top-level type=="message", .message.role=="user",
# .message.content[].type=="text"). No convenience wrapper exists in
# mk-session-store.sh for this shape yet (Task 1/3 only needed assistant
# events); built inline via mk_event, same technique as GROUP TR-5's custom
# toolResult event below.
# ---------------------------------------------------------------------------
mk_user_event() {
  local db="$1" sid="$2" seq="$3" text="$4"
  local doc
  doc=$(SEQ="${seq}" TEXT="${text}" python3 - <<'PY'
import json, os
seq = os.environ['SEQ']
print(json.dumps({
    "type": "message",
    "id": f"user-id-{seq}",
    "parentId": "00000000",
    "timestamp": "2026-01-01T10:01:00.000Z",
    "message": {"role": "user", "content": [{"type": "text", "text": os.environ['TEXT']}]},
}))
PY
)
  mk_event "${db}" "${sid}" "${seq}" "${doc}"
}

# ---------------------------------------------------------------------------
# build_canonical_fixture <db> <sid>
#   One user message + one TOOL_CALL completion + one toolCall/toolResult
#   pair (read, toolu_test001, 250ms) + one CHAT completion. Mirrors the
#   pre-2.0 FIXTURE_JSONL shape used by GROUPs T/I/X/P — the user message
#   exists so the Task 2 system-prompt behavior case has a first user
#   message to capture.
# ---------------------------------------------------------------------------
build_canonical_fixture() {
  local db="$1" sid="$2"
  mk_store "${db}"
  mk_session "${db}" "${sid}" "agent:main:${sid}" "" 100
  mk_user_event "${db}" "${sid}" 0 "Use the read tool"
  mk_assistant_event "${db}" "${sid}" 1 "resp-001-${sid}" "run-1" 150 "claude-sonnet-4-6" "2026-01-01T10:01:05.000Z" "toolUse"
  mk_toolcall_pair "${db}" "${sid}" 2 "toolu_test001" "read" 250 "false"
  mk_assistant_event "${db}" "${sid}" 4 "resp-002-${sid}" "run-1" 380 "claude-sonnet-4-6" "2026-01-01T10:01:06.000Z" "stop"
}

# ===========================================================================
# GROUP T: Basic tool registry + tool-event (TOOLEV-01..03)
# ===========================================================================
SID_T1="10000000-aaaa-aaaa-aaaa-000000000001"
TMP_HOME_T=$(make_openclaw_home)
ARGV_FILE_T=$(mktemp "${TMPDIR:-/tmp}/test-rpt-tools-argv-t.XXXXXX")

build_canonical_fixture "$(db_for "${TMP_HOME_T}")" "${SID_T1}"

# First run — all tool registry and tool-event argv should appear
run_report "${TMP_HOME_T}" "${ARGV_FILE_T}"

# ---------------------------------------------------------------------------
# GROUP T assertions — TOOLEV-01: tool registry (tools create)
# ---------------------------------------------------------------------------

# TOOLEV-01: tools create called with --name read
if argv_vals "--name" "${ARGV_FILE_T}" | grep -q "^read$"; then
  pass "TOOLEV-01: tools create --name read found in argv"
else
  fail "TOOLEV-01: tools create --name read NOT found in argv (RED — tool registry not yet in report.sh)"
fi

# TOOLEV-01: tools create called with --tool-id read
if argv_vals "--tool-id" "${ARGV_FILE_T}" | grep -q "^read$"; then
  pass "TOOLEV-01: tools create --tool-id read found in argv"
else
  fail "TOOLEV-01: tools create --tool-id read NOT found in argv (RED)"
fi

# TOOLEV-01: tools create called with --tool-type CUSTOM (built-in tools).
# NOTE: must be a valid Revenium enum value — the API rejects "BUILTIN" HTTP 400.
if argv_vals "--tool-type" "${ARGV_FILE_T}" | grep -q "^CUSTOM$"; then
  pass "TOOLEV-01: tools create --tool-type CUSTOM found in argv"
else
  fail "TOOLEV-01: tools create --tool-type CUSTOM NOT found in argv"
fi

# TOOLEV-01: never emit an invalid tool-type the API would reject (HTTP 400).
if argv_vals "--tool-type" "${ARGV_FILE_T}" | grep -qvE "^(SDK|MCP_SERVER|AI_SERVICE|REST_API|LOCAL_FUNCTION|CUSTOM)$"; then
  fail "TOOLEV-01: an invalid --tool-type value was emitted (API would reject HTTP 400)"
else
  pass "TOOLEV-01: all --tool-type values are valid Revenium enum members"
fi

# TOOLEV-01: tools registry ledger written after successful registration
if grep -q "^TOOL:read:" "${TMP_HOME_T}/revenium-tools.ledger" 2>/dev/null; then
  pass "TOOLEV-01: TOOL:read: entry written to revenium-tools.ledger"
else
  fail "TOOLEV-01: TOOL:read: entry NOT in revenium-tools.ledger (RED)"
fi

# ---------------------------------------------------------------------------
# GROUP T assertions — TOOLEV-02: tool-event metering (meter tool-event)
# ---------------------------------------------------------------------------

# TOOLEV-02: meter tool-event called with --tool-id read
# Note: both tools create and meter tool-event pass --tool-id; this checks the
# value appears somewhere in the argv (sufficient since only "read" is the tool)
if argv_vals "--tool-id" "${ARGV_FILE_T}" | grep -q "^read$"; then
  pass "TOOLEV-02: meter tool-event --tool-id read found in argv"
else
  fail "TOOLEV-02: meter tool-event --tool-id read NOT found in argv (RED)"
fi

# TOOLEV-02: --agent value starts with openclaw- (for meter tool-event attribution)
if argv_vals "--agent" "${ARGV_FILE_T}" | grep -q "^openclaw-"; then
  pass "TOOLEV-02: meter tool-event --agent openclaw-* found in argv"
else
  fail "TOOLEV-02: meter tool-event --agent NOT found or wrong prefix (RED)"
fi

# TOOLEV-02 explicit success flag: --success must appear as a bare flag.
# The no-default-false assertion: if --success is absent, every tool-event
# appears failed in the Revenium dashboard (RESEARCH.md Pitfall 2).
if grep -q "^--success$" "${ARGV_FILE_T}"; then
  pass "TOOLEV-02: --success flag present in argv (explicit success; no-default-false gotcha covered)"
else
  fail "TOOLEV-02: --success flag NOT found in argv (RED — tool-event will appear failed in dashboard)"
fi

# TOOLEV-02 timing: --duration-ms 250 (the fixture's toolCall/toolResult durationMs)
if argv_vals "--duration-ms" "${ARGV_FILE_T}" | grep -q "^250$"; then
  pass "TOOLEV-02 timing: --duration-ms 250 found in argv (250ms fixture delta)"
else
  fail "TOOLEV-02 timing: --duration-ms 250 NOT found in argv (RED — duration computation missing or wrong)"
fi

# TOOLEV-02: tool-events ledger written after successful emission
if grep -q "^TOOLEV:toolu_test001$" "${TMP_HOME_T}/revenium-tool-events.ledger" 2>/dev/null; then
  pass "TOOLEV-02: TOOLEV:toolu_test001 entry written to revenium-tool-events.ledger"
else
  fail "TOOLEV-02: TOOLEV:toolu_test001 entry NOT in revenium-tool-events.ledger (RED)"
fi

# ---------------------------------------------------------------------------
# GROUP T assertions — TOOLEV-03: completion metering untouched
# ---------------------------------------------------------------------------
# Both TOOL_CALL and CHAT completions must still appear; no operation-type
# contamination from tool-event logic.

# TOOLEV-03: at least one meter completion with --operation-type TOOL_CALL
if argv_vals "--operation-type" "${ARGV_FILE_T}" | grep -q "^TOOL_CALL$"; then
  pass "TOOLEV-03: meter completion --operation-type TOOL_CALL still present (completion path untouched)"
else
  fail "TOOLEV-03: meter completion --operation-type TOOL_CALL NOT found (RED — completion path broken)"
fi

# TOOLEV-03: at least one meter completion with --operation-type CHAT
if argv_vals "--operation-type" "${ARGV_FILE_T}" | grep -q "^CHAT$"; then
  pass "TOOLEV-03: meter completion --operation-type CHAT still present"
else
  fail "TOOLEV-03: meter completion --operation-type CHAT NOT found (RED)"
fi

# TOOLEV-03: --operation-type values are ONLY TOOL_CALL or CHAT (no tool-event
# operation types leaked onto completions). Since meter tool-event uses
# --tool-id (not --operation-type), any --operation-type in argv comes from
# meter completion only. Verify no unexpected operation-type values appear.
unexpected_optypes=$(argv_vals "--operation-type" "${ARGV_FILE_T}" | grep -v "^TOOL_CALL$" | grep -v "^CHAT$" | grep -v "^GUARDRAIL$" || true)
if [[ -z "${unexpected_optypes}" ]]; then
  pass "TOOLEV-03: no unexpected --operation-type values (completion path not contaminated by tool-event)"
else
  fail "TOOLEV-03: unexpected --operation-type values found: ${unexpected_optypes} (RED)"
fi

# ---------------------------------------------------------------------------
# Task 2 behavior: the completion path's system prompt is populated from the
# session_events_tmp full-history seam (not empty, not offset-truncated) —
# the fixture's first (and only) user message text must appear.
# ---------------------------------------------------------------------------
if argv_vals "--system-prompt" "${ARGV_FILE_T}" | grep -q "Use the read tool"; then
  pass "Task 2: --system-prompt carries the fixture's first user-message text"
else
  fail "Task 2: --system-prompt did NOT carry the fixture's first user-message text"
fi

rm -f "${ARGV_FILE_T}"

# ===========================================================================
# GROUP I: Idempotency (TOOLEV-01 registry dedup, TOOLEV-04 tool-event dedup)
# Run report.sh TWICE against the same OPENCLAW_HOME. The second run must
# NOT re-register the tool or re-emit the tool-event.
# ===========================================================================
SID_I1="20000000-aaaa-aaaa-aaaa-000000000001"
TMP_HOME_I=$(make_openclaw_home)
ARGV_FILE_I1=$(mktemp "${TMPDIR:-/tmp}/test-rpt-tools-argv-i1.XXXXXX")
ARGV_FILE_I2=$(mktemp "${TMPDIR:-/tmp}/test-rpt-tools-argv-i2.XXXXXX")

build_canonical_fixture "$(db_for "${TMP_HOME_I}")" "${SID_I1}"

# First run
run_report "${TMP_HOME_I}" "${ARGV_FILE_I1}"

# Second run (same OPENCLAW_HOME — no reset of offsets/ledgers, store unchanged)
run_report "${TMP_HOME_I}" "${ARGV_FILE_I2}"

# Merge both argv files for cross-run token count assertions
ARGV_FILE_I_MERGED=$(mktemp "${TMPDIR:-/tmp}/test-rpt-tools-argv-i-merged.XXXXXX")
cat "${ARGV_FILE_I1}" "${ARGV_FILE_I2}" > "${ARGV_FILE_I_MERGED}"

# TOOLEV-01 idempotency: tools create must appear exactly once across both runs.
# Count adjacent "tools\ncreate" pairs via awk (jobs create does not emit "tools").
tools_create_count=$(count_adjacent "tools" "create" "${ARGV_FILE_I_MERGED}")
if [[ "${tools_create_count}" -eq 1 ]]; then
  pass "TOOLEV-01 idempotency: tools create called exactly once across two runs (registry ledger dedup)"
else
  fail "TOOLEV-01 idempotency: expected tools create count=1, got ${tools_create_count} (RED)"
fi

# TOOLEV-04 event idempotency: meter tool-event must appear exactly once.
# Use --duration-ms count instead of count_adjacent("meter","tool-event") because
# the TOOLS_CLI_CAPABLE probe (`revenium meter tool-event --help`) also emits
# consecutive "meter\ntool-event" tokens in the argv file on every cron tick.
# --duration-ms ONLY appears in real `meter tool-event` posts, not in --help probes.
meter_tool_event_count=$(count_grep "^--duration-ms$" "${ARGV_FILE_I_MERGED}")
if [[ "${meter_tool_event_count}" -eq 1 ]]; then
  pass "TOOLEV-04 event idempotency: meter tool-event called exactly once across two runs (tool-events ledger dedup)"
else
  fail "TOOLEV-04 event idempotency: expected meter tool-event count=1, got ${meter_tool_event_count} (RED)"
fi

rm -f "${ARGV_FILE_I1}" "${ARGV_FILE_I2}" "${ARGV_FILE_I_MERGED}"

# ===========================================================================
# GROUP X: Prefix-collision regression (TOOLEV-01/04 dedup must be anchored)
# Seed each ledger with an entry whose key SUPERSTRINGS the real id. An
# unanchored `grep -F "TOOL:read"` false-matches "TOOL:read-file:..." and an
# unanchored `grep -F "TOOLEV:toolu_test001"` false-matches
# "TOOLEV:toolu_test0019" — silently skipping registration / under-metering.
# The fixture tool is `read` (id=read, toolCall id=toolu_test001), so seeding
# these superstrings MUST NOT suppress the real calls when dedup is anchored.
# ===========================================================================
SID_X1="30000000-aaaa-aaaa-aaaa-000000000001"
TMP_HOME_X=$(make_openclaw_home)
ARGV_FILE_X=$(mktemp "${TMPDIR:-/tmp}/test-rpt-tools-argv-x.XXXXXX")

build_canonical_fixture "$(db_for "${TMP_HOME_X}")" "${SID_X1}"
# Pre-seed superstring ledger entries (prefix-collision bait)
printf 'TOOL:read-file:123.000\n'       > "${TMP_HOME_X}/revenium-tools.ledger"
printf 'TOOLEV:toolu_test0019\n'        > "${TMP_HOME_X}/revenium-tool-events.ledger"

run_report "${TMP_HOME_X}" "${ARGV_FILE_X}"

# TOOLEV-01: `read` still registers despite ledger containing `read-file`.
if argv_vals "--tool-id" "${ARGV_FILE_X}" | grep -q "^read$" \
   && [[ "$(count_adjacent "tools" "create" "${ARGV_FILE_X}")" -eq 1 ]]; then
  pass "TOOLEV-01 prefix-safe: 'read' registers even when ledger holds 'read-file' (anchored dedup)"
else
  fail "TOOLEV-01 prefix-safe: 'read' was suppressed by 'read-file' ledger entry (unanchored grep regression)"
fi

# TOOLEV-04: toolu_test001 event still emits despite ledger holding toolu_test0019.
if [[ "$(count_grep "^--duration-ms$" "${ARGV_FILE_X}")" -eq 1 ]]; then
  pass "TOOLEV-04 prefix-safe: 'toolu_test001' event emits even when ledger holds 'toolu_test0019' (anchored dedup)"
else
  fail "TOOLEV-04 prefix-safe: 'toolu_test001' event suppressed by 'toolu_test0019' ledger entry (unanchored grep regression)"
fi

rm -f "${ARGV_FILE_X}"

# ===========================================================================
# GROUP E: Empty tool-name skip (no garbage empty --tool-id rows)
# Some toolCall content items carry an empty/missing name. Registering or
# metering those emits `tools create --tool-id ""` / `meter tool-event
# --tool-id ""` — garbage that the API rejects and that pollutes the ledger.
# report.sh must skip them entirely.
# ===========================================================================
SID_E1="40000000-aaaa-aaaa-aaaa-000000000001"
TMP_HOME_E=$(make_openclaw_home)
ARGV_FILE_E=$(mktemp "${TMPDIR:-/tmp}/test-rpt-tools-argv-e.XXXXXX")

DB_E="$(db_for "${TMP_HOME_E}")"
mk_store "${DB_E}"
mk_session "${DB_E}" "${SID_E1}" "agent:main:${SID_E1}" "" 100
# One toolCall with an EMPTY name + its toolResult. No accompanying
# usage-bearing completion — this group only exercises the toolCall scan.
mk_toolcall_pair "${DB_E}" "${SID_E1}" 0 "toolu_empty001" "" 10 "false"

run_report "${TMP_HOME_E}" "${ARGV_FILE_E}"

# No tools create at all (the only tool had an empty name → skipped).
if [[ "$(count_adjacent "tools" "create" "${ARGV_FILE_E}")" -eq 0 ]]; then
  pass "TOOLEV-01 empty-skip: empty-name toolCall produces zero tools create"
else
  fail "TOOLEV-01 empty-skip: empty-name toolCall still emitted a tools create (garbage)"
fi

# No real tool-event (no --duration-ms) for the empty-name toolCall.
if [[ "$(count_grep "^--duration-ms$" "${ARGV_FILE_E}")" -eq 0 ]]; then
  pass "TOOLEV-02 empty-skip: empty-name toolCall produces zero meter tool-event"
else
  fail "TOOLEV-02 empty-skip: empty-name toolCall still emitted a meter tool-event (garbage)"
fi

# Defensive: no empty-string --tool-id was ever passed.
if argv_vals "--tool-id" "${ARGV_FILE_E}" | grep -q "^$"; then
  fail "TOOLEV empty-skip: an empty --tool-id value was emitted"
else
  pass "TOOLEV empty-skip: no empty --tool-id values emitted"
fi

rm -f "${ARGV_FILE_E}"

# ===========================================================================
# GROUP P: Fail-open probe (TOOLEV-04)
# STUB_REVENIUM_NO_TOOLS=1 forces the tools probe to fail → TOOLS_CLI_CAPABLE=false.
# All tool work must be skipped; meter completion must still appear.
# ===========================================================================
SID_P1="50000000-aaaa-aaaa-aaaa-000000000001"
TMP_HOME_P=$(make_openclaw_home)
ARGV_FILE_P=$(mktemp "${TMPDIR:-/tmp}/test-rpt-tools-argv-p.XXXXXX")

build_canonical_fixture "$(db_for "${TMP_HOME_P}")" "${SID_P1}"

# Run with STUB_REVENIUM_NO_TOOLS=1 — probe fails → TOOLS_CLI_CAPABLE=false
STUB_REVENIUM_ARGV_FILE="${ARGV_FILE_P}" \
OPENCLAW_HOME="${TMP_HOME_P}" \
HOME="${TMP_FAKE_HOME}" \
STUB_REVENIUM_NO_TOOLS=1 \
bash "${REPORT_SH}" 2>&1 || true

# TOOLEV-04: no tools create when probe fails
tools_create_count_p=$(count_adjacent "tools" "create" "${ARGV_FILE_P}")
if [[ "${tools_create_count_p}" -eq 0 ]]; then
  pass "TOOLEV-04 fail-open: zero tools create calls when TOOLS_CLI_CAPABLE=false (probe failed)"
else
  fail "TOOLEV-04 fail-open: expected 0 tools create, got ${tools_create_count_p} (RED)"
fi

# TOOLEV-04: no meter tool-event when probe fails
meter_tool_event_count_p=$(count_adjacent "meter" "tool-event" "${ARGV_FILE_P}")
if [[ "${meter_tool_event_count_p}" -eq 0 ]]; then
  pass "TOOLEV-04 fail-open: zero meter tool-event calls when TOOLS_CLI_CAPABLE=false"
else
  fail "TOOLEV-04 fail-open: expected 0 meter tool-event, got ${meter_tool_event_count_p} (RED)"
fi

# TOOLEV-04: meter completion still appears (v1.1 metering byte-identical when probe fails)
if argv_vals "--operation-type" "${ARGV_FILE_P}" | grep -q "^TOOL_CALL$\|^CHAT$"; then
  pass "TOOLEV-04 fail-open: meter completion still present when TOOLS_CLI_CAPABLE=false (v1.1 metering unaffected)"
else
  fail "TOOLEV-04 fail-open: meter completion NOT found when probe failed (RED — completion metering broken)"
fi

rm -f "${ARGV_FILE_P}"

# ===========================================================================
# GROUP TR: Tracer — "a tool call in the store becomes one tool-event"
# The five <behavior> cases from Task 1 of 19-04-PLAN.md. Session id/tool
# call id/duration deliberately mirror the live sample-rows.txt evidence
# (exec / toolu_..., durationMs 2085) that motivated store_tool_calls.
# ===========================================================================

# --- TR-1/TR-2: one call+result pair -> exactly one tool-event + one registration
SID_TR1="60000000-aaaa-aaaa-aaaa-000000000001"
TMP_HOME_TR1=$(make_openclaw_home)
ARGV_FILE_TR1=$(mktemp "${TMPDIR:-/tmp}/test-rpt-tools-argv-tr1.XXXXXX")
DB_TR1="$(db_for "${TMP_HOME_TR1}")"
mk_store "${DB_TR1}"
mk_session "${DB_TR1}" "${SID_TR1}" "agent:main:${SID_TR1}" "" 100
mk_toolcall_pair "${DB_TR1}" "${SID_TR1}" 0 "toolu_tracer_001" "exec" 2085 "false"

run_report "${TMP_HOME_TR1}" "${ARGV_FILE_TR1}"

if [[ "$(count_grep "^--duration-ms$" "${ARGV_FILE_TR1}")" -eq 1 ]] \
   && argv_vals "--duration-ms" "${ARGV_FILE_TR1}" | grep -q "^2085$"; then
  pass "GROUP TR-1: exactly one tool-event argv carrying duration 2085"
else
  fail "GROUP TR-1: expected exactly one --duration-ms 2085 in captured argv"
fi

if grep -q "^TOOLEV:toolu_tracer_001$" "${TMP_HOME_TR1}/revenium-tool-events.ledger" 2>/dev/null; then
  pass "GROUP TR-1: tool-events ledger keyed by toolu_tracer_001"
else
  fail "GROUP TR-1: TOOLEV:toolu_tracer_001 NOT found in tool-events ledger"
fi

if [[ "$(count_adjacent "tools" "create" "${ARGV_FILE_TR1}")" -eq 1 ]]; then
  pass "GROUP TR-2: exactly one tools create registration for the fixture's tool"
else
  fail "GROUP TR-2: expected exactly one tools create, got $(count_adjacent "tools" "create" "${ARGV_FILE_TR1}")"
fi

# --- TR-3: a second tick over the unchanged fixture captures zero additional tool-event
ARGV_FILE_TR1_TICK2=$(mktemp "${TMPDIR:-/tmp}/test-rpt-tools-argv-tr1-tick2.XXXXXX")
run_report "${TMP_HOME_TR1}" "${ARGV_FILE_TR1_TICK2}"
if [[ "$(count_grep "^--duration-ms$" "${ARGV_FILE_TR1_TICK2}")" -eq 0 ]]; then
  pass "GROUP TR-3: second tick over the unchanged fixture emits zero additional tool-events"
else
  fail "GROUP TR-3: second tick re-emitted a tool-event (ledger dedup broken)"
fi
rm -f "${ARGV_FILE_TR1}" "${ARGV_FILE_TR1_TICK2}"

# --- TR-4: a toolCall with no matching toolResult still produces one tool-event,
#     error flag false, empty error text (the LEFT JOIN's result-less-call path).
SID_TR4="60000000-aaaa-aaaa-aaaa-000000000004"
TMP_HOME_TR4=$(make_openclaw_home)
ARGV_FILE_TR4=$(mktemp "${TMPDIR:-/tmp}/test-rpt-tools-argv-tr4.XXXXXX")
DB_TR4="$(db_for "${TMP_HOME_TR4}")"
mk_store "${DB_TR4}"
mk_session "${DB_TR4}" "${SID_TR4}" "agent:main:${SID_TR4}" "" 100
# mk_toolcall_pair always inserts both rows; delete the result row afterward
# to model a toolCall whose result has not landed yet.
mk_toolcall_pair "${DB_TR4}" "${SID_TR4}" 0 "toolu_noresult001" "search" 999 "false"
"${STUB_SQLITE3_BIN:-sqlite3}" "${DB_TR4}" "DELETE FROM transcript_events WHERE session_id='${SID_TR4}' AND seq=1;"

run_report "${TMP_HOME_TR4}" "${ARGV_FILE_TR4}"

if [[ "$(count_grep "^--duration-ms$" "${ARGV_FILE_TR4}")" -eq 1 ]] \
   && argv_vals "--duration-ms" "${ARGV_FILE_TR4}" | grep -q "^0$"; then
  pass "GROUP TR-4: a result-less toolCall still emits one tool-event (duration 0)"
else
  fail "GROUP TR-4: expected exactly one --duration-ms 0 for the result-less toolCall"
fi
if grep -q "^--success$" "${ARGV_FILE_TR4}" && ! grep -q "^--error-message$" "${ARGV_FILE_TR4}"; then
  pass "GROUP TR-4: result-less toolCall reports success (error flag false) with no error text"
else
  fail "GROUP TR-4: result-less toolCall did not report success/empty-error as expected"
fi
rm -f "${ARGV_FILE_TR4}"

# --- TR-5: a toolResult whose error text spans two lines produces a single-line
#     captured argv value — no field is shifted (T-19-13).
SID_TR5="60000000-aaaa-aaaa-aaaa-000000000005"
TMP_HOME_TR5=$(make_openclaw_home)
ARGV_FILE_TR5=$(mktemp "${TMPDIR:-/tmp}/test-rpt-tools-argv-tr5.XXXXXX")
DB_TR5="$(db_for "${TMP_HOME_TR5}")"
mk_store "${DB_TR5}"
mk_session "${DB_TR5}" "${SID_TR5}" "agent:main:${SID_TR5}" "" 100
TR5_CALL_JSON='{"type":"message","id":"call-tr5","parentId":"parent-tr5","timestamp":"2026-09-24T04:29:20.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"toolu_multiline001","name":"exec","arguments":{}}]}}'
mk_event "${DB_TR5}" "${SID_TR5}" 0 "${TR5_CALL_JSON}"
TR5_RESULT_JSON=$(python3 - <<'PY'
import json
doc = {
    "type": "message",
    "id": "result-tr5",
    "parentId": "call-tr5",
    "timestamp": "2026-09-24T04:29:22.085Z",
    "message": {
        "role": "toolResult",
        "toolCallId": "toolu_multiline001",
        "toolName": "exec",
        "content": [{"type": "text", "text": "line one\nline two"}],
        "details": {"status": "failed", "durationMs": 500},
        "isError": True,
    },
}
print(json.dumps(doc))
PY
)
mk_event "${DB_TR5}" "${SID_TR5}" 1 "${TR5_RESULT_JSON}"

run_report "${TMP_HOME_TR5}" "${ARGV_FILE_TR5}"

error_msg_lines=$(argv_vals "--error-message" "${ARGV_FILE_TR5}")
error_msg_count=$(printf '%s\n' "${error_msg_lines}" | grep -c . || true)
if [[ "${error_msg_count}" -eq 1 ]] && printf '%s' "${error_msg_lines}" | grep -q "line one line two"; then
  pass "GROUP TR-5: two-line error text is captured as a single-line argv value"
else
  fail "GROUP TR-5: multi-line error text was not collapsed to a single argv line (got: ${error_msg_lines})"
fi
rm -f "${ARGV_FILE_TR5}"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
