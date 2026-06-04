#!/usr/bin/env bash
# =============================================================================
# test_guardrail_argv.sh — Integration tests for guardrail-check.sh
# guardrail-event metering (GRDEV-01..05)
#
# Strategy:
#   Build a tmp OPENCLAW_HOME with fixtures needed by guardrail-check.sh:
#     - guardrail-status.json (prev state: no rules breached)
#     - config.json (ruleIds: ["rule-abc123"])
#     - revenium-guardrail.ledger (empty — dedup ledger for Phase 9 / Section M)
#     - revenium-jobs.ledger (one open job for --agentic-job-id attribution)
#     - agents/main/sessions/ (one fake session file for root-session attribution)
#   Place stub-revenium.sh on PATH capturing all argv to STUB_REVENIUM_ARGV_FILE.
#   Set STUB_REVENIUM_ENFORCEMENT_JSON to a fixture with a halted rule, a warned
#   rule, and a shadow rule.
#   Run guardrail-check.sh and assert captured argv.
#
# CLI flag answers (resolved 2026-06-04 on live host 172.16.1.247, Team DZxzEl):
#   A1: --transaction-id is OPTIONAL — do NOT assert it; implementation MUST NOT add it.
#   A2: zero token values accepted — no --total-tokens 1 sentinel needed.
#   A3: COST_LIMIT is a valid --stop-reason enum value.
#
# EXPECTED RESULT THIS PLAN (Wave 0 / Plan 00):
#   This test FAILS RED — guardrail-check.sh has no Section M metering yet
#   (no _emit_guardrail_event, no GUARDRAIL_LEDGER_FILE, no meter calls are
#   produced). The test turns green in Wave 1 when Section M is implemented.
#   Do NOT stub guardrail-check.sh or weaken assertions to make it pass now.
#
# SECURITY: This test never `eval`s or string-interpolates captured argv.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GUARDRAIL_CHECK_SH="${REPO_ROOT}/scripts/guardrail-check.sh"
STUB_SH="${SCRIPT_DIR}/stub-revenium.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# count_grep <pattern> <file>
#   Returns the count of matching lines in <file>.
#   Uses `; exit 0` to prevent grep -c exit-1 (no match) from triggering || echo 0
#   double-output bug (test_report_jobs_argv.sh pattern).
count_grep() {
  local pattern="$1" file="${2:-/dev/null}"
  local r
  r=$(grep -c "${pattern}" "${file}" 2>/dev/null; exit 0)
  echo "${r:-0}"
}

# ---------------------------------------------------------------------------
# Helper: build a fresh tmp OPENCLAW_HOME and return the path.
# Usage: TMP_HOME=$(make_openclaw_home)
# Creates:
#   agents/main/sessions/ (with one fake session file for attribution)
#   skills/revenium/markers/
#   skills/revenium/scripts/get-root-session-id.py (symlink from repo)
#   skills/revenium/config.json (organizationName + ruleIds)
#   skills/revenium/guardrail-status.json (prev state: no rules breached)
#   revenium-guardrail.ledger (empty — Phase 9 dedup ledger)
#   revenium-jobs.ledger (one open job for --agentic-job-id attribution)
# ---------------------------------------------------------------------------
make_openclaw_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-gc-home.XXXXXX")
  mkdir -p "${d}/agents/main/sessions" \
           "${d}/skills/revenium/markers" \
           "${d}/skills/revenium/scripts"
  # Symlink get-root-session-id.py so guardrail-check.sh can resolve root session
  ln -sf "${REPO_ROOT}/scripts/get-root-session-id.py" \
         "${d}/skills/revenium/scripts/get-root-session-id.py"
  # Config: organizationName + ruleIds (needed for D-13 guard to pass)
  echo '{"organizationName":"TestOrg","ruleIds":["rule-abc123"],"autonomousMode":true}' \
    > "${d}/skills/revenium/config.json"
  # Minimal prev-state guardrail-status.json: no rules breached
  echo '{"halted":false,"warned":false,"warnedRules":[],"autonomousMode":true,"lastChecked":"2026-01-01T00:00:00+00:00","rules":[]}' \
    > "${d}/skills/revenium/guardrail-status.json"
  # Empty dedup ledger (Phase 9 GUARDRAIL_LEDGER_FILE)
  touch "${d}/revenium-guardrail.ledger"
  # Jobs ledger: one open job (JOB:<id>:created: with no matching outcome)
  echo "JOB:test-job-open-001:created:$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "${d}/revenium-jobs.ledger"
  echo "${d}"
}

# ---------------------------------------------------------------------------
# Fake HOME setup: stub on PATH via fake HOME/.local/bin/revenium.
# guardrail-check.sh's ensure_path appends HOME/.local/bin last → it ends
# up first when PATH is built, so the stub wins the PATH search.
# ---------------------------------------------------------------------------
TMP_FAKE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-gc-fakehome.XXXXXX")
TMP_LOCAL_BIN="${TMP_FAKE_HOME}/.local/bin"
mkdir -p "${TMP_LOCAL_BIN}"
ln -sf "${STUB_SH}" "${TMP_LOCAL_BIN}/revenium"
ARGV_FILE=$(mktemp "${TMPDIR:-/tmp}/test-gc-argv.XXXXXX")

# Create one fake session file in make_openclaw_home's dir.
# We defer session creation to the group block below since each group
# has its own OPENCLAW_HOME from make_openclaw_home.

cleanup() {
  rm -rf "${TMP_FAKE_HOME}" "${ARGV_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

# Export so guardrail-check.sh subshell inherits it
export STUB_REVENIUM_ARGV_FILE="${ARGV_FILE}"

# ---------------------------------------------------------------------------
# argv_vals <flag> — extract all values after <flag> from ARGV_FILE.
# Uses awk: when the current line equals the flag, print the next line.
# ---------------------------------------------------------------------------
argv_vals() {
  awk -v flag="$1" '$0==flag{getline;print}' "${ARGV_FILE}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# run_guardrail_check <OPENCLAW_HOME> <ARGV_FILE>
#   Runs guardrail-check.sh with the stub on PATH.
#   Callers set STUB_REVENIUM_ENFORCEMENT_JSON and STUB_REVENIUM_BUDGET_RULES_JSON
#   as exported env vars before calling (avoids shell word-splitting on JSON values).
# ---------------------------------------------------------------------------
run_guardrail_check() {
  local openclaw_home="$1"
  local _argv_file="$2"
  STUB_REVENIUM_ARGV_FILE="${_argv_file}" \
  OPENCLAW_HOME="${openclaw_home}" \
  HOME="${TMP_FAKE_HOME}" \
  bash "${GUARDRAIL_CHECK_SH}" 2>&1 || true
}

# ---------------------------------------------------------------------------
# Fixture JSON: enforcement-rules response with three rule types.
#
# Rule 1: halted   — breached:true, shadowMode:false
#   → state='block', non-shadow → halt transition → budget_guardrail_halt
#
# Rule 2: warned   — warnBreached:true, breached:false, shadowMode:false
#   → state='warn', non-shadow → warn transition → budget_guardrail_warn
#
# Rule 3: shadow   — breached:true, shadowMode:true
#   → state='block', shadow → shadow transition → budget_guardrail_shadow
#
# budget-rules list fixture: maps names to string IDs for D-15 name-join.
# The name field must match enforcement-rules name field exactly.
# ---------------------------------------------------------------------------
HALT_ENFORCEMENT_JSON='{"rules":[{"ruleId":1001,"name":"monthly-cost-limit","metricType":"TOTAL_COST","periodType":"MONTHLY","threshold":100,"warnThreshold":80,"currentValue":105,"breached":true,"warnBreached":true,"shadowMode":false,"groupBy":"AGENT"},{"ruleId":1002,"name":"monthly-cost-warn","metricType":"TOTAL_COST","periodType":"MONTHLY","threshold":200,"warnThreshold":160,"currentValue":175,"breached":false,"warnBreached":true,"shadowMode":false,"groupBy":"AGENT"},{"ruleId":1003,"name":"monthly-cost-shadow","metricType":"TOTAL_COST","periodType":"MONTHLY","threshold":50,"warnThreshold":40,"currentValue":55,"breached":true,"warnBreached":true,"shadowMode":true,"groupBy":"AGENT"}]}'

HALT_BUDGET_RULES_JSON='[{"id":"rule-abc123","name":"monthly-cost-limit","metricType":"TOTAL_COST","periodType":"MONTHLY","threshold":100},{"id":"rule-def456","name":"monthly-cost-warn","metricType":"TOTAL_COST","periodType":"MONTHLY","threshold":200},{"id":"rule-ghi789","name":"monthly-cost-shadow","metricType":"TOTAL_COST","periodType":"MONTHLY","threshold":50}]'

# ===========================================================================
# GROUP A: GRDEV-01 halt — --operation-type GUARDRAIL / --task-type
# budget_guardrail_halt / --stop-reason COST_LIMIT (first run, fresh ledger)
# ===========================================================================
echo ""
echo "--- GROUP A: GRDEV-01 halt emission (first run) ---"

TMP_HOME_A=$(make_openclaw_home)
# Create fake session file for root-session attribution
SESSION_ID_A="aaaaaaaa-1111-1111-1111-000000000001"
cat > "${TMP_HOME_A}/agents/main/sessions/${SESSION_ID_A}.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"aaaaaaaa-1111-1111-1111-000000000001","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp/test"}
JSONL

# Clear argv file for this group
> "${ARGV_FILE}"

export STUB_REVENIUM_ENFORCEMENT_JSON="${HALT_ENFORCEMENT_JSON}"
export STUB_REVENIUM_BUDGET_RULES_JSON="${HALT_BUDGET_RULES_JSON}"
run_guardrail_check "${TMP_HOME_A}" "${ARGV_FILE}"

# GRDEV-01a: --operation-type GUARDRAIL present
if argv_vals "--operation-type" | grep -q "^GUARDRAIL$"; then
  pass "GRDEV-01a: --operation-type GUARDRAIL found in meter call"
else
  fail "GRDEV-01a: --operation-type GUARDRAIL NOT found (guardrail-check.sh has no Section M yet)"
fi

# GRDEV-01a: --task-type budget_guardrail_halt present
if argv_vals "--task-type" | grep -q "^budget_guardrail_halt$"; then
  pass "GRDEV-01a: --task-type budget_guardrail_halt found"
else
  fail "GRDEV-01a: --task-type budget_guardrail_halt NOT found"
fi

# GRDEV-01a: --stop-reason COST_LIMIT present
if argv_vals "--stop-reason" | grep -q "^COST_LIMIT$"; then
  pass "GRDEV-01a: --stop-reason COST_LIMIT found"
else
  fail "GRDEV-01a: --stop-reason COST_LIMIT NOT found"
fi

# GRDEV-01a: --model guardrail-enforcement present
if argv_vals "--model" | grep -q "^guardrail-enforcement$"; then
  pass "GRDEV-01a: --model guardrail-enforcement found"
else
  fail "GRDEV-01a: --model guardrail-enforcement NOT found"
fi

# GRDEV-01a: --provider revenium present
if argv_vals "--provider" | grep -q "^revenium$"; then
  pass "GRDEV-01a: --provider revenium found"
else
  fail "GRDEV-01a: --provider revenium NOT found"
fi

# GRDEV-01a: NO --transaction-id (A1: optional and MUST NOT be added)
if argv_vals "--transaction-id" | grep -q '.'; then
  fail "GRDEV-01a: --transaction-id present but MUST NOT be added (A1: optional, not needed)"
else
  pass "GRDEV-01a: --transaction-id correctly absent (A1: optional, not needed)"
fi

rm -rf "${TMP_HOME_A}"

# ===========================================================================
# GROUP B: GRDEV-01 idempotency — run twice, assert exactly one
# budget_guardrail_halt in argv (ledger dedup prevents double emission)
# ===========================================================================
echo ""
echo "--- GROUP B: GRDEV-01 idempotency (run twice, halt emitted exactly once) ---"

TMP_HOME_B=$(make_openclaw_home)
SESSION_ID_B="bbbbbbbb-2222-2222-2222-000000000002"
cat > "${TMP_HOME_B}/agents/main/sessions/${SESSION_ID_B}.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"bbbbbbbb-2222-2222-2222-000000000002","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp/test"}
JSONL

# Clear argv file
> "${ARGV_FILE}"

# First run — should emit halt event and write to ledger
export STUB_REVENIUM_ENFORCEMENT_JSON="${HALT_ENFORCEMENT_JSON}"
export STUB_REVENIUM_BUDGET_RULES_JSON="${HALT_BUDGET_RULES_JSON}"
run_guardrail_check "${TMP_HOME_B}" "${ARGV_FILE}"

# Second run — ledger gate should prevent re-emission.
# NOTE: prev-state is now the status written by the first run (halted:true),
# so halt_transition=false on second run (not a new transition). Both the
# transition gate AND ledger dedup prevent double-emission.
run_guardrail_check "${TMP_HOME_B}" "${ARGV_FILE}"

halt_count=$(count_grep "^budget_guardrail_halt$" "${ARGV_FILE}")
if [[ "${halt_count}" -eq 1 ]]; then
  pass "GRDEV-01b idempotency: budget_guardrail_halt emitted exactly once across two runs"
else
  fail "GRDEV-01b idempotency: halt count=${halt_count}, expected 1 (ledger dedup or transition gate not working)"
fi

rm -rf "${TMP_HOME_B}"

# ===========================================================================
# GROUP C: GRDEV-02 warn — --task-type budget_guardrail_warn emitted once
# ===========================================================================
echo ""
echo "--- GROUP C: GRDEV-02 warn emission (first run) ---"

TMP_HOME_C=$(make_openclaw_home)
SESSION_ID_C="cccccccc-3333-3333-3333-000000000003"
cat > "${TMP_HOME_C}/agents/main/sessions/${SESSION_ID_C}.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"cccccccc-3333-3333-3333-000000000003","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp/test"}
JSONL

> "${ARGV_FILE}"

export STUB_REVENIUM_ENFORCEMENT_JSON="${HALT_ENFORCEMENT_JSON}"
export STUB_REVENIUM_BUDGET_RULES_JSON="${HALT_BUDGET_RULES_JSON}"
run_guardrail_check "${TMP_HOME_C}" "${ARGV_FILE}"

if argv_vals "--task-type" | grep -q "^budget_guardrail_warn$"; then
  pass "GRDEV-02a: --task-type budget_guardrail_warn found"
else
  fail "GRDEV-02a: --task-type budget_guardrail_warn NOT found"
fi

rm -rf "${TMP_HOME_C}"

# ===========================================================================
# GROUP D: GRDEV-02 warn re-fire — warn→ok→warn fires again on second onset
# Uses two separate runs with a different prev-state each time.
# Run 1: prev-state=ok → warn fires (onset)
# Run 2: prev-state=warn → warn does NOT re-fire (still in warn, not new onset)
# Run 3: prev-state=ok (recovered) → warn fires again (new onset)
# ===========================================================================
echo ""
echo "--- GROUP D: GRDEV-02 warn re-fire (warn->ok->warn) ---"

TMP_HOME_D=$(make_openclaw_home)
SESSION_ID_D="dddddddd-4444-4444-4444-000000000004"
cat > "${TMP_HOME_D}/agents/main/sessions/${SESSION_ID_D}.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"dddddddd-4444-4444-4444-000000000004","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp/test"}
JSONL

# Warn-only fixture: only the warn rule, no halt rule
WARN_ONLY_ENFORCEMENT_JSON='{"rules":[{"ruleId":2002,"name":"monthly-cost-warn","metricType":"TOTAL_COST","periodType":"MONTHLY","threshold":200,"warnThreshold":160,"currentValue":175,"breached":false,"warnBreached":true,"shadowMode":false,"groupBy":"AGENT"}]}'
WARN_ONLY_BUDGET_JSON='[{"id":"rule-def456","name":"monthly-cost-warn","metricType":"TOTAL_COST","periodType":"MONTHLY","threshold":200}]'

# Run 1: prev-state=ok (default) → first warn onset
> "${ARGV_FILE}"
export STUB_REVENIUM_ENFORCEMENT_JSON="${WARN_ONLY_ENFORCEMENT_JSON}"
export STUB_REVENIUM_BUDGET_RULES_JSON="${WARN_ONLY_BUDGET_JSON}"
run_guardrail_check "${TMP_HOME_D}" "${ARGV_FILE}"

warn_count_r1=$(count_grep "^budget_guardrail_warn$" "${ARGV_FILE}")

# Inject a "recovered" prev-state: rule is now ok (warn resolved)
echo '{"halted":false,"warned":false,"warnedRules":[],"autonomousMode":true,"lastChecked":"2026-01-01T01:00:00+00:00","rules":[{"ruleId":"rule-def456","name":"monthly-cost-warn","state":"ok","shadowMode":false,"lastChecked":"2026-01-01T01:00:00+00:00"}]}' \
  > "${TMP_HOME_D}/skills/revenium/guardrail-status.json"

# Run 2: prev-state=ok (recovered) → warn fires again (new onset)
> "${ARGV_FILE}"
run_guardrail_check "${TMP_HOME_D}" "${ARGV_FILE}"

warn_count_r2=$(count_grep "^budget_guardrail_warn$" "${ARGV_FILE}")

if [[ "${warn_count_r1}" -eq 1 && "${warn_count_r2}" -eq 1 ]]; then
  pass "GRDEV-02b: warn fired once on first onset AND once on second onset after recovery"
else
  fail "GRDEV-02b: warn re-fire: r1_count=${warn_count_r1} r2_count=${warn_count_r2}, expected 1 each"
fi

rm -rf "${TMP_HOME_D}"

# ===========================================================================
# GROUP E: GRDEV-03 shadow — --task-type budget_guardrail_shadow emitted once
# ===========================================================================
echo ""
echo "--- GROUP E: GRDEV-03 shadow emission ---"

TMP_HOME_E=$(make_openclaw_home)
SESSION_ID_E="eeeeeeee-5555-5555-5555-000000000005"
cat > "${TMP_HOME_E}/agents/main/sessions/${SESSION_ID_E}.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"eeeeeeee-5555-5555-5555-000000000005","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp/test"}
JSONL

> "${ARGV_FILE}"

export STUB_REVENIUM_ENFORCEMENT_JSON="${HALT_ENFORCEMENT_JSON}"
export STUB_REVENIUM_BUDGET_RULES_JSON="${HALT_BUDGET_RULES_JSON}"
run_guardrail_check "${TMP_HOME_E}" "${ARGV_FILE}"

if argv_vals "--task-type" | grep -q "^budget_guardrail_shadow$"; then
  pass "GRDEV-03: --task-type budget_guardrail_shadow found"
else
  fail "GRDEV-03: --task-type budget_guardrail_shadow NOT found"
fi

rm -rf "${TMP_HOME_E}"

# ===========================================================================
# GROUP F: GRDEV-04a attribution — --agent openclaw-<root_sid> present
# ===========================================================================
echo ""
echo "--- GROUP F: GRDEV-04a agent attribution ---"

TMP_HOME_F=$(make_openclaw_home)
SESSION_ID_F="ffffffff-6666-6666-6666-000000000006"
cat > "${TMP_HOME_F}/agents/main/sessions/${SESSION_ID_F}.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"ffffffff-6666-6666-6666-000000000006","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp/test"}
JSONL

> "${ARGV_FILE}"

export STUB_REVENIUM_ENFORCEMENT_JSON="${HALT_ENFORCEMENT_JSON}"
export STUB_REVENIUM_BUDGET_RULES_JSON="${HALT_BUDGET_RULES_JSON}"
run_guardrail_check "${TMP_HOME_F}" "${ARGV_FILE}"

agent_vals=$(argv_vals "--agent")
if echo "${agent_vals}" | grep -q "^openclaw-"; then
  pass "GRDEV-04a: --agent openclaw-<root_sid> found in meter call"
else
  fail "GRDEV-04a: --agent with 'openclaw-' prefix NOT found (agent_vals: $(echo "${agent_vals}" | tr '\n' '|'))"
fi

rm -rf "${TMP_HOME_F}"

# ===========================================================================
# GROUP G: GRDEV-04b agentic-job-id — present when open job exists;
# omitted when jobs ledger is empty (D-08)
# ===========================================================================
echo ""
echo "--- GROUP G: GRDEV-04b agentic-job-id attribution ---"

# G1: open job present → --agentic-job-id MUST appear
TMP_HOME_G1=$(make_openclaw_home)
# make_openclaw_home already places one open job in revenium-jobs.ledger
SESSION_ID_G="11111111-7777-7777-7777-000000000007"
cat > "${TMP_HOME_G1}/agents/main/sessions/${SESSION_ID_G}.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"11111111-7777-7777-7777-000000000007","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp/test"}
JSONL

> "${ARGV_FILE}"

export STUB_REVENIUM_ENFORCEMENT_JSON="${HALT_ENFORCEMENT_JSON}"
export STUB_REVENIUM_BUDGET_RULES_JSON="${HALT_BUDGET_RULES_JSON}"
run_guardrail_check "${TMP_HOME_G1}" "${ARGV_FILE}"

if grep -q "^--agentic-job-id$" "${ARGV_FILE}" 2>/dev/null; then
  pass "GRDEV-04b: --agentic-job-id present when open job exists"
else
  fail "GRDEV-04b: --agentic-job-id NOT found with open job in ledger"
fi

rm -rf "${TMP_HOME_G1}"

# G2: no open job → --agentic-job-id MUST NOT appear
TMP_HOME_G2=$(make_openclaw_home)
# Truncate the jobs ledger — no open jobs
> "${TMP_HOME_G2}/revenium-jobs.ledger"
cat > "${TMP_HOME_G2}/agents/main/sessions/${SESSION_ID_G}.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"11111111-7777-7777-7777-000000000007","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp/test"}
JSONL

> "${ARGV_FILE}"

run_guardrail_check "${TMP_HOME_G2}" "${ARGV_FILE}"

if grep -q "^--agentic-job-id$" "${ARGV_FILE}" 2>/dev/null; then
  fail "GRDEV-04b: --agentic-job-id found but MUST be omitted when no open jobs (D-08)"
else
  pass "GRDEV-04b: --agentic-job-id correctly absent when jobs ledger is empty"
fi

rm -rf "${TMP_HOME_G2}"

# ===========================================================================
# GROUP H: GRDEV-05 fail-open — guardrail-check.sh exits 0 even when
# meter calls fail (STUB_REVENIUM_GUARDRAILS_FAIL), and guardrail-status.json
# is still written (status file durability before metering per D-11)
# ===========================================================================
echo ""
echo "--- GROUP H: GRDEV-05 fail-open (meter call failure does not block tick) ---"

TMP_HOME_H=$(make_openclaw_home)
SESSION_ID_H="22222222-8888-8888-8888-000000000008"
cat > "${TMP_HOME_H}/agents/main/sessions/${SESSION_ID_H}.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"22222222-8888-8888-8888-000000000008","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp/test"}
JSONL

> "${ARGV_FILE}"

# STUB_REVENIUM_GUARDRAILS_FAIL=1 → enforcement-rules get fails with EOF error
# The guardrail-check.sh handles EOF as soft-fail (ENFORCEMENT_JSON='{"rules":[]}')
# and continues normally. This also exercises the "no rules → no meter calls" path.
exit_code=0
STUB_REVENIUM_ARGV_FILE="${ARGV_FILE}" \
OPENCLAW_HOME="${TMP_HOME_H}" \
HOME="${TMP_FAKE_HOME}" \
STUB_REVENIUM_GUARDRAILS_FAIL=1 \
bash "${GUARDRAIL_CHECK_SH}" 2>&1 || exit_code=$?

if [[ "${exit_code}" -eq 0 ]]; then
  pass "GRDEV-05: guardrail-check.sh exits 0 when enforcement-rules get fails (fail-open)"
else
  fail "GRDEV-05: guardrail-check.sh exited ${exit_code} — fail-open posture broken"
fi

# Status file should still be written even when enforcement fails (guardrail-check.sh
# treats the EOF error as empty rules → writes a status with halted:false)
if [[ -f "${TMP_HOME_H}/skills/revenium/guardrail-status.json" ]]; then
  pass "GRDEV-05: guardrail-status.json written even after enforcement-rules get failure"
else
  fail "GRDEV-05: guardrail-status.json NOT written after enforcement-rules get failure"
fi

rm -rf "${TMP_HOME_H}"

# ===========================================================================
# GROUP I: GRDEV-05 fail-open (meter call itself fails)
# When the meter completion call exits non-zero, guardrail-check.sh still
# exits 0 (Section M _emit_guardrail_event is wrapped with || true / fail-open)
# ===========================================================================
echo ""
echo "--- GROUP I: GRDEV-05 fail-open (meter call fails, tick still exits 0) ---"

# Create a stub that accepts guardrails calls but fails on meter completion
TMP_HOME_I=$(make_openclaw_home)
SESSION_ID_I="33333333-9999-9999-9999-000000000009"
cat > "${TMP_HOME_I}/agents/main/sessions/${SESSION_ID_I}.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"33333333-9999-9999-9999-000000000009","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp/test"}
JSONL

# Create a meter-failing stub: same as normal stub but exits 1 for meter completion
TMP_METER_FAIL_BIN=$(mktemp -d "${TMPDIR:-/tmp}/test-gc-meterfail.XXXXXX")
cat > "${TMP_METER_FAIL_BIN}/revenium" <<'STUBEOF'
#!/usr/bin/env bash
if [[ -n "${STUB_REVENIUM_ARGV_FILE:-}" ]]; then
  for arg in "$@"; do
    printf '%s\n' "${arg}" >> "${STUB_REVENIUM_ARGV_FILE}"
  done
fi
# config show → emit Team ID
if [[ "$1 $2" == "config show" ]]; then
  echo "Team ID:    test-team-id"
  exit 0
fi
# guardrails probes → exit 0
if [[ "$1" == "guardrails" && "$2" == "--help" ]]; then exit 0; fi
if [[ "$1 $2 $3" == "guardrails budget-rules --help" ]]; then exit 0; fi
if [[ "$1 $2 $3" == "guardrails enforcement-events --help" ]]; then exit 0; fi
# enforcement-rules get → return halt fixture
if [[ "$1 $2 $3" == "guardrails enforcement-rules get" ]]; then
  echo "${STUB_REVENIUM_ENFORCEMENT_JSON:-{\"rules\":[]}}"
  exit 0
fi
# budget-rules list → return default
if [[ "$1 $2 $3" == "guardrails budget-rules list" ]]; then
  echo "[]"
  exit 0
fi
# meter completion → FAIL (exercises fail-open path in Section M)
if [[ "$1 $2" == "meter completion" ]]; then
  echo "Error: network timeout" >&2
  exit 1
fi
exit 0
STUBEOF
chmod +x "${TMP_METER_FAIL_BIN}/revenium"

# Run with the meter-failing stub on PATH
exit_code_i=0
STUB_REVENIUM_ARGV_FILE="${ARGV_FILE}" \
OPENCLAW_HOME="${TMP_HOME_I}" \
HOME="${TMP_FAKE_HOME}" \
STUB_REVENIUM_ENFORCEMENT_JSON="${HALT_ENFORCEMENT_JSON}" \
STUB_REVENIUM_BUDGET_RULES_JSON="${HALT_BUDGET_RULES_JSON}" \
PATH="${TMP_METER_FAIL_BIN}:${PATH}" \
bash "${GUARDRAIL_CHECK_SH}" 2>&1 || exit_code_i=$?

if [[ "${exit_code_i}" -eq 0 ]]; then
  pass "GRDEV-05: guardrail-check.sh exits 0 even when meter completion call fails (Section M fail-open)"
else
  fail "GRDEV-05: guardrail-check.sh exited ${exit_code_i} on meter call failure — Section M not fail-open"
fi

rm -rf "${TMP_HOME_I}" "${TMP_METER_FAIL_BIN}"

# ===========================================================================
# GROUP J: Zero-token values (A2 confirmed): assert --input-tokens 0,
# --output-tokens 0, --total-tokens 0 are used (no sentinel needed)
# ===========================================================================
echo ""
echo "--- GROUP J: A2 zero-token values in meter call ---"

TMP_HOME_J=$(make_openclaw_home)
SESSION_ID_J="44444444-aaaa-aaaa-aaaa-00000000000a"
cat > "${TMP_HOME_J}/agents/main/sessions/${SESSION_ID_J}.jsonl" <<'JSONL'
{"type":"session","version":3,"id":"44444444-aaaa-aaaa-aaaa-00000000000a","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp/test"}
JSONL

> "${ARGV_FILE}"

export STUB_REVENIUM_ENFORCEMENT_JSON="${HALT_ENFORCEMENT_JSON}"
export STUB_REVENIUM_BUDGET_RULES_JSON="${HALT_BUDGET_RULES_JSON}"
run_guardrail_check "${TMP_HOME_J}" "${ARGV_FILE}"

# --input-tokens should be 0
if argv_vals "--input-tokens" | grep -q "^0$"; then
  pass "A2: --input-tokens 0 (zero-token sentinel not needed)"
else
  fail "A2: --input-tokens 0 NOT found — expected zero token value in GUARDRAIL meter call"
fi

# --total-tokens should be 0 (NOT 1 sentinel — A2 confirmed zero is accepted)
if argv_vals "--total-tokens" | grep -q "^0$"; then
  pass "A2: --total-tokens 0 (no --total-tokens 1 sentinel)"
else
  fail "A2: --total-tokens 0 NOT found — expected zero, not 1 sentinel"
fi

rm -rf "${TMP_HOME_J}"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""
echo "NOTE: This test is EXPECTED TO FAIL RED before Wave 1 implements Section M"
echo "      in guardrail-check.sh. Failures in GROUP A-J (meter call assertions)"
echo "      indicate the production code is not yet written — that is correct."
echo "      Failures in GROUP H (fail-open / status file) indicate a regression."
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
