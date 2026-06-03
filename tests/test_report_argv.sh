#!/usr/bin/env bash
# =============================================================================
# test_report_argv.sh — Integration tests for report.sh task-type/agent wiring
# (METER-03 / TRACE-01 / TRACE-02)
#
# Strategy:
#   - Build a tmp OPENCLAW_HOME with two session JSONL fixtures:
#       session A: has two markers (research@T1, generation@T2); two completions:
#                  comp1 between T1 and T2 → should tag --task-type research
#                  comp2 after T2 → should tag --task-type generation
#       session B: no marker file → every completion tagged --task-type unclassified
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
# Session A: two completions at different timestamps (with markers)
# ---------------------------------------------------------------------------
SID_A="aaaaaaaa-1111-1111-1111-000000000001"
SESSION_A="${TMP_SESSIONS}/${SID_A}.jsonl"

# Timestamps:
#   T0: session start     2026-01-01T10:00:00Z
#   T1: marker research   2026-01-01T10:05:00Z
#   T2: comp1 response    2026-01-01T10:06:00Z  → research (T1 <= T2)
#   T3: marker generation 2026-01-01T10:08:00Z
#   T4: comp2 response    2026-01-01T10:10:00Z  → generation (T3 <= T4)
#
# Session JSONL lines: session header, user msg, two assistant completions
cat > "${SESSION_A}" <<'JSONL'
{"type":"session","version":3,"id":"aaaaaaaa-1111-1111-1111-000000000001","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-A-001","parentId":"00000000","timestamp":"2026-01-01T10:04:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Research task"}]}}
{"type":"message","id":"comp-A-001","parentId":"user-A-001","timestamp":"2026-01-01T10:06:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Research response"}],"usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150}}}
{"type":"message","id":"user-A-002","parentId":"comp-A-001","timestamp":"2026-01-01T10:09:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Generation task"}]}}
{"type":"message","id":"comp-A-002","parentId":"user-A-002","timestamp":"2026-01-01T10:10:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Generation response"}],"usage":{"input":120,"output":60,"cacheRead":0,"cacheWrite":0,"totalTokens":180}}}
JSONL

# Marker file for session A: two markers
MARKER_A="${TMP_MARKERS}/${SID_A}.jsonl"
echo '{"ts":"2026-01-01T10:05:00Z","task_type":"research"}' > "${MARKER_A}"
echo '{"ts":"2026-01-01T10:08:00Z","task_type":"generation"}' >> "${MARKER_A}"

# ---------------------------------------------------------------------------
# Session B: one completion, no marker file (should be unclassified)
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
# Assert: --task-type research for comp-A-001 (marker research@T1, comp@T2)
# ---------------------------------------------------------------------------
# Captured argv: each arg is on its own line; look for a --task-type line
# followed (within a few lines) by 'research'. Actually the stub records each
# arg on its own line, so we look for adjacent --task-type / research pairs.
task_type_values=$(awk '/^--task-type$/{getline; print}' "${ARGV_FILE}" 2>/dev/null || true)

if echo "${task_type_values}" | grep -q "^research$"; then
  pass "--task-type research found in captured argv (comp-A-001 tagged correctly)"
else
  fail "--task-type research NOT found in captured argv (task_type_values: $(echo "${task_type_values}" | tr '\n' '|'))"
  echo "--- report output ---"
  echo "${report_output}" | tail -20
  echo "--- captured argv ---"
  cat "${ARGV_FILE}" 2>/dev/null | head -60
fi

# ---------------------------------------------------------------------------
# Assert: --task-type generation for comp-A-002 (marker generation@T3, comp@T4)
# ---------------------------------------------------------------------------
if echo "${task_type_values}" | grep -q "^generation$"; then
  pass "--task-type generation found in captured argv (comp-A-002 tagged correctly)"
else
  fail "--task-type generation NOT found in captured argv"
fi

# ---------------------------------------------------------------------------
# Assert: --task-type unclassified for comp-B-001 (no marker file)
# ---------------------------------------------------------------------------
if echo "${task_type_values}" | grep -q "^unclassified$"; then
  pass "--task-type unclassified found in captured argv (comp-B-001 has no marker)"
else
  fail "--task-type unclassified NOT found in captured argv"
fi

# ---------------------------------------------------------------------------
# Assert: all meter completion calls have --task-type (always present)
# ---------------------------------------------------------------------------
meter_completions=0
task_type_count=0
if [[ -f "${ARGV_FILE}" ]]; then
  meter_completions=$(grep -c "^meter$" "${ARGV_FILE}" 2>/dev/null) || meter_completions=0
  task_type_count=$(grep -c "^--task-type$" "${ARGV_FILE}" 2>/dev/null) || task_type_count=0
fi

if [[ "${meter_completions}" -gt 0 && "${task_type_count}" -eq "${meter_completions}" ]]; then
  pass "--task-type present in all ${meter_completions} meter completion calls"
else
  fail "--task-type count (${task_type_count}) != meter completion count (${meter_completions})"
fi

# ---------------------------------------------------------------------------
# Assert: --agent with openclaw- prefix present
# ---------------------------------------------------------------------------
agent_values=$(awk '/^--agent$/{getline; print}' "${ARGV_FILE}" 2>/dev/null || true)

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
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
