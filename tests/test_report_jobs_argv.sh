#!/usr/bin/env bash
# =============================================================================
# test_report_jobs_argv.sh — Integration tests for report.sh agentic-job wiring
# (JLIFE-01..05)
#
# Strategy:
#   Build a tmp OPENCLAW_HOME with session JSONL fixtures that contain
#   kind:"job" markers correlating to completions.  Place stub-revenium.sh on
#   PATH capturing all argv to STUB_REVENIUM_ARGV_FILE.  Run report.sh and
#   assert the captured argv and revenium-jobs.ledger contain the expected
#   tokens.
#
# EXPECTED RESULT THIS PLAN (Wave 0 / Plan 01):
#   This test FAILS RED — report.sh has no job wiring yet (no create/outcome/
#   --agentic-job-id tokens are produced).  The test turns green across Plans
#   02 (probe + ledger + stamping) and 03 (create/outcome + CR-02/D-12 fixture).
#   Do NOT stub report.sh or weaken assertions to make it pass now.
#
# Pitfall 4 (RECORDED): test_report_argv.sh is left UNTOUCHED and job-free.
#   All Phase 6 job fixtures live here.  Adding job markers to Sessions A-D in
#   the old test would silently break its no-agentic-job assertion (line 285).
#
# SECURITY (T-06-01 / T-06-02):
#   - This test never `eval`s or string-interpolates captured argv.
#   - --metadata JSON values are parsed via env-passing python3 json.loads.
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
# Helper: build a fresh tmp OPENCLAW_HOME and return the path.
# Usage: TMP_HOME=$(make_openclaw_home)
# Creates:  agents/main/sessions, skills/revenium/markers,
#           revenium-offsets.json ({}), revenium-reported.ledger (empty),
#           revenium-jobs.ledger (empty), skills/revenium/config.json
# ---------------------------------------------------------------------------
make_openclaw_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-rpt-jobs-home.XXXXXX")
  mkdir -p "${d}/agents/main/sessions" "${d}/skills/revenium/markers" \
            "${d}/skills/revenium/scripts"
  # Symlink get-root-session-id.py so report.sh can resolve subagent->root
  # for GROUP F/G/H tests.  Groups A-E use single root sessions and never
  # invoke the resolver; the symlink is harmless for them.
  ln -sf "${REPO_ROOT}/scripts/get-root-session-id.py" \
         "${d}/skills/revenium/scripts/get-root-session-id.py"
  echo '{}' > "${d}/revenium-offsets.json"
  touch "${d}/revenium-reported.ledger"
  touch "${d}/revenium-jobs.ledger"
  echo '{"organizationName":"TestOrg"}' > "${d}/skills/revenium/config.json"
  echo "${d}"
}

# ---------------------------------------------------------------------------
# Fake HOME setup: stub on PATH via fake HOME/.local/bin/revenium
# All test runs share a single fake HOME so HOME= is always settable.
# ---------------------------------------------------------------------------
TMP_FAKE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-rpt-jobs-fakehome.XXXXXX")
TMP_LOCAL_BIN="${TMP_FAKE_HOME}/.local/bin"
mkdir -p "${TMP_LOCAL_BIN}"
ln -sf "${STUB_SH}" "${TMP_LOCAL_BIN}/revenium"

cleanup() {
  rm -rf "${TMP_FAKE_HOME}" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# count_grep <pattern> <file>
#   Returns the count of matching lines in <file>.
#   Returns 0 if file is missing or pattern does not match.
#   Does NOT use `|| echo 0` which causes "0\n0" double-output when grep -c
#   exits 1 (no match but file exists).
# ---------------------------------------------------------------------------
count_grep() {
  local pattern="$1" file="${2:-/dev/null}"
  local r
  r=$(grep -c "${pattern}" "${file}" 2>/dev/null; exit 0)
  echo "${r:-0}"
}

# ---------------------------------------------------------------------------
# run_report <OPENCLAW_HOME> <ARGV_FILE> [extra env vars...]
#   Runs report.sh with the stub on PATH; returns its exit code.
#   Caller already exported STUB_REVENIUM_ARGV_FILE=<ARGV_FILE>.
# ---------------------------------------------------------------------------
run_report() {
  local openclaw_home="$1"
  local _argv_file="$2"
  shift 2
  local -a extra_env=("$@")
  STUB_REVENIUM_ARGV_FILE="${_argv_file}" \
  OPENCLAW_HOME="${openclaw_home}" \
  HOME="${TMP_FAKE_HOME}" \
  env "${extra_env[@]+"${extra_env[@]}"}" \
  bash "${REPORT_SH}" 2>&1 || true
  # (env: expanded VAR=val words are not recognized as assignment prefixes by
  # the shell, so without `env` an extra_env entry would be executed as the
  # command name. With no extras, `env bash ...` is behavior-identical.)
}

# ===========================================================================
# FIXTURE SESSIONS
# ===========================================================================
# We use isolated OPENCLAW_HOMEs for each fixture group so ledgers don't
# interfere.  Shared session IDs across groups use distinct hexes.

# ---------------------------------------------------------------------------
# Session J1: SUCCESS job (JLIFE-01/02/03/05)
#   - completion comp-J1-001 at T1
#   - job marker kind:"job" status:"SUCCESS" completion_id="comp-J1-001"
#     (marker ts AFTER completion ts — real lifecycle)
# ---------------------------------------------------------------------------
SID_J1="11111111-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
JOB_ID_J1="add-feature-1ab2"
JOB_NAME_J1="Add Feature"
JOB_TYPE_J1="feature_development"

# ---------------------------------------------------------------------------
# Session J2: FAILED job (JLIFE-03 + D-08)
#   - completion comp-J2-001
#   - job marker status:"FAILED" with failure_reason
# ---------------------------------------------------------------------------
SID_J2="22222222-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
JOB_ID_J2="fix-bug-2cd3"
JOB_NAME_J2="Fix Bug"
JOB_TYPE_J2="bug_fix"
FAILURE_REASON_J2="test suite failing: 3 assertions red"

# ---------------------------------------------------------------------------
# Session J3: CANCELLED job (JLIFE-03 + D-07)
#   - completion comp-J3-001
#   - job marker status:"CANCELLED"
# ---------------------------------------------------------------------------
SID_J3="33333333-cccc-cccc-cccc-cccccccccccc"
JOB_ID_J3="review-docs-3ef4"
JOB_NAME_J3="Review Docs"
JOB_TYPE_J3="documentation"

# ===========================================================================
# GROUP A: SUCCESS + FAILED + CANCELLED fixtures (shared OPENCLAW_HOME)
# ===========================================================================
TMP_HOME_A=$(make_openclaw_home)
ARGV_FILE_A=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-a.XXXXXX")

# Session J1 — SUCCESS
SESSION_J1="${TMP_HOME_A}/agents/main/sessions/${SID_J1}.jsonl"
cat > "${SESSION_J1}" <<JSONL
{"type":"session","version":3,"id":"${SID_J1}","timestamp":"2026-02-01T10:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-J1-001","parentId":"00000000","timestamp":"2026-02-01T10:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Build the feature"}]}}
{"type":"message","id":"comp-J1-001","parentId":"user-J1-001","timestamp":"2026-02-01T10:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Feature implemented"}],"usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150}}}
JSONL

MARKER_J1="${TMP_HOME_A}/skills/revenium/markers/${SID_J1}.jsonl"
printf '%s\n' '{"kind":"job","ts":"2026-02-01T10:03:00Z","sid":"'"${SID_J1}"'","agentic_job_id":"'"${JOB_ID_J1}"'","job_name":"'"${JOB_NAME_J1}"'","job_type":"'"${JOB_TYPE_J1}"'","status":"SUCCESS","completion_id":"comp-J1-001"}' > "${MARKER_J1}"

# Session J2 — FAILED
SESSION_J2="${TMP_HOME_A}/agents/main/sessions/${SID_J2}.jsonl"
cat > "${SESSION_J2}" <<JSONL
{"type":"session","version":3,"id":"${SID_J2}","timestamp":"2026-02-01T11:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-J2-001","parentId":"00000000","timestamp":"2026-02-01T11:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Fix the bug"}]}}
{"type":"message","id":"comp-J2-001","parentId":"user-J2-001","timestamp":"2026-02-01T11:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Bug investigated"}],"usage":{"input":80,"output":40,"cacheRead":0,"cacheWrite":0,"totalTokens":120}}}
JSONL

MARKER_J2="${TMP_HOME_A}/skills/revenium/markers/${SID_J2}.jsonl"
printf '%s\n' '{"kind":"job","ts":"2026-02-01T11:03:00Z","sid":"'"${SID_J2}"'","agentic_job_id":"'"${JOB_ID_J2}"'","job_name":"'"${JOB_NAME_J2}"'","job_type":"'"${JOB_TYPE_J2}"'","status":"FAILED","failure_reason":"'"${FAILURE_REASON_J2}"'","completion_id":"comp-J2-001"}' > "${MARKER_J2}"

# Session J3 — CANCELLED
SESSION_J3="${TMP_HOME_A}/agents/main/sessions/${SID_J3}.jsonl"
cat > "${SESSION_J3}" <<JSONL
{"type":"session","version":3,"id":"${SID_J3}","timestamp":"2026-02-01T12:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-J3-001","parentId":"00000000","timestamp":"2026-02-01T12:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Review the docs"}]}}
{"type":"message","id":"comp-J3-001","parentId":"user-J3-001","timestamp":"2026-02-01T12:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Docs reviewed"}],"usage":{"input":60,"output":30,"cacheRead":0,"cacheWrite":0,"totalTokens":90}}}
JSONL

MARKER_J3="${TMP_HOME_A}/skills/revenium/markers/${SID_J3}.jsonl"
printf '%s\n' '{"kind":"job","ts":"2026-02-01T12:03:00Z","sid":"'"${SID_J3}"'","agentic_job_id":"'"${JOB_ID_J3}"'","job_name":"'"${JOB_NAME_J3}"'","job_type":"'"${JOB_TYPE_J3}"'","status":"CANCELLED","completion_id":"comp-J3-001"}' > "${MARKER_J3}"

# Run report.sh for group A
run_report "${TMP_HOME_A}" "${ARGV_FILE_A}"
JOBS_LEDGER_A="${TMP_HOME_A}/revenium-jobs.ledger"

# ---------------------------------------------------------------------------
# GROUP A assertions
# ---------------------------------------------------------------------------

# --- JLIFE-01: jobs create fires for J1 (exactly one ^create$ token)
create_count_a=$(count_grep "^create$" "${ARGV_FILE_A}")
if [[ "${create_count_a}" -eq 3 ]]; then
  pass "JLIFE-01: exactly 3 ^create$ tokens (one per job)"
else
  fail "JLIFE-01: expected 3 ^create$ tokens, got ${create_count_a} (RED — job wiring not yet in report.sh)"
fi

# --- JLIFE-01/05: J1 job ledger has a :created: entry
if grep -q "^JOB:${JOB_ID_J1}:created:" "${JOBS_LEDGER_A}" 2>/dev/null; then
  pass "JLIFE-01: revenium-jobs.ledger has JOB:${JOB_ID_J1}:created: entry"
else
  fail "JLIFE-01: no JOB:${JOB_ID_J1}:created: in jobs ledger (RED)"
fi

# --- JLIFE-02: correlated completion ships --agentic-job-id for J1
# Note: find(1) returns session files in inode order (not alphabetical), so we
# cannot rely on head -1 to return J1's id first.  Instead check that J1's id
# appears SOMEWHERE in the captured argv (all three sessions are in one home,
# so all three ids must appear; this assertion only checks the J1 presence).
all_stamped_ids=$(awk '/^--agentic-job-id$/{getline; print}' "${ARGV_FILE_A}" 2>/dev/null || true)
if echo "${all_stamped_ids}" | grep -qx "${JOB_ID_J1}"; then
  pass "JLIFE-02: --agentic-job-id ${JOB_ID_J1} found in stamped completion argv"
else
  fail "JLIFE-02: expected --agentic-job-id ${JOB_ID_J1} somewhere in argv, got '$(echo "${all_stamped_ids}" | tr '\n' '|')' (RED)"
fi

# --- JLIFE-02: --agentic-job-name present
if grep -q "^--agentic-job-name$" "${ARGV_FILE_A}" 2>/dev/null; then
  pass "JLIFE-02: --agentic-job-name present in argv"
else
  fail "JLIFE-02: --agentic-job-name NOT present in argv (RED)"
fi

# --- JLIFE-02: --agentic-job-type present
if grep -q "^--agentic-job-type$" "${ARGV_FILE_A}" 2>/dev/null; then
  pass "JLIFE-02: --agentic-job-type present in argv"
else
  fail "JLIFE-02: --agentic-job-type NOT present in argv (RED)"
fi

# --- JLIFE-03: jobs outcome fires for J1 (^outcome$ token)
outcome_count_a=$(count_grep "^outcome$" "${ARGV_FILE_A}")
if [[ "${outcome_count_a}" -eq 3 ]]; then
  pass "JLIFE-03: exactly 3 ^outcome$ tokens (one per job)"
else
  fail "JLIFE-03: expected 3 ^outcome$ tokens, got ${outcome_count_a} (RED)"
fi

# --- JLIFE-03: J1 outcome --result SUCCESS
result_j1=$(awk '/^--result$/{getline; print}' "${ARGV_FILE_A}" 2>/dev/null | grep "^SUCCESS$" | head -1 || true)
if [[ "${result_j1}" == "SUCCESS" ]]; then
  pass "JLIFE-03: --result SUCCESS found for J1"
else
  fail "JLIFE-03: --result SUCCESS NOT found (RED)"
fi

# --- JLIFE-03: J1 SUCCESS has NO --metadata token
# (we check that the metadata count matches only the number of FAILED jobs = 1)
metadata_count_a=$(count_grep "^--metadata$" "${ARGV_FILE_A}")
if [[ "${metadata_count_a}" -eq 1 ]]; then
  pass "JLIFE-03: exactly 1 --metadata token (only for FAILED job J2)"
else
  fail "JLIFE-03: expected 1 --metadata token, got ${metadata_count_a} (RED)"
fi

# --- J1 jobs ledger :outcome: entry
if grep -q "^JOB:${JOB_ID_J1}:outcome:.*:SUCCESS" "${JOBS_LEDGER_A}" 2>/dev/null; then
  pass "JLIFE-03/05: revenium-jobs.ledger has JOB:${JOB_ID_J1}:outcome:...:SUCCESS entry"
else
  fail "JLIFE-03/05: no JOB:${JOB_ID_J1}:outcome:...:SUCCESS in jobs ledger (RED)"
fi

# --- JLIFE-03: J2 outcome --result FAILED
result_j2=$(awk '/^--result$/{getline; print}' "${ARGV_FILE_A}" 2>/dev/null | grep "^FAILED$" | head -1 || true)
if [[ "${result_j2}" == "FAILED" ]]; then
  pass "JLIFE-03 D-08: --result FAILED found for J2"
else
  fail "JLIFE-03 D-08: --result FAILED NOT found (RED)"
fi

# --- D-08: J2 --metadata is present and contains failure_reason (via python3 env-pass, no eval)
metadata_val=$(awk '/^--metadata$/{getline; print}' "${ARGV_FILE_A}" 2>/dev/null | head -1 || true)
if [[ -n "${metadata_val}" ]]; then
  has_failure_reason=$(METADATA_VAL="${metadata_val}" python3 - 2>/dev/null <<'PY'
import json, os, sys
v = os.environ.get('METADATA_VAL', '')
try:
    d = json.loads(v)
    if isinstance(d, dict) and 'failure_reason' in d:
        print('yes')
except Exception:
    pass
PY
)
  if [[ "${has_failure_reason}" == "yes" ]]; then
    pass "D-08: --metadata JSON contains failure_reason key (parsed via env-passing python3, no eval)"
  else
    fail "D-08: --metadata JSON does NOT contain failure_reason key (value='${metadata_val}')"
  fi
else
  fail "D-08: --metadata value is empty (RED)"
fi

# --- JLIFE-03 D-07: J3 outcome --result CANCELLED
result_j3=$(awk '/^--result$/{getline; print}' "${ARGV_FILE_A}" 2>/dev/null | grep "^CANCELLED$" | head -1 || true)
if [[ "${result_j3}" == "CANCELLED" ]]; then
  pass "JLIFE-03 D-07: --result CANCELLED found for J3"
else
  fail "JLIFE-03 D-07: --result CANCELLED NOT found (RED)"
fi

# --- JOUT-01: exactly ONE --outcome-type token, only for the SUCCESS arc (J1),
# and its value is CONVERTED. GROUP A = J1 SUCCESS + J2 FAILED + J3 CANCELLED,
# so FAILED/CANCELLED must contribute zero --outcome-type tokens.
outcome_type_count_a=$(count_grep "^--outcome-type$" "${ARGV_FILE_A}")
if [[ "${outcome_type_count_a}" -eq 1 ]]; then
  pass "JOUT-01: exactly 1 --outcome-type token (SUCCESS arc only)"
else
  fail "JOUT-01: expected 1 --outcome-type token (SUCCESS-only), got ${outcome_type_count_a}"
fi

outcome_type_val_a=$(awk '/^--outcome-type$/{getline; print}' "${ARGV_FILE_A}" 2>/dev/null | head -1 || true)
if [[ "${outcome_type_val_a}" == "CONVERTED" ]]; then
  pass "JOUT-01: --outcome-type value is CONVERTED"
else
  fail "JOUT-01: --outcome-type value expected CONVERTED, got '${outcome_type_val_a}'"
fi

# --- D-04: NO --environment token EVER appears
env_token_count_a=$(count_grep "^--environment$" "${ARGV_FILE_A}")
if [[ "${env_token_count_a}" -eq 0 ]]; then
  pass "D-04: no --environment token in captured argv"
else
  fail "D-04: found ${env_token_count_a} --environment tokens (should be 0)"
fi

# --- J3 CANCELLED has NO --metadata token (only FAILED gets metadata)
# Already asserted above: metadata_count_a == 1 means only J2 FAILED has it.

rm -f "${ARGV_FILE_A}"

# ===========================================================================
# GROUP B: Fail-open (JLIFE-04) — STUB_REVENIUM_NO_JOBS forces probe failure
# ===========================================================================
TMP_HOME_B=$(make_openclaw_home)
ARGV_FILE_B=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-b.XXXXXX")

SID_B1="44444444-dddd-dddd-dddd-dddddddddddd"
JOB_ID_B1="failopen-5gh6"

SESSION_B1="${TMP_HOME_B}/agents/main/sessions/${SID_B1}.jsonl"
cat > "${SESSION_B1}" <<JSONL
{"type":"session","version":3,"id":"${SID_B1}","timestamp":"2026-02-02T10:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-B1-001","parentId":"00000000","timestamp":"2026-02-02T10:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Some work"}]}}
{"type":"message","id":"comp-B1-001","parentId":"user-B1-001","timestamp":"2026-02-02T10:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Work done"}],"usage":{"input":50,"output":25,"cacheRead":0,"cacheWrite":0,"totalTokens":75}}}
JSONL

MARKER_B1="${TMP_HOME_B}/skills/revenium/markers/${SID_B1}.jsonl"
printf '%s\n' '{"kind":"job","ts":"2026-02-02T10:03:00Z","sid":"'"${SID_B1}"'","agentic_job_id":"'"${JOB_ID_B1}"'","job_name":"Fail Open","job_type":"feature_development","status":"SUCCESS","completion_id":"comp-B1-001"}' > "${MARKER_B1}"

# Run with STUB_REVENIUM_NO_JOBS=1 — probe fails → JOBS_CLI_CAPABLE=false
STUB_REVENIUM_NO_JOBS=1 STUB_REVENIUM_ARGV_FILE="${ARGV_FILE_B}" \
  OPENCLAW_HOME="${TMP_HOME_B}" HOME="${TMP_FAKE_HOME}" \
  bash "${REPORT_SH}" 2>&1 || true

# Assert: zero ^create$ tokens (no jobs create call happened)
# Note: the capability probe "revenium jobs --help" always emits 1 ^jobs$ token
# even when it fails (the stub captures all argv before checking env switches).
# Checking for ^create$ = 0 and ^outcome$ = 0 is the reliable signal that no
# actual job work happened (the probe invocation is expected and benign).
create_token_count_b=$(count_grep "^create$" "${ARGV_FILE_B}")
outcome_token_count_b=$(count_grep "^outcome$" "${ARGV_FILE_B}")
if [[ "${create_token_count_b}" -eq 0 && "${outcome_token_count_b}" -eq 0 ]]; then
  pass "JLIFE-04 fail-open: zero ^create$/^outcome$ tokens in argv (JOBS_CLI_CAPABLE=false, no job work)"
else
  fail "JLIFE-04 fail-open: expected 0 ^create$/^outcome$ tokens, got create=${create_token_count_b} outcome=${outcome_token_count_b} (RED)"
fi

# Assert: zero agentic-job tokens
agentic_job_count_b=$(count_grep "agentic-job" "${ARGV_FILE_B}")
if [[ "${agentic_job_count_b}" -eq 0 ]]; then
  pass "JLIFE-04 fail-open: zero agentic-job tokens in argv (v1.0 metering unchanged)"
else
  fail "JLIFE-04 fail-open: expected 0 agentic-job tokens, got ${agentic_job_count_b} (RED)"
fi

# Assert: --task-type still present (v1.0 metering unaffected)
if grep -q "^--task-type$" "${ARGV_FILE_B}" 2>/dev/null; then
  pass "JLIFE-04 fail-open: --task-type still present in argv (v1.0 metering byte-identical)"
else
  fail "JLIFE-04 fail-open: --task-type NOT present in argv (RED)"
fi

# Assert: --agent still present
if grep -q "^--agent$" "${ARGV_FILE_B}" 2>/dev/null; then
  pass "JLIFE-04 fail-open: --agent still present in argv"
else
  fail "JLIFE-04 fail-open: --agent NOT present in argv (RED)"
fi

rm -f "${ARGV_FILE_B}"

# ===========================================================================
# GROUP C: 409-as-success (JLIFE-04 extra / D-06)
#   Run with STUB_REVENIUM_409_FOR = J1 job id on a FRESH OPENCLAW_HOME.
#   Even though jobs create exits non-zero (409), the ledger row must be written
#   and report.sh must exit 0.
# ===========================================================================
TMP_HOME_C=$(make_openclaw_home)
ARGV_FILE_C=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-c.XXXXXX")

# Re-use SID_J1 fixture in a new home
SESSION_C1="${TMP_HOME_C}/agents/main/sessions/${SID_J1}.jsonl"
cat > "${SESSION_C1}" <<JSONL
{"type":"session","version":3,"id":"${SID_J1}","timestamp":"2026-02-01T10:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-J1-001","parentId":"00000000","timestamp":"2026-02-01T10:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Build the feature"}]}}
{"type":"message","id":"comp-J1-001","parentId":"user-J1-001","timestamp":"2026-02-01T10:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Feature implemented"}],"usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150}}}
JSONL

MARKER_C1="${TMP_HOME_C}/skills/revenium/markers/${SID_J1}.jsonl"
printf '%s\n' '{"kind":"job","ts":"2026-02-01T10:03:00Z","sid":"'"${SID_J1}"'","agentic_job_id":"'"${JOB_ID_J1}"'","job_name":"'"${JOB_NAME_J1}"'","job_type":"'"${JOB_TYPE_J1}"'","status":"SUCCESS","completion_id":"comp-J1-001"}' > "${MARKER_C1}"

# Run with 409 stub for J1
STUB_REVENIUM_409_FOR="${JOB_ID_J1}" STUB_REVENIUM_ARGV_FILE="${ARGV_FILE_C}" \
  OPENCLAW_HOME="${TMP_HOME_C}" HOME="${TMP_FAKE_HOME}" \
  bash "${REPORT_SH}" 2>&1 || true

JOBS_LEDGER_C="${TMP_HOME_C}/revenium-jobs.ledger"

# Assert: :created: row still written (409 is success)
if grep -q "^JOB:${JOB_ID_J1}:created:" "${JOBS_LEDGER_C}" 2>/dev/null; then
  pass "D-06 409-as-success: JOB:${JOB_ID_J1}:created: ledger row written despite 409 stub (RED — wiring not yet in report.sh)"
else
  fail "D-06 409-as-success: JOB:${JOB_ID_J1}:created: ledger row NOT written (RED — expected failure)"
fi

rm -f "${ARGV_FILE_C}"

# ===========================================================================
# GROUP D: CR-02 / D-12 decoupling (JLIFE-04 extra — REQUIRED, VALIDATION.md L48)
#   STUB_REVENIUM_JOBS_FAIL=1: jobs create/outcome exit non-409 error;
#   meter completion still succeeds.
#   Fresh OPENCLAW_HOME, empty offsets, empty ledgers.
#   Assert:
#     (a) TX:<comp_id> written exactly once in revenium-reported.ledger
#     (b) offset advanced — second run does NOT re-meter the completion
#     (c) report.sh exits 0 on the jobs-failing run
#     (d) no JOB:<id>: row in revenium-jobs.ledger
# ===========================================================================
TMP_HOME_D=$(make_openclaw_home)
ARGV_FILE_D1=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-d1.XXXXXX")

SID_D1="55555555-eeee-eeee-eeee-eeeeeeeeeeee"
JOB_ID_D1="decoupling-7ij8"

SESSION_D1="${TMP_HOME_D}/agents/main/sessions/${SID_D1}.jsonl"
cat > "${SESSION_D1}" <<JSONL
{"type":"session","version":3,"id":"${SID_D1}","timestamp":"2026-02-03T10:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-D1-001","parentId":"00000000","timestamp":"2026-02-03T10:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Decouple jobs from metering"}]}}
{"type":"message","id":"comp-D1-001","parentId":"user-D1-001","timestamp":"2026-02-03T10:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Decoupled"}],"usage":{"input":70,"output":35,"cacheRead":0,"cacheWrite":0,"totalTokens":105}}}
JSONL

MARKER_D1="${TMP_HOME_D}/skills/revenium/markers/${SID_D1}.jsonl"
printf '%s\n' '{"kind":"job","ts":"2026-02-03T10:03:00Z","sid":"'"${SID_D1}"'","agentic_job_id":"'"${JOB_ID_D1}"'","job_name":"Decouple","job_type":"feature_development","status":"SUCCESS","completion_id":"comp-D1-001"}' > "${MARKER_D1}"

# First run with STUB_REVENIUM_JOBS_FAIL=1 — jobs CLI fails, meter completion succeeds
report_rc_d=0
STUB_REVENIUM_JOBS_FAIL=1 STUB_REVENIUM_ARGV_FILE="${ARGV_FILE_D1}" \
  OPENCLAW_HOME="${TMP_HOME_D}" HOME="${TMP_FAKE_HOME}" \
  bash "${REPORT_SH}" 2>&1 || report_rc_d=$?

COMPLETION_LEDGER_D="${TMP_HOME_D}/revenium-reported.ledger"
JOBS_LEDGER_D="${TMP_HOME_D}/revenium-jobs.ledger"

# (a) TX:comp-D1-001 written exactly once
tx_count_d=$(count_grep "^TX:comp-D1-001$" "${COMPLETION_LEDGER_D}")
if [[ "${tx_count_d}" -eq 1 ]]; then
  pass "CR-02/D-12 (a): TX:comp-D1-001 written exactly once in revenium-reported.ledger"
else
  fail "CR-02/D-12 (a): expected TX:comp-D1-001 count=1, got ${tx_count_d} (RED)"
fi

# (c) report.sh exits 0 on the jobs-failing run (best-effort)
if [[ "${report_rc_d}" -eq 0 ]]; then
  pass "CR-02/D-12 (c): report.sh exits 0 even when jobs CLI fails (best-effort)"
else
  fail "CR-02/D-12 (c): report.sh exited ${report_rc_d} (should be 0 — jobs failure must not abort)"
fi

# (d) No JOB:<id>: row in revenium-jobs.ledger (jobs failure stayed in warn path)
job_row_count_d=$(count_grep "^JOB:${JOB_ID_D1}:" "${JOBS_LEDGER_D}")
if [[ "${job_row_count_d}" -eq 0 ]]; then
  pass "CR-02/D-12 (d): no JOB:${JOB_ID_D1}: row in jobs ledger (failure stayed in warn-and-continue)"
else
  fail "CR-02/D-12 (d): found ${job_row_count_d} JOB:${JOB_ID_D1}: rows (should be 0 on failure — RED)"
fi

# (b) Second run — offset should be advanced, no re-metering of comp-D1-001
ARGV_FILE_D2=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-d2.XXXXXX")
STUB_REVENIUM_JOBS_FAIL=1 STUB_REVENIUM_ARGV_FILE="${ARGV_FILE_D2}" \
  OPENCLAW_HOME="${TMP_HOME_D}" HOME="${TMP_FAKE_HOME}" \
  bash "${REPORT_SH}" 2>&1 || true

# The second run must NOT re-meter comp-D1-001 (TX: already in ledger + offset advanced).
# The capability probe "revenium meter completion --help" emits a ^completion$ token even
# when no real metering happens, so we check for ^--transaction-id$ instead — that flag
# only appears in real "meter completion" posts (not in the --help probe).
tx_flag_count_d2=$(count_grep "^--transaction-id$" "${ARGV_FILE_D2}")
if [[ "${tx_flag_count_d2}" -eq 0 ]]; then
  pass "CR-02/D-12 (b): second run does NOT re-meter comp-D1-001 (offset advanced, no --transaction-id in argv)"
else
  fail "CR-02/D-12 (b): second run has ${tx_flag_count_d2} ^--transaction-id$ flag(s) — re-metering occurred (RED)"
fi

# Also verify TX: count is still exactly 1 after the second run
tx_count_d2=$(count_grep "^TX:comp-D1-001$" "${COMPLETION_LEDGER_D}")
if [[ "${tx_count_d2}" -eq 1 ]]; then
  pass "CR-02/D-12 (b) ledger: TX:comp-D1-001 still exactly 1 after second run"
else
  fail "CR-02/D-12 (b) ledger: TX:comp-D1-001 count=${tx_count_d2} after second run (expected 1)"
fi

rm -f "${ARGV_FILE_D1}" "${ARGV_FILE_D2}"

# ===========================================================================
# GROUP E: Idempotency / re-run (JLIFE-01/05)
#   Run report.sh TWICE against the same OPENCLAW_HOME (no reset between runs).
#   Assert across BOTH runs combined: exactly one ^create$ and one ^outcome$
#   token per job, and the jobs ledger has exactly one :created: and one
#   :outcome: line per job id.
# ===========================================================================
TMP_HOME_E=$(make_openclaw_home)
ARGV_FILE_E1=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-e1.XXXXXX")
ARGV_FILE_E2=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-e2.XXXXXX")

SID_E1="66666666-ffff-ffff-ffff-ffffffffffff"
JOB_ID_E1="idempotent-9kl0"

SESSION_E1="${TMP_HOME_E}/agents/main/sessions/${SID_E1}.jsonl"
cat > "${SESSION_E1}" <<JSONL
{"type":"session","version":3,"id":"${SID_E1}","timestamp":"2026-02-04T10:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-E1-001","parentId":"00000000","timestamp":"2026-02-04T10:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Idempotent work"}]}}
{"type":"message","id":"comp-E1-001","parentId":"user-E1-001","timestamp":"2026-02-04T10:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Done"}],"usage":{"input":50,"output":25,"cacheRead":0,"cacheWrite":0,"totalTokens":75}}}
JSONL

MARKER_E1="${TMP_HOME_E}/skills/revenium/markers/${SID_E1}.jsonl"
printf '%s\n' '{"kind":"job","ts":"2026-02-04T10:03:00Z","sid":"'"${SID_E1}"'","agentic_job_id":"'"${JOB_ID_E1}"'","job_name":"Idempotent","job_type":"feature_development","status":"SUCCESS","completion_id":"comp-E1-001"}' > "${MARKER_E1}"

# First run
run_report "${TMP_HOME_E}" "${ARGV_FILE_E1}"
# Second run (same OPENCLAW_HOME — no reset of offsets/ledgers)
run_report "${TMP_HOME_E}" "${ARGV_FILE_E2}"

JOBS_LEDGER_E="${TMP_HOME_E}/revenium-jobs.ledger"

# Merge both argv files for cross-run token counts
ARGV_FILE_E_MERGED=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-e-merged.XXXXXX")
cat "${ARGV_FILE_E1}" "${ARGV_FILE_E2}" > "${ARGV_FILE_E_MERGED}"

# Exactly one ^create$ across both runs
create_count_e=$(count_grep "^create$" "${ARGV_FILE_E_MERGED}")
if [[ "${create_count_e}" -eq 1 ]]; then
  pass "JLIFE-05: exactly 1 ^create$ token across two runs (idempotent — ledger gate worked)"
else
  fail "JLIFE-05: expected 1 ^create$ across two runs, got ${create_count_e} (RED)"
fi

# Exactly one ^outcome$ across both runs
outcome_count_e=$(count_grep "^outcome$" "${ARGV_FILE_E_MERGED}")
if [[ "${outcome_count_e}" -eq 1 ]]; then
  pass "JLIFE-05: exactly 1 ^outcome$ token across two runs (idempotent)"
else
  fail "JLIFE-05: expected 1 ^outcome$ across two runs, got ${outcome_count_e} (RED)"
fi

# Exactly one :created: line in jobs ledger
created_ledger_count_e=$(count_grep "^JOB:${JOB_ID_E1}:created:" "${JOBS_LEDGER_E}")
if [[ "${created_ledger_count_e}" -eq 1 ]]; then
  pass "JLIFE-05: exactly 1 JOB:${JOB_ID_E1}:created: line in jobs ledger"
else
  fail "JLIFE-05: expected 1 :created: ledger line, got ${created_ledger_count_e} (RED)"
fi

# Exactly one :outcome: line in jobs ledger
outcome_ledger_count_e=$(count_grep "^JOB:${JOB_ID_E1}:outcome:" "${JOBS_LEDGER_E}")
if [[ "${outcome_ledger_count_e}" -eq 1 ]]; then
  pass "JLIFE-05: exactly 1 JOB:${JOB_ID_E1}:outcome: line in jobs ledger"
else
  fail "JLIFE-05: expected 1 :outcome: ledger line, got ${outcome_ledger_count_e} (RED)"
fi

rm -f "${ARGV_FILE_E1}" "${ARGV_FILE_E2}" "${ARGV_FILE_E_MERGED}"

# ===========================================================================
# GROUP F: Subagent inherits root's agentic_job_id (JROLL-01)
#   ROOT session has a sessions_spawn link to CHILD session.
#   ROOT marker declares a job (root-job-1a2b).
#   CHILD marker has its OWN job id (child-job-9z9z) — proves it is NOT shipped.
#   After report.sh runs:
#     - child's completion ships --agentic-job-id == root-job-1a2b (inherited)
#     - child's own id (child-job-9z9z) never appears in argv
#     - exactly one ^create$ token (root only — child must NOT create)
#     - one JOB:root-job-1a2b:created: line in jobs ledger
# ===========================================================================
ROOT_UUID_F="f0000000-aaaa-aaaa-aaaa-000000000001"
CHILD_UUID_F="f0000000-cccc-cccc-cccc-000000000002"
JOB_ID_ROOT_F="root-job-1a2b"
JOB_NAME_ROOT_F="Root Job"
JOB_TYPE_ROOT_F="feature_development"

TMP_HOME_F=$(make_openclaw_home)
ARGV_FILE_F=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-f.XXXXXX")

# Root session JSONL with sessions_spawn tool result — required so
# get-root-session-id.py resolves CHILD_UUID_F -> ROOT_UUID_F.
# toolName must be literally "sessions_spawn"; details.childSessionKey must use
# "agent:main:subagent:<UUID>" prefix (resolver strips prefix via rsplit(":", 1)[-1]).
cat > "${TMP_HOME_F}/agents/main/sessions/${ROOT_UUID_F}.jsonl" <<JSONL
{"type":"session","version":3,"id":"${ROOT_UUID_F}","timestamp":"2026-03-01T10:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"spawn-msg-f1","parentId":"00000000","timestamp":"2026-03-01T10:01:00.000Z","message":{"role":"toolResult","toolName":"sessions_spawn","content":[{"type":"text","text":"{}"}],"details":{"status":"accepted","childSessionKey":"agent:main:subagent:${CHILD_UUID_F}","runId":"run-f001"}}}
{"type":"message","id":"comp-root-f001","parentId":"spawn-msg-f1","timestamp":"2026-03-01T10:04:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Root work done"}],"usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150}}}
JSONL

# Child session JSONL with one assistant completion
cat > "${TMP_HOME_F}/agents/main/sessions/${CHILD_UUID_F}.jsonl" <<JSONL
{"type":"session","version":3,"id":"${CHILD_UUID_F}","timestamp":"2026-03-01T10:02:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-child-f1","parentId":"00000000","timestamp":"2026-03-01T10:02:30.000Z","message":{"role":"user","content":[{"type":"text","text":"Subagent task"}]}}
{"type":"message","id":"comp-child-f001","parentId":"user-child-f1","timestamp":"2026-03-01T10:03:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Subagent work done"}],"usage":{"input":80,"output":40,"cacheRead":0,"cacheWrite":0,"totalTokens":120}}}
JSONL

# Root job marker — root declares its job (enable JROLL-01 inherit path)
printf '%s\n' '{"kind":"job","ts":"2026-03-01T10:05:00Z","sid":"'"${ROOT_UUID_F}"'","agentic_job_id":"'"${JOB_ID_ROOT_F}"'","job_name":"'"${JOB_NAME_ROOT_F}"'","job_type":"'"${JOB_TYPE_ROOT_F}"'","status":"SUCCESS","completion_id":"comp-root-f001"}' \
  > "${TMP_HOME_F}/skills/revenium/markers/${ROOT_UUID_F}.jsonl"

# Child marker with a DIFFERENT job id — proves it is NOT shipped (JROLL-01 / D-04)
printf '%s\n' '{"kind":"job","ts":"2026-03-01T10:03:30Z","sid":"'"${CHILD_UUID_F}"'","agentic_job_id":"child-job-9z9z","job_name":"Child Own Job","job_type":"bug_fix","status":"SUCCESS","completion_id":"comp-child-f001"}' \
  > "${TMP_HOME_F}/skills/revenium/markers/${CHILD_UUID_F}.jsonl"

# Run report.sh for GROUP F
run_report "${TMP_HOME_F}" "${ARGV_FILE_F}"
JOBS_LEDGER_F="${TMP_HOME_F}/revenium-jobs.ledger"

# ---------------------------------------------------------------------------
# GROUP F assertions
# ---------------------------------------------------------------------------

# JROLL-01 F: child's completion ships the ROOT's agentic_job_id, not child's own
all_stamped_ids_f=$(awk '/^--agentic-job-id$/{getline; print}' "${ARGV_FILE_F}" 2>/dev/null || true)
if echo "${all_stamped_ids_f}" | grep -qx "${JOB_ID_ROOT_F}"; then
  pass "JROLL-01 F: --agentic-job-id ${JOB_ID_ROOT_F} found in argv (root's id inherited by child)"
else
  fail "JROLL-01 F: expected --agentic-job-id ${JOB_ID_ROOT_F}, got '$(echo "${all_stamped_ids_f}" | tr '\n' '|')' (RED — rollup not yet in report.sh)"
fi

# JROLL-01 F: child's own id must NOT appear as a stamped agentic_job_id
if echo "${all_stamped_ids_f}" | grep -qx "child-job-9z9z"; then
  fail "JROLL-01 F: child's own id 'child-job-9z9z' leaked into --agentic-job-id (must NOT happen)"
else
  pass "JROLL-01 F: child's own id 'child-job-9z9z' NOT in stamped --agentic-job-id (correct)"
fi

# JROLL-01 F: --agentic-job-name value is the root's job name
all_stamped_names_f=$(awk '/^--agentic-job-name$/{getline; print}' "${ARGV_FILE_F}" 2>/dev/null || true)
if echo "${all_stamped_names_f}" | grep -qx "${JOB_NAME_ROOT_F}"; then
  pass "JROLL-01 F: --agentic-job-name '${JOB_NAME_ROOT_F}' found (root's name inherited)"
else
  fail "JROLL-01 F: expected --agentic-job-name '${JOB_NAME_ROOT_F}', got '$(echo "${all_stamped_names_f}" | tr '\n' '|')' (RED)"
fi

# JROLL-01 F: --agentic-job-type value is the root's job type
all_stamped_types_f=$(awk '/^--agentic-job-type$/{getline; print}' "${ARGV_FILE_F}" 2>/dev/null || true)
if echo "${all_stamped_types_f}" | grep -qx "${JOB_TYPE_ROOT_F}"; then
  pass "JROLL-01 F: --agentic-job-type '${JOB_TYPE_ROOT_F}' found (root's type inherited)"
else
  fail "JROLL-01 F: expected --agentic-job-type '${JOB_TYPE_ROOT_F}', got '$(echo "${all_stamped_types_f}" | tr '\n' '|')' (RED)"
fi

# JROLL-01 F: exactly 1 ^create$ token (only root creates — child must NOT create)
create_count_f=$(count_grep "^create$" "${ARGV_FILE_F}")
if [[ "${create_count_f}" -eq 1 ]]; then
  pass "JROLL-01 F: exactly 1 ^create$ token (root creates once; child skips create)"
else
  fail "JROLL-01 F: expected 1 ^create$ token, got ${create_count_f} (RED)"
fi

# JROLL-01 F: jobs ledger has exactly one JOB:root-job-1a2b:created: line
created_count_f=$(count_grep "^JOB:${JOB_ID_ROOT_F}:created:" "${JOBS_LEDGER_F}")
if [[ "${created_count_f}" -eq 1 ]]; then
  pass "JROLL-01 F: exactly 1 JOB:${JOB_ID_ROOT_F}:created: in jobs ledger"
else
  fail "JROLL-01 F: expected 1 JOB:${JOB_ID_ROOT_F}:created: ledger row, got ${created_count_f} (RED)"
fi

rm -f "${ARGV_FILE_F}"

# ===========================================================================
# GROUP G: Race window / orphan-drop — root has NO job marker yet (JROLL-02 / D-07)
#   ROOT session has a sessions_spawn link to CHILD session.
#   NO root job marker written (root has not declared its job — the race).
#   CHILD has its OWN orphan job marker (orphan-job-7x7x) — proves it is NOT shipped.
#   After report.sh runs:
#     - NO --agentic-job-id in argv (race → omit entirely)
#     - --agent IS present (v1.0 rollup still works)
#     - --task-type IS present (metering byte-identical)
#     - 0 ^create$ tokens (no job created)
#     - 0 ^outcome$ tokens (no job outcome)
#     - completion IS reported (a TX: line exists in revenium-reported.ledger)
# ===========================================================================
ROOT_UUID_G="g0000000-aaaa-aaaa-aaaa-000000000001"
CHILD_UUID_G="g0000000-cccc-cccc-cccc-000000000002"

TMP_HOME_G=$(make_openclaw_home)
ARGV_FILE_G=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-g.XXXXXX")

# Root session JSONL with sessions_spawn link — resolver needs this to identify CHILD as subagent
cat > "${TMP_HOME_G}/agents/main/sessions/${ROOT_UUID_G}.jsonl" <<JSONL
{"type":"session","version":3,"id":"${ROOT_UUID_G}","timestamp":"2026-03-02T10:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"spawn-msg-g1","parentId":"00000000","timestamp":"2026-03-02T10:01:00.000Z","message":{"role":"toolResult","toolName":"sessions_spawn","content":[{"type":"text","text":"{}"}],"details":{"status":"accepted","childSessionKey":"agent:main:subagent:${CHILD_UUID_G}","runId":"run-g001"}}}
JSONL

# Child session JSONL with one assistant completion
cat > "${TMP_HOME_G}/agents/main/sessions/${CHILD_UUID_G}.jsonl" <<JSONL
{"type":"session","version":3,"id":"${CHILD_UUID_G}","timestamp":"2026-03-02T10:02:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-child-g1","parentId":"00000000","timestamp":"2026-03-02T10:02:30.000Z","message":{"role":"user","content":[{"type":"text","text":"Subagent task"}]}}
{"type":"message","id":"comp-child-g001","parentId":"user-child-g1","timestamp":"2026-03-02T10:03:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Subagent work done"}],"usage":{"input":80,"output":40,"cacheRead":0,"cacheWrite":0,"totalTokens":120}}}
JSONL

# NO root job marker — root has NOT declared a job yet (race window)
# Child has its OWN orphan marker — proves the orphan id is dropped, not shipped (D-04/D-07)
printf '%s\n' '{"kind":"job","ts":"2026-03-02T10:03:30Z","sid":"'"${CHILD_UUID_G}"'","agentic_job_id":"orphan-job-7x7x","job_name":"Orphan Job","job_type":"bug_fix","status":"SUCCESS","completion_id":"comp-child-g001"}' \
  > "${TMP_HOME_G}/skills/revenium/markers/${CHILD_UUID_G}.jsonl"

# Run report.sh for GROUP G
run_report "${TMP_HOME_G}" "${ARGV_FILE_G}"
COMPLETION_LEDGER_G="${TMP_HOME_G}/revenium-reported.ledger"

# ---------------------------------------------------------------------------
# GROUP G assertions
# ---------------------------------------------------------------------------

# JROLL-02 G: NO --agentic-job-id in argv (race → omit entirely; orphan id never leaks)
job_id_count_g=$(count_grep "^--agentic-job-id$" "${ARGV_FILE_G}")
if [[ "${job_id_count_g}" -eq 0 ]]; then
  pass "JROLL-02 G: zero --agentic-job-id tokens (race → omit; orphan id not leaked)"
else
  fail "JROLL-02 G: expected 0 --agentic-job-id tokens, got ${job_id_count_g} (RED — orphan id must never ship)"
fi

# JROLL-02 G: --agent IS present (v1.0 openclaw- attribution still works)
if grep -q "^--agent$" "${ARGV_FILE_G}" 2>/dev/null; then
  pass "JROLL-02 G: --agent present in argv (v1.0 rollup unaffected)"
else
  fail "JROLL-02 G: --agent NOT present in argv (RED — v1.0 metering must not break)"
fi

# JROLL-02 G: --task-type IS present (metering byte-identical)
if grep -q "^--task-type$" "${ARGV_FILE_G}" 2>/dev/null; then
  pass "JROLL-02 G: --task-type present in argv (metering byte-identical)"
else
  fail "JROLL-02 G: --task-type NOT present in argv (RED)"
fi

# JROLL-02 G: 0 ^create$ tokens (no job created in race scenario)
create_count_g=$(count_grep "^create$" "${ARGV_FILE_G}")
if [[ "${create_count_g}" -eq 0 ]]; then
  pass "JROLL-02 G: 0 ^create$ tokens (no job create in race/orphan scenario)"
else
  fail "JROLL-02 G: expected 0 ^create$ tokens, got ${create_count_g} (RED)"
fi

# JROLL-02 G: 0 ^outcome$ tokens (no job outcome in race scenario)
outcome_count_g=$(count_grep "^outcome$" "${ARGV_FILE_G}")
if [[ "${outcome_count_g}" -eq 0 ]]; then
  pass "JROLL-02 G: 0 ^outcome$ tokens (no job outcome in race/orphan scenario)"
else
  fail "JROLL-02 G: expected 0 ^outcome$ tokens, got ${outcome_count_g} (RED)"
fi

# JROLL-02 G (D-07): completion IS still reported (TX: line exists in revenium-reported.ledger)
tx_count_g=$(count_grep "^TX:comp-child-g001$" "${COMPLETION_LEDGER_G}")
if [[ "${tx_count_g}" -ge 1 ]]; then
  pass "JROLL-02 G (D-07): completion comp-child-g001 IS reported (TX: ledger line exists)"
else
  fail "JROLL-02 G (D-07): comp-child-g001 NOT in revenium-reported.ledger (RED — spend must still ship)"
fi

rm -f "${ARGV_FILE_G}"

# ===========================================================================
# GROUP H: Subagent job markers suppressed; root still creates once (JROLL-03)
#   ROOT session with sessions_spawn link to CHILD; BOTH have completions.
#   ROOT marker declares job root-job-5e6f (enables JROLL-01 inherit path).
#   CHILD marker has its OWN job id sub-job-3c4d — proves subagent-own-job
#   marker is suppressed (JROLL-03): no JOB:sub-job-3c4d: ledger rows.
#   After report.sh runs:
#     - 0 JOB:sub-job-3c4d: lines in jobs ledger (subagent own job suppressed)
#     - 1 JOB:root-job-5e6f:created: line in jobs ledger (root creates once)
#     - child completion ships --agentic-job-id == root-job-5e6f (JROLL-01)
#     - --agentic-job-id never resolves to sub-job-3c4d
# ===========================================================================
ROOT_UUID_H="h0000000-aaaa-aaaa-aaaa-000000000001"
CHILD_UUID_H="h0000000-cccc-cccc-cccc-000000000002"
JOB_ID_ROOT_H="root-job-5e6f"
JOB_NAME_ROOT_H="Root H Job"
JOB_TYPE_ROOT_H="bug_fix"
SUB_JOB_ID_H="sub-job-3c4d"

TMP_HOME_H=$(make_openclaw_home)
ARGV_FILE_H=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-h.XXXXXX")

# Root session JSONL with sessions_spawn link AND a root completion
cat > "${TMP_HOME_H}/agents/main/sessions/${ROOT_UUID_H}.jsonl" <<JSONL
{"type":"session","version":3,"id":"${ROOT_UUID_H}","timestamp":"2026-03-03T10:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"spawn-msg-h1","parentId":"00000000","timestamp":"2026-03-03T10:01:00.000Z","message":{"role":"toolResult","toolName":"sessions_spawn","content":[{"type":"text","text":"{}"}],"details":{"status":"accepted","childSessionKey":"agent:main:subagent:${CHILD_UUID_H}","runId":"run-h001"}}}
{"type":"message","id":"comp-root-h001","parentId":"spawn-msg-h1","timestamp":"2026-03-03T10:04:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Root work done"}],"usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150}}}
JSONL

# Child session JSONL with one assistant completion
cat > "${TMP_HOME_H}/agents/main/sessions/${CHILD_UUID_H}.jsonl" <<JSONL
{"type":"session","version":3,"id":"${CHILD_UUID_H}","timestamp":"2026-03-03T10:02:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-child-h1","parentId":"00000000","timestamp":"2026-03-03T10:02:30.000Z","message":{"role":"user","content":[{"type":"text","text":"Subagent task"}]}}
{"type":"message","id":"comp-child-h001","parentId":"user-child-h1","timestamp":"2026-03-03T10:03:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Subagent work done"}],"usage":{"input":80,"output":40,"cacheRead":0,"cacheWrite":0,"totalTokens":120}}}
JSONL

# Root job marker — root declares its job (enables JROLL-01 inherit path)
printf '%s\n' '{"kind":"job","ts":"2026-03-03T10:05:00Z","sid":"'"${ROOT_UUID_H}"'","agentic_job_id":"'"${JOB_ID_ROOT_H}"'","job_name":"'"${JOB_NAME_ROOT_H}"'","job_type":"'"${JOB_TYPE_ROOT_H}"'","status":"SUCCESS","completion_id":"comp-root-h001"}' \
  > "${TMP_HOME_H}/skills/revenium/markers/${ROOT_UUID_H}.jsonl"

# Child marker with the subagent's OWN job id — must be suppressed (JROLL-03)
printf '%s\n' '{"kind":"job","ts":"2026-03-03T10:03:30Z","sid":"'"${CHILD_UUID_H}"'","agentic_job_id":"'"${SUB_JOB_ID_H}"'","job_name":"Subagent Own Job","job_type":"feature_development","status":"SUCCESS","completion_id":"comp-child-h001"}' \
  > "${TMP_HOME_H}/skills/revenium/markers/${CHILD_UUID_H}.jsonl"

# Run report.sh for GROUP H
run_report "${TMP_HOME_H}" "${ARGV_FILE_H}"
JOBS_LEDGER_H="${TMP_HOME_H}/revenium-jobs.ledger"

# ---------------------------------------------------------------------------
# GROUP H assertions
# ---------------------------------------------------------------------------

# JROLL-03 H: 0 JOB:sub-job-3c4d: lines in jobs ledger (subagent own job suppressed)
sub_job_ledger_count_h=$(count_grep "^JOB:${SUB_JOB_ID_H}:" "${JOBS_LEDGER_H}")
if [[ "${sub_job_ledger_count_h}" -eq 0 ]]; then
  pass "JROLL-03 H: 0 JOB:${SUB_JOB_ID_H}: rows in jobs ledger (subagent's own job suppressed)"
else
  fail "JROLL-03 H: found ${sub_job_ledger_count_h} JOB:${SUB_JOB_ID_H}: rows (must be 0 — suppression failed)"
fi

# JROLL-03 H: exactly 1 JOB:root-job-5e6f:created: line in jobs ledger (root creates once)
root_created_count_h=$(count_grep "^JOB:${JOB_ID_ROOT_H}:created:" "${JOBS_LEDGER_H}")
if [[ "${root_created_count_h}" -eq 1 ]]; then
  pass "JROLL-03 H: exactly 1 JOB:${JOB_ID_ROOT_H}:created: in jobs ledger (root creates once)"
else
  fail "JROLL-03 H: expected 1 JOB:${JOB_ID_ROOT_H}:created: ledger row, got ${root_created_count_h} (RED)"
fi

# JROLL-03 H (+ JROLL-01): child's completion ships the ROOT's agentic_job_id (not sub-job-3c4d)
all_stamped_ids_h=$(awk '/^--agentic-job-id$/{getline; print}' "${ARGV_FILE_H}" 2>/dev/null || true)
if echo "${all_stamped_ids_h}" | grep -qx "${JOB_ID_ROOT_H}"; then
  pass "JROLL-03 H: child completion ships --agentic-job-id ${JOB_ID_ROOT_H} (root id inherited)"
else
  fail "JROLL-03 H: expected child completion --agentic-job-id ${JOB_ID_ROOT_H}, got '$(echo "${all_stamped_ids_h}" | tr '\n' '|')' (RED)"
fi

# JROLL-03 H: --agentic-job-id never resolves to sub-job-3c4d
if echo "${all_stamped_ids_h}" | grep -qx "${SUB_JOB_ID_H}"; then
  fail "JROLL-03 H: subagent's own id '${SUB_JOB_ID_H}' leaked into --agentic-job-id (must NEVER happen)"
else
  pass "JROLL-03 H: subagent's own id '${SUB_JOB_ID_H}' NOT in stamped --agentic-job-id (correct)"
fi

rm -f "${ARGV_FILE_H}"

# ===========================================================================
# Phase 8 halt-handler fixture helper
# ---------------------------------------------------------------------------
# write_halt_fixture <openclaw_home> <halted_at>
#   Writes a halted guardrail-status.json into the given OPENCLAW_HOME.
#   JSON is built via printf/quoting only — no eval (T-08-01).
# ---------------------------------------------------------------------------
write_halt_fixture() {
  local home="$1"
  local halted_at="$2"
  printf '%s\n' \
    '{"halted":true,"haltedAt":"'"${halted_at}"'","autonomousMode":true,"haltedRule":{"name":"token-budget","ruleId":"test-rule-id","metricType":"TOKEN","windowType":"ROLLING","currentValue":1000,"hardLimit":500}}' \
    > "${home}/skills/revenium/guardrail-status.json"
}

# ===========================================================================
# GROUP I: JHALT-01 / D-04 — single open real job -> CANCELLED
#   Pre-seed ledger with one open job (add-auth-9f3c:created).
#   Write halted guardrail-status.json fixture.
#   Assert:
#     - argv contains exactly 1 `outcome add-auth-9f3c` + `CANCELLED` pair
#     - ledger gains exactly 1 JOB:add-auth-9f3c:outcome:.*:CANCELLED line
#     - NO guardrail-halt- token appears (open-count was 1, no synthetic)
#     - exactly 1 JOB:halt:<haltedAt> line appended
# ===========================================================================
TMP_HOME_I=$(make_openclaw_home)
ARGV_FILE_I=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-i.XXXXXX")

HALTED_AT_I="2026-06-03T10:00:00.000Z"
OPEN_JOB_ID_I="add-auth-9f3c"

SID_I1="aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa"
SESSION_I1="${TMP_HOME_I}/agents/main/sessions/${SID_I1}.jsonl"
cat > "${SESSION_I1}" <<JSONL
{"type":"session","version":3,"id":"${SID_I1}","timestamp":"2026-06-01T09:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-I1-001","parentId":"00000000","timestamp":"2026-06-01T09:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Add auth"}]}}
{"type":"message","id":"comp-I1-001","parentId":"user-I1-001","timestamp":"2026-06-01T09:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Auth added"}],"usage":{"input":60,"output":30,"cacheRead":0,"cacheWrite":0,"totalTokens":90}}}
JSONL

# Pre-seed the jobs ledger with the open job (created, no outcome)
printf '%s\n' "JOB:${OPEN_JOB_ID_I}:created:1700000000.000" \
  >> "${TMP_HOME_I}/revenium-jobs.ledger"

# Write the halt fixture
write_halt_fixture "${TMP_HOME_I}" "${HALTED_AT_I}"

# Run report.sh
run_report "${TMP_HOME_I}" "${ARGV_FILE_I}"
JOBS_LEDGER_I="${TMP_HOME_I}/revenium-jobs.ledger"

# ---------------------------------------------------------------------------
# GROUP I assertions
# ---------------------------------------------------------------------------

# JHALT-01: argv contains add-auth-9f3c token (outcome call for the open job)
if grep -q "^${OPEN_JOB_ID_I}$" "${ARGV_FILE_I}" 2>/dev/null; then
  pass "GROUP I JHALT-01: ${OPEN_JOB_ID_I} token present in argv (halt CANCELLED close)"
else
  fail "GROUP I JHALT-01: ${OPEN_JOB_ID_I} token NOT in argv (RED — halt handler not in report.sh)"
fi

# JHALT-01: argv contains CANCELLED result token (halt drove the outcome)
if grep -q "^CANCELLED$" "${ARGV_FILE_I}" 2>/dev/null; then
  pass "GROUP I JHALT-01: CANCELLED token present in argv (halt-driven close)"
else
  fail "GROUP I JHALT-01: CANCELLED token NOT in argv (RED)"
fi

# JHALT-01: ledger gains a JOB:add-auth-9f3c:outcome:.*:CANCELLED line
if grep -q "^JOB:${OPEN_JOB_ID_I}:outcome:.*:CANCELLED$" "${JOBS_LEDGER_I}" 2>/dev/null; then
  pass "GROUP I JHALT-01: JOB:${OPEN_JOB_ID_I}:outcome:.*:CANCELLED in jobs ledger"
else
  fail "GROUP I JHALT-01: no JOB:${OPEN_JOB_ID_I}:outcome:.*:CANCELLED in jobs ledger (RED)"
fi

# D-08: NO guardrail-halt- synthetic token (open-count was 1, no synthetic)
if grep -q "guardrail-halt-" "${ARGV_FILE_I}" 2>/dev/null; then
  fail "GROUP I D-08: guardrail-halt- token found in argv (must NOT appear when open job exists)"
else
  pass "GROUP I D-08: no guardrail-halt- token in argv (correct — real job was open)"
fi

# D-03: exactly one JOB:halt:<haltedAt> line appended
halt_gate_count_i=$(count_grep "^JOB:halt:${HALTED_AT_I}$" "${JOBS_LEDGER_I}")
if [[ "${halt_gate_count_i}" -eq 1 ]]; then
  pass "GROUP I D-03: exactly 1 JOB:halt:${HALTED_AT_I} line in jobs ledger"
else
  fail "GROUP I D-03: expected 1 JOB:halt:${HALTED_AT_I} line, got ${halt_gate_count_i} (RED)"
fi

rm -f "${ARGV_FILE_I}"

# ===========================================================================
# GROUP J: JHALT-02 / D-05 / D-09 — zero open jobs -> synthetic interrupted job
#   Empty/no-open ledger; haltedAt chosen so test can predict synthetic id.
#   Compute expected hex in-test via env-passing python3 sha1 (not hard-coded).
#   Assert:
#     - argv contains jobs create --agentic-job-id guardrail-halt-<hex> --type interrupted
#     - argv contains jobs outcome guardrail-halt-<hex> --result CANCELLED
#     - ledger gains JOB:guardrail-halt-<hex>:created: and :outcome:.*:CANCELLED
#     - JOB:halt:<haltedAt> appended
# ===========================================================================
TMP_HOME_J=$(make_openclaw_home)
ARGV_FILE_J=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-j.XXXXXX")

HALTED_AT_J="2026-06-03T11:00:00.000Z"

SID_J_HALT="bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb"
SESSION_JJ="${TMP_HOME_J}/agents/main/sessions/${SID_J_HALT}.jsonl"
cat > "${SESSION_JJ}" <<JSONL
{"type":"session","version":3,"id":"${SID_J_HALT}","timestamp":"2026-06-01T10:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-JJ-001","parentId":"00000000","timestamp":"2026-06-01T10:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Some work"}]}}
{"type":"message","id":"comp-JJ-001","parentId":"user-JJ-001","timestamp":"2026-06-01T10:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Done"}],"usage":{"input":50,"output":25,"cacheRead":0,"cacheWrite":0,"totalTokens":75}}}
JSONL

# No open jobs in the ledger (it was already empty from make_openclaw_home)

# Write the halt fixture
write_halt_fixture "${TMP_HOME_J}" "${HALTED_AT_J}"

# Compute expected hex via env-passing python3 sha1 (same algorithm as implementation)
EXPECTED_HEX_J=$(
  HALTED_AT="${HALTED_AT_J}" \
  python3 - <<'PY'
import hashlib, os
halted_at = os.environ.get('HALTED_AT', '')
h = hashlib.sha1(halted_at.encode('utf-8')).hexdigest()
print(h[:4])
PY
)
EXPECTED_SYNTH_ID_J="guardrail-halt-${EXPECTED_HEX_J}"

# Run report.sh
run_report "${TMP_HOME_J}" "${ARGV_FILE_J}"
JOBS_LEDGER_J="${TMP_HOME_J}/revenium-jobs.ledger"

# ---------------------------------------------------------------------------
# GROUP J assertions
# ---------------------------------------------------------------------------

# JHALT-02 / D-09: argv contains synthetic id (guardrail-halt-<hex>)
if grep -qF "${EXPECTED_SYNTH_ID_J}" "${ARGV_FILE_J}" 2>/dev/null; then
  pass "GROUP J JHALT-02: ${EXPECTED_SYNTH_ID_J} token present in argv (synthetic interrupted job)"
else
  fail "GROUP J JHALT-02: ${EXPECTED_SYNTH_ID_J} token NOT in argv (RED — halt handler not in report.sh)"
fi

# JHALT-02: argv contains --type interrupted (synthetic job type)
if grep -q "^interrupted$" "${ARGV_FILE_J}" 2>/dev/null; then
  pass "GROUP J JHALT-02: 'interrupted' job type token in argv (D-05)"
else
  fail "GROUP J JHALT-02: 'interrupted' job type token NOT in argv (RED)"
fi

# JHALT-02: argv contains CANCELLED result for synthetic job
if grep -q "^CANCELLED$" "${ARGV_FILE_J}" 2>/dev/null; then
  pass "GROUP J JHALT-02: CANCELLED token present in argv (synthetic job closed CANCELLED)"
else
  fail "GROUP J JHALT-02: CANCELLED token NOT in argv (RED)"
fi

# JHALT-02: ledger has JOB:guardrail-halt-<hex>:created: line
if grep -q "^JOB:${EXPECTED_SYNTH_ID_J}:created:" "${JOBS_LEDGER_J}" 2>/dev/null; then
  pass "GROUP J JHALT-02: JOB:${EXPECTED_SYNTH_ID_J}:created: in jobs ledger"
else
  fail "GROUP J JHALT-02: no JOB:${EXPECTED_SYNTH_ID_J}:created: in jobs ledger (RED)"
fi

# JHALT-02: ledger has JOB:guardrail-halt-<hex>:outcome:.*:CANCELLED line
if grep -q "^JOB:${EXPECTED_SYNTH_ID_J}:outcome:.*:CANCELLED$" "${JOBS_LEDGER_J}" 2>/dev/null; then
  pass "GROUP J JHALT-02: JOB:${EXPECTED_SYNTH_ID_J}:outcome:.*:CANCELLED in jobs ledger"
else
  fail "GROUP J JHALT-02: no JOB:${EXPECTED_SYNTH_ID_J}:outcome:.*:CANCELLED in jobs ledger (RED)"
fi

# D-03: JOB:halt:<haltedAt> appended
halt_gate_count_j=$(count_grep "^JOB:halt:${HALTED_AT_J}$" "${JOBS_LEDGER_J}")
if [[ "${halt_gate_count_j}" -eq 1 ]]; then
  pass "GROUP J D-03: exactly 1 JOB:halt:${HALTED_AT_J} line in jobs ledger"
else
  fail "GROUP J D-03: expected 1 JOB:halt:${HALTED_AT_J} line, got ${halt_gate_count_j} (RED)"
fi

rm -f "${ARGV_FILE_J}"

# ===========================================================================
# GROUP K: D-08 — multiple open jobs -> all closed CANCELLED, no synthetic
#   Pre-seed ledger with two open jobs (add-auth-9f3c, refactor-api-1b1b).
#   Assert both are closed CANCELLED; no guardrail-halt- synthetic created.
# ===========================================================================
TMP_HOME_K=$(make_openclaw_home)
ARGV_FILE_K=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-k.XXXXXX")

HALTED_AT_K="2026-06-03T12:00:00.000Z"
OPEN_JOB_ID_K1="add-auth-9f3c"
OPEN_JOB_ID_K2="refactor-api-1b1b"

SID_K1="cccccccc-3333-3333-3333-cccccccccccc"
SESSION_K1="${TMP_HOME_K}/agents/main/sessions/${SID_K1}.jsonl"
cat > "${SESSION_K1}" <<JSONL
{"type":"session","version":3,"id":"${SID_K1}","timestamp":"2026-06-01T11:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-K1-001","parentId":"00000000","timestamp":"2026-06-01T11:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Multi job work"}]}}
{"type":"message","id":"comp-K1-001","parentId":"user-K1-001","timestamp":"2026-06-01T11:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Done"}],"usage":{"input":50,"output":25,"cacheRead":0,"cacheWrite":0,"totalTokens":75}}}
JSONL

# Pre-seed ledger with two open jobs (no outcome lines for either)
printf '%s\n' \
  "JOB:${OPEN_JOB_ID_K1}:created:1700000000.000" \
  "JOB:${OPEN_JOB_ID_K2}:created:1700000001.000" \
  >> "${TMP_HOME_K}/revenium-jobs.ledger"

# Write the halt fixture
write_halt_fixture "${TMP_HOME_K}" "${HALTED_AT_K}"

# Run report.sh
run_report "${TMP_HOME_K}" "${ARGV_FILE_K}"
JOBS_LEDGER_K="${TMP_HOME_K}/revenium-jobs.ledger"

# ---------------------------------------------------------------------------
# GROUP K assertions
# ---------------------------------------------------------------------------

# D-08: both open jobs closed CANCELLED in argv
if grep -q "^${OPEN_JOB_ID_K1}$" "${ARGV_FILE_K}" 2>/dev/null; then
  pass "GROUP K D-08: ${OPEN_JOB_ID_K1} token in argv (CANCELLED close)"
else
  fail "GROUP K D-08: ${OPEN_JOB_ID_K1} NOT in argv (RED)"
fi

if grep -q "^${OPEN_JOB_ID_K2}$" "${ARGV_FILE_K}" 2>/dev/null; then
  pass "GROUP K D-08: ${OPEN_JOB_ID_K2} token in argv (CANCELLED close)"
else
  fail "GROUP K D-08: ${OPEN_JOB_ID_K2} NOT in argv (RED)"
fi

# D-08: both get :outcome:.*:CANCELLED in the ledger
if grep -q "^JOB:${OPEN_JOB_ID_K1}:outcome:.*:CANCELLED$" "${JOBS_LEDGER_K}" 2>/dev/null; then
  pass "GROUP K D-08: JOB:${OPEN_JOB_ID_K1}:outcome:.*:CANCELLED in jobs ledger"
else
  fail "GROUP K D-08: no JOB:${OPEN_JOB_ID_K1}:outcome:.*:CANCELLED in jobs ledger (RED)"
fi

if grep -q "^JOB:${OPEN_JOB_ID_K2}:outcome:.*:CANCELLED$" "${JOBS_LEDGER_K}" 2>/dev/null; then
  pass "GROUP K D-08: JOB:${OPEN_JOB_ID_K2}:outcome:.*:CANCELLED in jobs ledger"
else
  fail "GROUP K D-08: no JOB:${OPEN_JOB_ID_K2}:outcome:.*:CANCELLED in jobs ledger (RED)"
fi

# D-08: NO guardrail-halt- synthetic (open-count was 2, not 0)
if grep -q "guardrail-halt-" "${ARGV_FILE_K}" 2>/dev/null; then
  fail "GROUP K D-08: guardrail-halt- token found (must NOT appear when open jobs exist)"
else
  pass "GROUP K D-08: no guardrail-halt- token in argv (correct — 2 real jobs were open)"
fi

# Count of CANCELLED results == 2 (one per open job)
cancelled_count_k=$(count_grep "^CANCELLED$" "${ARGV_FILE_K}")
if [[ "${cancelled_count_k}" -eq 2 ]]; then
  pass "GROUP K D-08: exactly 2 CANCELLED tokens in argv (one per open job)"
else
  fail "GROUP K D-08: expected 2 CANCELLED tokens, got ${cancelled_count_k} (RED)"
fi

rm -f "${ARGV_FILE_K}"

# ===========================================================================
# GROUP L: D-03 idempotency across ticks — same OPENCLAW_HOME, same haltedAt
#   Same fixture as GROUP I (single open real job).
#   Run report.sh TWICE without resetting the ledger (mirror GROUP E pattern).
#   Assert across both runs: halt-driven CANCELLED outcome for the open job
#   appears exactly 1 time total, and JOB:halt:<haltedAt> appears exactly once.
# ===========================================================================
TMP_HOME_L=$(make_openclaw_home)
ARGV_FILE_L1=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-l1.XXXXXX")
ARGV_FILE_L2=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-l2.XXXXXX")

HALTED_AT_L="2026-06-03T13:00:00.000Z"
OPEN_JOB_ID_L="add-auth-9f3c"

SID_L1="dddddddd-4444-4444-4444-dddddddddddd"
SESSION_L1="${TMP_HOME_L}/agents/main/sessions/${SID_L1}.jsonl"
cat > "${SESSION_L1}" <<JSONL
{"type":"session","version":3,"id":"${SID_L1}","timestamp":"2026-06-01T12:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-L1-001","parentId":"00000000","timestamp":"2026-06-01T12:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Idempotent halt work"}]}}
{"type":"message","id":"comp-L1-001","parentId":"user-L1-001","timestamp":"2026-06-01T12:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Done"}],"usage":{"input":50,"output":25,"cacheRead":0,"cacheWrite":0,"totalTokens":75}}}
JSONL

# Pre-seed the jobs ledger with the open job (created, no outcome)
printf '%s\n' "JOB:${OPEN_JOB_ID_L}:created:1700000000.000" \
  >> "${TMP_HOME_L}/revenium-jobs.ledger"

# Write the halt fixture (stays halted across both ticks — same haltedAt)
write_halt_fixture "${TMP_HOME_L}" "${HALTED_AT_L}"

# First run
run_report "${TMP_HOME_L}" "${ARGV_FILE_L1}"
# Second run — same OPENCLAW_HOME, no reset (mirrors GROUP E pattern)
run_report "${TMP_HOME_L}" "${ARGV_FILE_L2}"

JOBS_LEDGER_L="${TMP_HOME_L}/revenium-jobs.ledger"

# Merge both argv files for cross-run token counts
ARGV_FILE_L_MERGED=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-l-merged.XXXXXX")
cat "${ARGV_FILE_L1}" "${ARGV_FILE_L2}" > "${ARGV_FILE_L_MERGED}"

# D-03: halt-driven CANCELLED outcome for the open job appears exactly 1 time
# across both runs (second tick hits the JOB:halt:<haltedAt> gate and skips)
cancelled_count_l=$(count_grep "^CANCELLED$" "${ARGV_FILE_L_MERGED}")
if [[ "${cancelled_count_l}" -eq 1 ]]; then
  pass "GROUP L D-03: exactly 1 CANCELLED token across 2 runs (idempotent — halt gate worked)"
else
  fail "GROUP L D-03: expected 1 CANCELLED token across 2 runs, got ${cancelled_count_l} (RED)"
fi

# D-03: JOB:halt:<haltedAt> appears exactly once in the jobs ledger
halt_gate_count_l=$(count_grep "^JOB:halt:${HALTED_AT_L}$" "${JOBS_LEDGER_L}")
if [[ "${halt_gate_count_l}" -eq 1 ]]; then
  pass "GROUP L D-03: exactly 1 JOB:halt:${HALTED_AT_L} line in jobs ledger across 2 runs"
else
  fail "GROUP L D-03: expected 1 JOB:halt:${HALTED_AT_L} line, got ${halt_gate_count_l} (RED)"
fi

# D-03: outcome ledger entry for the open job appears exactly once
outcome_ledger_count_l=$(count_grep "^JOB:${OPEN_JOB_ID_L}:outcome:.*:CANCELLED$" "${JOBS_LEDGER_L}")
if [[ "${outcome_ledger_count_l}" -eq 1 ]]; then
  pass "GROUP L D-03: exactly 1 JOB:${OPEN_JOB_ID_L}:outcome:.*:CANCELLED in ledger across 2 runs"
else
  fail "GROUP L D-03: expected 1 outcome ledger line, got ${outcome_ledger_count_l} (RED)"
fi

rm -f "${ARGV_FILE_L1}" "${ARGV_FILE_L2}" "${ARGV_FILE_L_MERGED}"

# ===========================================================================
# GROUP M: D-10 fail-open — halt handler never endangers metering
#
# M1: JOBS_CLI_CAPABLE=false via STUB_REVENIUM_NO_JOBS=1
#     Assert: zero guardrail-halt- tokens, zero halt-driven CANCELLED tokens,
#     report.sh exits 0.
#
# M2: Open job present; STUB_REVENIUM_HALT_JOBS_FAIL=1 (halt jobs calls fail).
#     Uses GROUP D exit-code-capture pattern (|| report_rc_m2=$?) NOT GROUP B
#     "|| true" form, so the exit-code assertion is reachable.
#     Assert: report.sh exits 0 (fail-open), per-session metering tokens still
#     present, NO JOB:halt:<haltedAt> line appended (failed halt not gated as done).
# ===========================================================================

# --- M1: JOBS_CLI_CAPABLE=false (STUB_REVENIUM_NO_JOBS) ---
TMP_HOME_M1=$(make_openclaw_home)
ARGV_FILE_M1=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-m1.XXXXXX")

HALTED_AT_M1="2026-06-03T14:00:00.000Z"

SID_M1="eeeeeeee-5555-5555-5555-eeeeeeeeeeee"
SESSION_M1="${TMP_HOME_M1}/agents/main/sessions/${SID_M1}.jsonl"
cat > "${SESSION_M1}" <<JSONL
{"type":"session","version":3,"id":"${SID_M1}","timestamp":"2026-06-01T13:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-M1-001","parentId":"00000000","timestamp":"2026-06-01T13:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Fail open work"}]}}
{"type":"message","id":"comp-M1-001","parentId":"user-M1-001","timestamp":"2026-06-01T13:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Done"}],"usage":{"input":50,"output":25,"cacheRead":0,"cacheWrite":0,"totalTokens":75}}}
JSONL

# Write halt fixture (halted, but JOBS_CLI_CAPABLE=false should skip the whole handler)
write_halt_fixture "${TMP_HOME_M1}" "${HALTED_AT_M1}"

# Run with STUB_REVENIUM_NO_JOBS=1 — probe fails → JOBS_CLI_CAPABLE=false
# Capture exit code using GROUP D pattern
report_rc_m1=0
STUB_REVENIUM_NO_JOBS=1 STUB_REVENIUM_ARGV_FILE="${ARGV_FILE_M1}" \
  OPENCLAW_HOME="${TMP_HOME_M1}" HOME="${TMP_FAKE_HOME}" \
  bash "${REPORT_SH}" 2>&1 || report_rc_m1=$?

# M1: zero guardrail-halt- tokens (halt handler skipped)
if grep -q "guardrail-halt-" "${ARGV_FILE_M1}" 2>/dev/null; then
  fail "GROUP M M1 D-10: guardrail-halt- token found (halt handler must be skipped when JOBS_CLI_CAPABLE=false)"
else
  pass "GROUP M M1 D-10: zero guardrail-halt- tokens (halt handler skipped — JOBS_CLI_CAPABLE=false)"
fi

# M1: zero halt-driven CANCELLED tokens (no halt jobs calls at all)
if grep -q "^CANCELLED$" "${ARGV_FILE_M1}" 2>/dev/null; then
  fail "GROUP M M1 D-10: CANCELLED token found (must be zero when halt handler is skipped)"
else
  pass "GROUP M M1 D-10: zero CANCELLED tokens (no halt jobs calls — correct)"
fi

# M1: report.sh exits 0 (fail-open — JOBS_CLI_CAPABLE=false must not abort)
if [[ "${report_rc_m1}" -eq 0 ]]; then
  pass "GROUP M M1 D-10: report.sh exits 0 when JOBS_CLI_CAPABLE=false (fail-open)"
else
  fail "GROUP M M1 D-10: report.sh exited ${report_rc_m1} (should be 0 — fail-open violated)"
fi

rm -f "${ARGV_FILE_M1}"

# --- M2: STUB_REVENIUM_HALT_JOBS_FAIL=1 (halt jobs CLI fails mid-tick) ---
TMP_HOME_M2=$(make_openclaw_home)
ARGV_FILE_M2=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-m2.XXXXXX")

HALTED_AT_M2="2026-06-03T15:00:00.000Z"
OPEN_JOB_ID_M2="add-auth-9f3c"

SID_M2="ffffffff-6666-6666-6666-ffffffffffff"
SESSION_M2="${TMP_HOME_M2}/agents/main/sessions/${SID_M2}.jsonl"
cat > "${SESSION_M2}" <<JSONL
{"type":"session","version":3,"id":"${SID_M2}","timestamp":"2026-06-01T14:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-M2-001","parentId":"00000000","timestamp":"2026-06-01T14:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Halt jobs fail work"}]}}
{"type":"message","id":"comp-M2-001","parentId":"user-M2-001","timestamp":"2026-06-01T14:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Done"}],"usage":{"input":50,"output":25,"cacheRead":0,"cacheWrite":0,"totalTokens":75}}}
JSONL

# Pre-seed the jobs ledger with an open job (halt handler will try to close it)
printf '%s\n' "JOB:${OPEN_JOB_ID_M2}:created:1700000000.000" \
  >> "${TMP_HOME_M2}/revenium-jobs.ledger"

# Write the halt fixture
write_halt_fixture "${TMP_HOME_M2}" "${HALTED_AT_M2}"

# Run with STUB_REVENIUM_HALT_JOBS_FAIL=1 — halt jobs calls fail, normal jobs pass.
# Use GROUP D exit-code-capture pattern (NOT "|| true") so exit-0 assertion is reachable.
report_rc_m2=0
STUB_REVENIUM_HALT_JOBS_FAIL=1 STUB_REVENIUM_ARGV_FILE="${ARGV_FILE_M2}" \
  OPENCLAW_HOME="${TMP_HOME_M2}" HOME="${TMP_FAKE_HOME}" \
  bash "${REPORT_SH}" 2>&1 || report_rc_m2=$?

JOBS_LEDGER_M2="${TMP_HOME_M2}/revenium-jobs.ledger"

# M2: report.sh exits 0 (halt jobs failure must not abort the tick — D-10)
if [[ "${report_rc_m2}" -eq 0 ]]; then
  pass "GROUP M M2 D-10: report.sh exits 0 when halt jobs CLI fails (fail-open)"
else
  fail "GROUP M M2 D-10: report.sh exited ${report_rc_m2} (should be 0 — halt jobs failure must not abort tick)"
fi

# M2: per-session metering tokens still present (--task-type and --agent unaffected)
if grep -q "^--task-type$" "${ARGV_FILE_M2}" 2>/dev/null; then
  pass "GROUP M M2 D-10: --task-type present in argv (per-session metering unaffected)"
else
  fail "GROUP M M2 D-10: --task-type NOT in argv (RED — metering must survive halt jobs failure)"
fi

if grep -q "^--agent$" "${ARGV_FILE_M2}" 2>/dev/null; then
  pass "GROUP M M2 D-10: --agent present in argv (v1.0 metering unaffected)"
else
  fail "GROUP M M2 D-10: --agent NOT in argv (RED)"
fi

# M2: NO JOB:halt:<haltedAt> line appended (failed halt close is not gated as done;
# retried next tick — the gate must only be written on successful processing)
halt_gate_count_m2=$(count_grep "^JOB:halt:${HALTED_AT_M2}$" "${JOBS_LEDGER_M2}")
if [[ "${halt_gate_count_m2}" -eq 0 ]]; then
  pass "GROUP M M2 D-10: no JOB:halt:${HALTED_AT_M2} in ledger (failed halt not gated — will retry next tick)"
else
  fail "GROUP M M2 D-10: JOB:halt:${HALTED_AT_M2} found in ledger (must NOT be written on failure — RED)"
fi

rm -f "${ARGV_FILE_M2}"

# ===========================================================================
# GROUP LIFECYCLE: RUNNING open -> stamp -> close (declare-at-start, 2026-06-13)
#
# A RUNNING marker at arc start must: create the job immediately (visible in
# Revenium while running), stamp completions inside the open interval with
# --agentic-job-id (Phase C), and NOT close the job. The later terminal marker
# closes it. A RUNNING marker with no terminal row past REVENIUM_JOB_STALE_HOURS
# is closed CANCELLED by the stale janitor.
# ===========================================================================
SID_LC="6c6c6c6c-8888-8888-8888-6c6c6c6c6c6c"
JOB_ID_LC="open-arc-lc-1a2b"

TMP_HOME_LC=$(make_openclaw_home)
ARGV_FILE_LC1=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-lc1.XXXXXX")
ARGV_FILE_LC2=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-lc2.XXXXXX")

SESSION_LC="${TMP_HOME_LC}/agents/main/sessions/${SID_LC}.jsonl"
cat > "${SESSION_LC}" <<JSONL
{"type":"session","version":3,"id":"${SID_LC}","timestamp":"2026-02-01T10:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-LC-001","parentId":"00000000","timestamp":"2026-02-01T10:00:30.000Z","message":{"role":"user","content":[{"type":"text","text":"Do the thing"}]}}
{"type":"message","id":"comp-LC-001","parentId":"user-LC-001","timestamp":"2026-02-01T10:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Working"}],"usage":{"input":70,"output":35,"cacheRead":0,"cacheWrite":0,"totalTokens":105}}}
JSONL

# RUNNING marker at 10:01 — BEFORE the completion, no completion_id (open form)
MARKER_LC="${TMP_HOME_LC}/skills/revenium/markers/${SID_LC}.jsonl"
printf '%s\n' '{"kind":"job","ts":"2026-02-01T10:01:00Z","sid":"'"${SID_LC}"'","agentic_job_id":"'"${JOB_ID_LC}"'","job_name":"Open arc","job_type":"testing","status":"RUNNING"}' > "${MARKER_LC}"

# Tick 1: create fires (sweep), completion stamps to the open job, NO outcome.
# (Fixture timestamps are months old, so the stale janitor is pushed out of the
# way with a huge threshold — LC-5 below tests the janitor with the default.)
run_report "${TMP_HOME_LC}" "${ARGV_FILE_LC1}" "REVENIUM_JOB_STALE_HOURS=9999999" > /dev/null 2>&1
JOBS_LEDGER_LC="${TMP_HOME_LC}/revenium-jobs.ledger"

create_count_lc1=$(count_grep "^create$" "${ARGV_FILE_LC1}")
outcome_count_lc1=$(count_grep "^outcome$" "${ARGV_FILE_LC1}")
if [[ "${create_count_lc1}" -ge 1 && "${outcome_count_lc1}" -eq 0 ]]; then
  pass "LC-1: RUNNING marker creates the job on tick 1 and does NOT close it"
else
  fail "LC-1: expected create>=1 outcome=0 on tick 1, got create=${create_count_lc1} outcome=${outcome_count_lc1}"
fi

id_count_lc1=$(count_grep "^${JOB_ID_LC}$" "${ARGV_FILE_LC1}")
if [[ "${id_count_lc1}" -ge 2 ]]; then
  pass "LC-2: completion inside the open interval is STAMPED with --agentic-job-id (id appears in create + stamp argv)"
else
  fail "LC-2: expected job id >=2 times in tick-1 argv (create + completion stamp), got ${id_count_lc1}"
fi

if grep -q "^JOB:${JOB_ID_LC}:created:" "${JOBS_LEDGER_LC}" 2>/dev/null \
   && ! grep -q "^JOB:${JOB_ID_LC}:outcome:" "${JOBS_LEDGER_LC}" 2>/dev/null; then
  pass "LC-3: ledger has created but NOT outcome after tick 1 (job stays open)"
else
  fail "LC-3: unexpected ledger state after tick 1: $(cat "${JOBS_LEDGER_LC}" 2>/dev/null | tr '\n' '|')"
fi

# Arc ends: terminal marker (what --close emits) referencing the now-TX-ledgered completion.
printf '%s\n' '{"kind":"job","ts":"2026-02-01T10:05:00Z","sid":"'"${SID_LC}"'","agentic_job_id":"'"${JOB_ID_LC}"'","job_name":"Open arc","job_type":"testing","status":"SUCCESS","completion_id":"comp-LC-001"}' >> "${MARKER_LC}"

# Tick 2: outcome fires; no duplicate create.
run_report "${TMP_HOME_LC}" "${ARGV_FILE_LC2}" "REVENIUM_JOB_STALE_HOURS=9999999" > /dev/null 2>&1
create_count_lc2=$(count_grep "^create$" "${ARGV_FILE_LC2}")
outcome_count_lc2=$(count_grep "^outcome$" "${ARGV_FILE_LC2}")
if [[ "${create_count_lc2}" -eq 0 && "${outcome_count_lc2}" -ge 1 ]] \
   && grep -q "^JOB:${JOB_ID_LC}:outcome:.*:SUCCESS$" "${JOBS_LEDGER_LC}" 2>/dev/null; then
  pass "LC-4: terminal marker closes the job on tick 2 (no duplicate create)"
else
  fail "LC-4: expected create=0 outcome>=1 + SUCCESS ledger, got create=${create_count_lc2} outcome=${outcome_count_lc2}"
fi

rm -f "${ARGV_FILE_LC1}" "${ARGV_FILE_LC2}" 2>/dev/null || true

# --- Stale janitor: RUNNING with no terminal row past the threshold -> CANCELLED ---
SID_LJ="7d7d7d7d-9999-9999-9999-7d7d7d7d7d7d"
JOB_ID_LJ="abandoned-arc-lj-4e4e"
TMP_HOME_LJ=$(make_openclaw_home)
ARGV_FILE_LJ=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-lj.XXXXXX")
SESSION_LJ="${TMP_HOME_LJ}/agents/main/sessions/${SID_LJ}.jsonl"
cat > "${SESSION_LJ}" <<JSONL
{"type":"session","version":3,"id":"${SID_LJ}","timestamp":"2026-02-01T11:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"comp-LJ-001","parentId":"00000000","timestamp":"2026-02-01T11:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Started"}],"usage":{"input":50,"output":25,"cacheRead":0,"cacheWrite":0,"totalTokens":75}}}
JSONL
# RUNNING marker months old (fixture date), never closed.
printf '%s\n' '{"kind":"job","ts":"2026-02-01T11:01:00Z","sid":"'"${SID_LJ}"'","agentic_job_id":"'"${JOB_ID_LJ}"'","job_name":"Abandoned arc","job_type":"testing","status":"RUNNING"}' > "${TMP_HOME_LJ}/skills/revenium/markers/${SID_LJ}.jsonl"

run_report "${TMP_HOME_LJ}" "${ARGV_FILE_LJ}" > /dev/null 2>&1
JOBS_LEDGER_LJ="${TMP_HOME_LJ}/revenium-jobs.ledger"
if grep -q "^JOB:${JOB_ID_LJ}:created:" "${JOBS_LEDGER_LJ}" 2>/dev/null \
   && grep -q "^JOB:${JOB_ID_LJ}:outcome:.*:CANCELLED$" "${JOBS_LEDGER_LJ}" 2>/dev/null; then
  pass "LC-5: stale janitor closes an abandoned RUNNING job as CANCELLED (default 24h threshold)"
else
  fail "LC-5: expected created + CANCELLED outcome for stale open job, ledger: $(cat "${JOBS_LEDGER_LJ}" 2>/dev/null | tr '\n' '|')"
fi
rm -f "${ARGV_FILE_LJ}" 2>/dev/null || true

# ===========================================================================
# GROUP SWEEP: stale-completion job marker (regression, live 2026-06-13)
#
# With a 1-minute cron, an arc's mid-arc completion is often metered by an
# EARLIER tick than the arc-end job marker that references it. The completion
# is then TX-ledger-skipped on every later tick, so the in-loop create/outcome
# (which only fire while processing that completion) never run — the job is
# silently never created. The per-session jobs sweep must consume the marker
# anyway: create + outcome on the next tick after the marker appears.
# ===========================================================================
SID_SW="5e5e5e5e-7777-7777-7777-5e5e5e5e5e5e"
JOB_ID_SW="stale-marker-sweep-9f3b"

TMP_HOME_SW=$(make_openclaw_home)
ARGV_FILE_SW1=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-sw1.XXXXXX")
ARGV_FILE_SW2=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-sw2.XXXXXX")

SESSION_SW="${TMP_HOME_SW}/agents/main/sessions/${SID_SW}.jsonl"
cat > "${SESSION_SW}" <<JSONL
{"type":"session","version":3,"id":"${SID_SW}","timestamp":"2026-02-01T15:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-SW-001","parentId":"00000000","timestamp":"2026-02-01T15:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Reconfigure the budget"}]}}
{"type":"message","id":"comp-SW-001","parentId":"user-SW-001","timestamp":"2026-02-01T15:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Working on it"}],"usage":{"input":90,"output":45,"cacheRead":0,"cacheWrite":0,"totalTokens":135}}}
JSONL

# Tick 1: NO job marker yet — the completion gets metered + TX-ledgered and the
# offset is fully consumed (the live pre-marker state).
run_report "${TMP_HOME_SW}" "${ARGV_FILE_SW1}" > /dev/null 2>&1

JOBS_LEDGER_SW="${TMP_HOME_SW}/revenium-jobs.ledger"

create_count_sw1=$(count_grep "^create$" "${ARGV_FILE_SW1}")
if [[ "${create_count_sw1}" -eq 0 ]]; then
  pass "SWEEP-0: no jobs create on tick 1 (no marker yet)"
else
  fail "SWEEP-0: expected 0 ^create$ on tick 1, got ${create_count_sw1}"
fi

# Between ticks: the arc ends and the agent writes the job marker — referencing
# the ALREADY-METERED completion (this is exactly the live failure shape).
MARKER_SW="${TMP_HOME_SW}/skills/revenium/markers/${SID_SW}.jsonl"
printf '%s\n' '{"kind":"job","ts":"2026-02-01T15:05:00Z","sid":"'"${SID_SW}"'","agentic_job_id":"'"${JOB_ID_SW}"'","job_name":"Stale marker sweep","job_type":"devops","status":"SUCCESS","completion_id":"comp-SW-001"}' > "${MARKER_SW}"

# Tick 2: session has no new lines (offset consumed) — only the sweep can act.
run_report "${TMP_HOME_SW}" "${ARGV_FILE_SW2}" > /dev/null 2>&1

create_count_sw2=$(count_grep "^create$" "${ARGV_FILE_SW2}")
if [[ "${create_count_sw2}" -ge 1 ]]; then
  pass "SWEEP-1: jobs create fired on tick 2 for the stale-completion marker"
else
  fail "SWEEP-1: expected >=1 ^create$ on tick 2, got ${create_count_sw2} (sweep missing — job silently dropped)"
fi

if grep -q "^JOB:${JOB_ID_SW}:created:" "${JOBS_LEDGER_SW}" 2>/dev/null; then
  pass "SWEEP-2: jobs ledger has JOB:${JOB_ID_SW}:created:"
else
  fail "SWEEP-2: no JOB:${JOB_ID_SW}:created: in jobs ledger"
fi

if grep -q "^JOB:${JOB_ID_SW}:outcome:.*:SUCCESS$" "${JOBS_LEDGER_SW}" 2>/dev/null; then
  pass "SWEEP-3: jobs ledger has JOB:${JOB_ID_SW}:outcome:...:SUCCESS (stale cid is TX-ledgered → closeable)"
else
  fail "SWEEP-3: no SUCCESS outcome ledger entry for ${JOB_ID_SW}"
fi

# Tick 3: idempotency — nothing new is created or closed.
ARGV_FILE_SW3=$(mktemp "${TMPDIR:-/tmp}/test-rpt-jobs-argv-sw3.XXXXXX")
run_report "${TMP_HOME_SW}" "${ARGV_FILE_SW3}" > /dev/null 2>&1
create_count_sw3=$(count_grep "^create$" "${ARGV_FILE_SW3}")
outcome_count_sw3=$(count_grep "^outcome$" "${ARGV_FILE_SW3}")
if [[ "${create_count_sw3}" -eq 0 && "${outcome_count_sw3}" -eq 0 ]]; then
  pass "SWEEP-4: tick 3 is a no-op (ledger-gated, exactly-once preserved)"
else
  fail "SWEEP-4: expected 0 create/outcome on tick 3, got create=${create_count_sw3} outcome=${outcome_count_sw3}"
fi

rm -f "${ARGV_FILE_SW1}" "${ARGV_FILE_SW2}" "${ARGV_FILE_SW3}" 2>/dev/null || true

# ===========================================================================
# GROUP A/F/G/H cleanup
# ===========================================================================
# (tmp homes cleaned up by EXIT trap below or manually here)

cleanup_all() {
  rm -rf "${TMP_HOME_A}" "${TMP_HOME_B}" "${TMP_HOME_C}" "${TMP_HOME_D}" "${TMP_HOME_E}" \
    "${TMP_HOME_F}" "${TMP_HOME_G}" "${TMP_HOME_H}" \
    "${TMP_HOME_I}" "${TMP_HOME_J}" "${TMP_HOME_K}" "${TMP_HOME_L}" \
    "${TMP_HOME_M1}" "${TMP_HOME_M2}" "${TMP_HOME_SW}" "${TMP_HOME_LC}" "${TMP_HOME_LJ}" 2>/dev/null || true
  cleanup
}
trap cleanup_all EXIT

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
