#!/usr/bin/env bash
# =============================================================================
# test_report_argv.sh — Integration tests for report.sh task-type/agent wiring
# (METER-03 / TRACE-01 / TRACE-02)
#
# Phase 19 (D-01/D-05): rebuilt on the synthetic-SQLite fixture harness
# (tests/lib/mk-session-store.sh) — report.sh's session discovery and
# completion metering are now SQL-only. Every scenario below is unchanged in
# INTENT from the pre-2.0 JSONL-fixture version; only the fixture
# construction changed.
#
# Strategy:
#   Build one synthetic SQLite store at the real
#   agents/<agentId>/agent/openclaw-agent.sqlite layout (store_db_paths' glob
#   is exercised, not bypassed), holding four sessions:
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
#     Marker carries completion_id = comp's responseId → exact match → tagged
#     correctly. LOAD-BEARING CHANGE (D-05): under the pre-2.0 read path the
#     marker's completion_id matched the record's top-level .id; under the
#     SQL seam, report.sh's Phase A correlation matches the marker against
#     the completion's transaction id, which store_completions defines as
#     responseId (D-05). If this fixture instead set completion_id to the
#     record's own synthetic .id (msg-id-N), the mismatch would NOT be
#     visible as an obvious failure here — Phase D's timestamp fallback
#     would still produce a plausible-looking "analysis" label, silently
#     masking the exact-match path being broken. Session C's marker
#     therefore MUST use the completion's responseId, so a regression in
#     that correlation shows up as a red test rather than a quiet
#     degradation to the fallback path.
#
#   Session D (anti-bleed — id-keyed marker does NOT steal label for other turns):
#     comp1 has a matching marker (completion_id=comp1's responseId) → tagged
#     comp2 has NO marker referencing it → unclassified (must not steal comp1's)
#
#   - Place stub-revenium.sh on PATH capturing all argv to STUB_REVENIUM_ARGV_FILE
#   - Run report.sh
#   - Assert captured argv contains --task-type with correct labels and
#     --agent with "openclaw-" prefix
#
# tests/fixtures/sessions/*.jsonl are pre-2.0 fixtures, left untouched on
# disk — they are not read by this suite.
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
# Build tmp OPENCLAW_HOME
# ---------------------------------------------------------------------------
TMP_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-rpt-home.XXXXXX")
TMP_SKILL_DIR="${TMP_HOME}/skills/revenium"
TMP_MARKERS="${TMP_SKILL_DIR}/markers"
DB="${TMP_HOME}/agents/main/agent/openclaw-agent.sqlite"

mkdir -p "${TMP_SKILL_DIR}" "${TMP_MARKERS}"
mk_store "${DB}"

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
#   T1: comp1 response    2026-01-01T10:06:00.000Z
#   T2: marker research   2026-01-01T10:07:00Z  → marker after comp1 → research
#   T3: comp2 response    2026-01-01T10:09:00.000Z
#   T4: marker generation 2026-01-01T10:10:00Z  → marker after comp2 → generation
#
# Markers for Session A have NO completion_id (legacy/Phase-D path).
# ---------------------------------------------------------------------------
SID_A="aaaaaaaa-1111-1111-1111-000000000001"
mk_session "${DB}" "${SID_A}" "agent:main:${SID_A}" "" 100
mk_assistant_event "${DB}" "${SID_A}" 0 "resp-A-001" "run-A-1" 150 "claude-sonnet-4-5" "2026-01-01T10:06:00.000Z"
mk_assistant_event "${DB}" "${SID_A}" 1 "resp-A-002" "run-A-1" 180 "claude-sonnet-4-5" "2026-01-01T10:09:00.000Z"

# Marker file for session A: two markers WITHOUT completion_id (legacy Phase D markers).
# Markers are written AFTER their respective completions.
MARKER_A="${TMP_MARKERS}/${SID_A}.jsonl"
echo '{"ts":"2026-01-01T10:07:00Z","task_type":"research"}' > "${MARKER_A}"
echo '{"ts":"2026-01-01T10:10:00Z","task_type":"generation"}' >> "${MARKER_A}"

# ---------------------------------------------------------------------------
# Session B: no marker file (should be unclassified)
# ---------------------------------------------------------------------------
SID_B="bbbbbbbb-2222-2222-2222-000000000002"
mk_session "${DB}" "${SID_B}" "agent:main:${SID_B}" "" 101
mk_assistant_event "${DB}" "${SID_B}" 0 "resp-B-001" "run-B-1" 120 "claude-sonnet-4-5" "2026-01-01T11:02:00.000Z"

# No marker file for SID_B

# ---------------------------------------------------------------------------
# Session C: Phase A — exact completion_id match
#
# The marker carries completion_id = the completion's responseId (D-05: the
# transaction id store_completions dedups on). Phase A should match it
# regardless of timestamp ordering. The marker ts is AFTER the completion ts
# (real lifecycle).
# ---------------------------------------------------------------------------
SID_C="cccccccc-3333-3333-3333-000000000003"
mk_session "${DB}" "${SID_C}" "agent:main:${SID_C}" "" 102
mk_assistant_event "${DB}" "${SID_C}" 0 "resp-C-001" "run-C-1" 135 "claude-sonnet-4-5" "2026-01-01T12:02:00.000Z"

# Marker for session C: includes completion_id (the responseId) → Phase A exact match.
MARKER_C="${TMP_MARKERS}/${SID_C}.jsonl"
echo '{"ts":"2026-01-01T12:03:00Z","task_type":"analysis","completion_id":"resp-C-001"}' > "${MARKER_C}"

# ---------------------------------------------------------------------------
# Session D: anti-bleed — id-keyed marker must NOT steal label from other turns
#
# comp-D-001 (responseId resp-D-001) has a matching marker → tagged "debugging"
# comp-D-002 (responseId resp-D-002) has NO marker referencing it → must be
#   unclassified (the id-keyed marker for comp-D-001 must not bleed onto
#   comp-D-002 via timestamp fallback, because markers with a completion_id
#   are excluded from Phase D according to the contract: they belong to a
#   specific completion).
# ---------------------------------------------------------------------------
SID_D="dddddddd-4444-4444-4444-000000000004"
mk_session "${DB}" "${SID_D}" "agent:main:${SID_D}" "" 103
mk_assistant_event "${DB}" "${SID_D}" 0 "resp-D-001" "run-D-1" 105 "claude-sonnet-4-5" "2026-01-01T13:02:00.000Z"
mk_assistant_event "${DB}" "${SID_D}" 1 "resp-D-002" "run-D-1" 90 "claude-sonnet-4-5" "2026-01-01T13:05:00.000Z"

# Marker for session D: only comp-D-001 has a marker (id-keyed on its responseId).
# comp-D-002 has no corresponding marker.
MARKER_D="${TMP_MARKERS}/${SID_D}.jsonl"
echo '{"ts":"2026-01-01T13:03:00Z","task_type":"debugging","completion_id":"resp-D-001"}' > "${MARKER_D}"

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
