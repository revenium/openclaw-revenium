#!/usr/bin/env bash
# =============================================================================
# test_report_argv.sh — Integration tests for report.sh task-type/agent wiring
# (METER-03 / TRACE-01 / TRACE-02)
#
# Strategy:
#   Build a tmp OPENCLAW_HOME with four session JSONL fixtures:
#
#   Session A (Phase D — marker-after-completion, no completion_id):
#     Two completions each followed by a marker WITHOUT a completion_id.
#     comp1 → marker1(research) written AFTER comp1  → Phase D picks research
#     comp2 → marker2(generation) written AFTER comp2 → Phase D picks generation
#     Encodes the REAL OpenClaw lifecycle: write-marker.sh fires after the turn.
#
#   Session B (no marker file):
#     Every completion tagged --task-type unclassified.
#
#   Session C (Phase A — exact completion_id match):
#     Marker carries completion_id = comp's .id → exact match → tagged correctly.
#
#   Session D (anti-bleed — id-keyed marker does NOT steal label for other turns):
#     comp1 has a matching marker (completion_id=comp1_id) → tagged
#     comp2 has NO marker referencing it → unclassified (must not steal comp1's)
#
#   - Place stub-revenium.sh on PATH capturing all argv to STUB_REVENIUM_ARGV_FILE
#   - Run report.sh
#   - Assert captured argv contains --task-type with correct labels and
#     --agent with "openclaw-" prefix
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPORT_SH="${REPO_ROOT}/scripts/report.sh"
STUB_SH="${SCRIPT_DIR}/stub-revenium.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Build tmp OPENCLAW_HOME
# ---------------------------------------------------------------------------
TMP_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-rpt-home.XXXXXX")
TMP_SESSIONS="${TMP_HOME}/agents/main/sessions"
TMP_SKILL_DIR="${TMP_HOME}/skills/revenium"
TMP_MARKERS="${TMP_SKILL_DIR}/markers"

mkdir -p "${TMP_SESSIONS}" "${TMP_SKILL_DIR}" "${TMP_MARKERS}"

# Offsets file (empty — process all lines)
OFFSETS_FILE="${TMP_HOME}/revenium-offsets.json"
echo '{}' > "${OFFSETS_FILE}"

# Ledger file (empty — no previously reported transactions)
LEDGER_FILE="${TMP_HOME}/revenium-reported.ledger"
touch "${LEDGER_FILE}"

# Config file (stub organizationName)
CONFIG_FILE="${TMP_SKILL_DIR}/config.json"
echo '{"organizationName":"TestOrg"}' > "${CONFIG_FILE}"

# ---------------------------------------------------------------------------
# Session A: Phase D — marker-after-completion ordering (REAL lifecycle)
#
# In the real OpenClaw lifecycle, write-marker.sh is called AFTER the LLM
# completion is produced, so the marker's ts is always LATER than the
# completion it classifies. Phase D correlation picks the earliest marker
# whose marker_ts >= completion_ts.
#
# Timestamps:
#   T1: comp1 response    2026-01-01T10:06:00Z
#   T2: marker research   2026-01-01T10:07:00Z  → marker after comp1 → research
#   T3: comp2 response    2026-01-01T10:09:00Z
#   T4: marker generation 2026-01-01T10:10:00Z  → marker after comp2 → generation
#
# Markers for Session A have NO completion_id (legacy/Phase-D path).
# ---------------------------------------------------------------------------
SID_A="aaaaaaaa-1111-1111-1111-000000000001"
SESSION_A="${TMP_SESSIONS}/${SID_A}.jsonl"

cat > "${SESSION_A}" <<'JSONL'
{"type":"session","version":3,"id":"aaaaaaaa-1111-1111-1111-000000000001","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-A-001","parentId":"00000000","timestamp":"2026-01-01T10:04:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Research task"}]}}
{"type":"message","id":"comp-A-001","parentId":"user-A-001","timestamp":"2026-01-01T10:06:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Research response"}],"usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150}}}
{"type":"message","id":"user-A-002","parentId":"comp-A-001","timestamp":"2026-01-01T10:08:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Generation task"}]}}
{"type":"message","id":"comp-A-002","parentId":"user-A-002","timestamp":"2026-01-01T10:09:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Generation response"}],"usage":{"input":120,"output":60,"cacheRead":0,"cacheWrite":0,"totalTokens":180}}}
JSONL

# Marker file for session A: two markers WITHOUT completion_id (legacy Phase D markers).
# Markers are written AFTER their respective completions.
MARKER_A="${TMP_MARKERS}/${SID_A}.jsonl"
echo '{"ts":"2026-01-01T10:07:00Z","task_type":"research"}' > "${MARKER_A}"
echo '{"ts":"2026-01-01T10:10:00Z","task_type":"generation"}' >> "${MARKER_A}"

# ---------------------------------------------------------------------------
# Session B: no marker file (should be unclassified)
# ---------------------------------------------------------------------------
SID_B="bbbbbbbb-2222-2222-2222-000000000002"
SESSION_B="${TMP_SESSIONS}/${SID_B}.jsonl"

cat > "${SESSION_B}" <<'JSONL'
{"type":"session","version":3,"id":"bbbbbbbb-2222-2222-2222-000000000002","timestamp":"2026-01-01T11:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-B-001","parentId":"00000000","timestamp":"2026-01-01T11:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Some task"}]}}
{"type":"message","id":"comp-B-001","parentId":"user-B-001","timestamp":"2026-01-01T11:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Some response"}],"usage":{"input":80,"output":40,"cacheRead":0,"cacheWrite":0,"totalTokens":120}}}
JSONL

# No marker file for SID_B

# ---------------------------------------------------------------------------
# Session C: Phase A — exact completion_id match
#
# The marker carries completion_id = comp-C-001 (the completion's .id).
# Phase A should match it regardless of timestamp ordering.
# The marker ts is AFTER the completion ts (real lifecycle).
# ---------------------------------------------------------------------------
SID_C="cccccccc-3333-3333-3333-000000000003"
SESSION_C="${TMP_SESSIONS}/${SID_C}.jsonl"

cat > "${SESSION_C}" <<'JSONL'
{"type":"session","version":3,"id":"cccccccc-3333-3333-3333-000000000003","timestamp":"2026-01-01T12:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-C-001","parentId":"00000000","timestamp":"2026-01-01T12:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Analysis task"}]}}
{"type":"message","id":"comp-C-001","parentId":"user-C-001","timestamp":"2026-01-01T12:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Analysis response"}],"usage":{"input":90,"output":45,"cacheRead":0,"cacheWrite":0,"totalTokens":135}}}
JSONL

# Marker for session C: includes completion_id → Phase A exact match.
MARKER_C="${TMP_MARKERS}/${SID_C}.jsonl"
echo '{"ts":"2026-01-01T12:03:00Z","task_type":"analysis","completion_id":"comp-C-001"}' > "${MARKER_C}"

# ---------------------------------------------------------------------------
# Session D: anti-bleed — id-keyed marker must NOT steal label from other turns
#
# comp-D-001 has a matching marker (completion_id=comp-D-001) → tagged "debugging"
# comp-D-002 has NO marker referencing it → must be unclassified
#   (the id-keyed marker for comp-D-001 must not bleed onto comp-D-002 via
#    timestamp fallback, because markers with a completion_id are excluded from
#    Phase D according to the contract: they belong to a specific completion).
# ---------------------------------------------------------------------------
SID_D="dddddddd-4444-4444-4444-000000000004"
SESSION_D="${TMP_SESSIONS}/${SID_D}.jsonl"

cat > "${SESSION_D}" <<'JSONL'
{"type":"session","version":3,"id":"dddddddd-4444-4444-4444-000000000004","timestamp":"2026-01-01T13:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-D-001","parentId":"00000000","timestamp":"2026-01-01T13:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Debug task"}]}}
{"type":"message","id":"comp-D-001","parentId":"user-D-001","timestamp":"2026-01-01T13:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Debug response"}],"usage":{"input":70,"output":35,"cacheRead":0,"cacheWrite":0,"totalTokens":105}}}
{"type":"message","id":"user-D-002","parentId":"comp-D-001","timestamp":"2026-01-01T13:04:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Follow-up with no marker"}]}}
{"type":"message","id":"comp-D-002","parentId":"user-D-002","timestamp":"2026-01-01T13:05:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Follow-up response"}],"usage":{"input":60,"output":30,"cacheRead":0,"cacheWrite":0,"totalTokens":90}}}
JSONL

# Marker for session D: only comp-D-001 has a marker (id-keyed).
# comp-D-002 has no corresponding marker.
MARKER_D="${TMP_MARKERS}/${SID_D}.jsonl"
echo '{"ts":"2026-01-01T13:03:00Z","task_type":"debugging","completion_id":"comp-D-001"}' > "${MARKER_D}"

# ---------------------------------------------------------------------------
# Stub revenium: place in a fake HOME/.local/bin so it wins after report.sh's
# PATH-expansion loop. report.sh prepends "${HOME}/.local/bin" LAST (so it
# ends up FIRST on PATH after the loop). By setting HOME to a temp dir we
# control that slot without touching the real user's environment.
# ---------------------------------------------------------------------------
TMP_FAKE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-rpt-fakehome.XXXXXX")
TMP_LOCAL_BIN="${TMP_FAKE_HOME}/.local/bin"
mkdir -p "${TMP_LOCAL_BIN}"
ln -sf "${STUB_SH}" "${TMP_LOCAL_BIN}/revenium"
ARGV_FILE=$(mktemp "${TMPDIR:-/tmp}/test-rpt-argv.XXXXXX")

cleanup() {
  rm -rf "${TMP_HOME}" "${TMP_FAKE_HOME}" "${ARGV_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

# Export STUB_REVENIUM_ARGV_FILE so it is inherited by the report.sh subshell
# and from there by every `revenium` invocation.
export STUB_REVENIUM_ARGV_FILE="${ARGV_FILE}"

# ---------------------------------------------------------------------------
# Run report.sh with the stubbed environment
# ---------------------------------------------------------------------------
report_output=$(
  OPENCLAW_HOME="${TMP_HOME}" \
  HOME="${TMP_FAKE_HOME}" \
  bash "${REPORT_SH}" 2>&1
) || true

# ---------------------------------------------------------------------------
# Helper: extract all --task-type values from the captured argv
# ---------------------------------------------------------------------------
task_type_values=$(awk '/^--task-type$/{getline; print}' "${ARGV_FILE}" 2>/dev/null || true)
agent_values=$(awk '/^--agent$/{getline; print}' "${ARGV_FILE}" 2>/dev/null || true)

# ---------------------------------------------------------------------------
# Session A assertions (Phase D — marker-after-completion ordering)
# ---------------------------------------------------------------------------

# comp-A-001 at 10:06 → earliest marker with marker_ts >= 10:06 is research@10:07
if echo "${task_type_values}" | grep -q "^research$"; then
  pass "Phase D: --task-type research found (comp-A-001 classified by marker after completion)"
else
  fail "Phase D: --task-type research NOT found (task_type_values: $(echo "${task_type_values}" | tr '\n' '|'))"
  echo "--- report output ---"
  echo "${report_output}" | tail -20
  echo "--- captured argv ---"
  cat "${ARGV_FILE}" 2>/dev/null | head -80
fi

# comp-A-002 at 10:09 → earliest marker with marker_ts >= 10:09 is generation@10:10
if echo "${task_type_values}" | grep -q "^generation$"; then
  pass "Phase D: --task-type generation found (comp-A-002 classified by marker after completion)"
else
  fail "Phase D: --task-type generation NOT found"
fi

# ---------------------------------------------------------------------------
# Session B assertions (no marker → unclassified)
# ---------------------------------------------------------------------------
if echo "${task_type_values}" | grep -q "^unclassified$"; then
  pass "--task-type unclassified found (session with no marker file)"
else
  fail "--task-type unclassified NOT found in captured argv"
fi

# ---------------------------------------------------------------------------
# Session C assertions (Phase A — exact completion_id match)
# ---------------------------------------------------------------------------
if echo "${task_type_values}" | grep -q "^analysis$"; then
  pass "Phase A: --task-type analysis found (comp-C-001 matched by completion_id)"
else
  fail "Phase A: --task-type analysis NOT found — exact completion_id match not working"
  echo "--- report output ---"
  echo "${report_output}" | tail -20
fi

# ---------------------------------------------------------------------------
# Session D assertions (anti-bleed)
# ---------------------------------------------------------------------------
# comp-D-001 should be tagged debugging via Phase A exact match
if echo "${task_type_values}" | grep -q "^debugging$"; then
  pass "anti-bleed: --task-type debugging found for comp-D-001 (id-keyed marker match)"
else
  fail "anti-bleed: --task-type debugging NOT found for comp-D-001"
fi

# comp-D-002 should be unclassified (marker for comp-D-001 must not bleed onto it).
# We check by counting: there should be at least 2 unclassified entries total
# (comp-B-001 and comp-D-002). We already verified unclassified is present above;
# verify count >= 2 to confirm bleed protection.
unclassified_count=$(echo "${task_type_values}" | grep -c "^unclassified$" || echo 0)
if [[ "${unclassified_count}" -ge 2 ]]; then
  pass "anti-bleed: comp-D-002 correctly unclassified (id-keyed marker did not bleed)"
else
  fail "anti-bleed: expected >=2 unclassified entries (got ${unclassified_count}) — marker may be bleeding onto comp-D-002"
fi

# ---------------------------------------------------------------------------
# Assert: all *real* meter completion calls have --task-type (always present)
#
# Phase 6 (06-02, D-11) added a one-time `meter completion --help` capability
# probe that runs once per invocation. The argv stub captures it too, so a bare
# `^meter$` count now includes the probe (which carries --help, not --task-type).
# Exclude `meter completion --help` probe invocations from the count so the
# assertion reflects only real metering completions.
# ---------------------------------------------------------------------------
meter_completions=0
task_type_count=0
meter_help_probes=0
if [[ -f "${ARGV_FILE}" ]]; then
  meter_completions=$(grep -c "^meter$" "${ARGV_FILE}" 2>/dev/null) || meter_completions=0
  task_type_count=$(grep -c "^--task-type$" "${ARGV_FILE}" 2>/dev/null) || task_type_count=0
  # Count `meter` `completion` `--help` token triples (JOBS_CLI_CAPABLE capability probe).
  meter_help_probes=$(awk 'p2=="meter"&&p1=="completion"&&$0=="--help"{c++}{p2=p1;p1=$0}END{print c+0}' "${ARGV_FILE}" 2>/dev/null) || meter_help_probes=0
  # Count `meter` `tool-event` `--help` token triples (TOOLS_CLI_CAPABLE capability probe, Phase 10).
  meter_tool_event_help_probes=$(awk 'p2=="meter"&&p1=="tool-event"&&$0=="--help"{c++}{p2=p1;p1=$0}END{print c+0}' "${ARGV_FILE}" 2>/dev/null) || meter_tool_event_help_probes=0
  meter_completions=$((meter_completions - meter_help_probes - meter_tool_event_help_probes))
fi

if [[ "${meter_completions}" -gt 0 && "${task_type_count}" -eq "${meter_completions}" ]]; then
  pass "--task-type present in all ${meter_completions} meter completion calls"
else
  fail "--task-type count (${task_type_count}) != meter completion count (${meter_completions})"
fi

# ---------------------------------------------------------------------------
# Assert: --agent with openclaw- prefix present
# ---------------------------------------------------------------------------
if echo "${agent_values}" | grep -q "^openclaw-"; then
  pass "--agent with 'openclaw-' prefix found in captured argv"
else
  fail "--agent with 'openclaw-' prefix NOT found (agent_values: $(echo "${agent_values}" | tr '\n' '|'))"
fi

# ---------------------------------------------------------------------------
# Assert: no --agentic-job-id / --agentic-job-name / --agentic-job-type
# ---------------------------------------------------------------------------
if grep -q "agentic-job" "${ARGV_FILE}" 2>/dev/null; then
  fail "forbidden --agentic-job-* found in captured argv"
else
  pass "no --agentic-job-* tokens in captured argv"
fi

# ---------------------------------------------------------------------------
# Assert: no --operation-type GUARDRAIL ever emitted (GRDEV-06)
# report.sh only ever assigns CHAT or TOOL_CALL; GUARDRAIL is emitted
# exclusively by guardrail-check.sh (Plan 01), never by report.sh.
# ---------------------------------------------------------------------------
argv_vals() { awk -v flag="$1" '$0==flag{getline;print}' "${ARGV_FILE}" 2>/dev/null || true; }
if argv_vals "--operation-type" | grep -q "^GUARDRAIL$"; then
  fail "GRDEV-06: --operation-type GUARDRAIL found in report.sh argv (dead heuristic still active)"
else
  pass "GRDEV-06: no --operation-type GUARDRAIL in report.sh argv (only CHAT/TOOL_CALL)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
