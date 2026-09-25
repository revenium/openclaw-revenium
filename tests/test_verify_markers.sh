#!/usr/bin/env bash
# =============================================================================
# test_verify_markers.sh — Integration tests for scripts/verify-markers.sh (SC-4)
#
# Rebuilt on the SQLite session-store fixture harness (tests/lib/mk-session-store.sh)
# for Phase 19 plan 19-06, which ports verify-markers.sh's session enumeration and
# completion counting off the transcript-directory scan onto
# scripts/session-store.sh :: store_list_sessions / store_completions (D-10),
# and aligns the completion-counting unit with the metered unit (D-04): one
# DISTINCT responseId, not one assistant-role row.
#
# Tests:
#   1. Session with 3 completions + 3 markers → gap 0, coverage 100%
#   2. Session with 3 completions + 1 marker  → gap 2, coverage ~33%
#   3. Session with 3 completions + 0 markers (no marker file) → gap 3, coverage 0%
#   4. Cron session is excluded from per-session output
#   5. Summary line reports correct totals
#   6. Two assistant events sharing ONE responseId count as ONE completion
#   7. Two distinct responseIds under one runId count as TWO completions
#   8. Running the script leaves no skill state directory behind
#   9. Running against a nonexistent store completes (exit 0), reports zero
#      completions, and does not abort
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERIFY_MARKERS="${REPO_ROOT}/scripts/verify-markers.sh"
MK_LIB="${SCRIPT_DIR}/lib/mk-session-store.sh"

# shellcheck source=lib/mk-session-store.sh
. "${MK_LIB}"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Test setup: build a minimal tmp OPENCLAW_HOME tree with a SQLite store at
# the real agents/<agentId>/agent/openclaw-agent.sqlite layout.
# ---------------------------------------------------------------------------
TMP_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-vm-home.XXXXXX")
TMP_STATE="${TMP_HOME}/skills/revenium"
TMP_MARKERS="${TMP_STATE}/markers"
DB="${TMP_HOME}/agents/main/agent/openclaw-agent.sqlite"

mkdir -p "${TMP_MARKERS}"

cleanup() { rm -rf "${TMP_HOME}"; }
trap cleanup EXIT

# Helper: run verify-markers.sh under isolated OPENCLAW_HOME
run_verify() {
  local home="$1"
  OPENCLAW_HOME="${home}" bash "${VERIFY_MARKERS}"
}

# ---------------------------------------------------------------------------
# Helper: write N distinct-responseId completions to a session in the store.
# Each completion gets its own responseId, so N calls always report as N
# completions (the metered unit, D-04) — mirrors the old write_session's
# "N assistant records = N completions" intent on the old transcript-row unit.
# ---------------------------------------------------------------------------
write_session() {
  local db="$1" sid="$2" n_completions="$3"
  local i
  for i in $(seq 1 "${n_completions}"); do
    mk_assistant_event "${db}" "${sid}" "$((i - 1))" "resp-${sid:0:8}-$(printf '%02d' "${i}")" "run-${sid:0:8}" 10
  done
}

# ---------------------------------------------------------------------------
# Helper: write N task-marker records to a marker JSONL
# ---------------------------------------------------------------------------
write_markers() {
  local path="$1"
  local n_markers="$2"

  : > "${path}"
  for i in $(seq 1 "${n_markers}"); do
    printf '{"ts":"2026-01-01T%02d:00:01Z","task_type":"research"}\n' "${i}" >> "${path}"
  done
}

# ---------------------------------------------------------------------------
# Session IDs for the tests
# ---------------------------------------------------------------------------
SID_FULL="aaaaaaaa-1111-1111-1111-000000000001"  # 3 completions, 3 markers
SID_PART="bbbbbbbb-2222-2222-2222-000000000002"  # 3 completions, 1 marker
SID_NONE="cccccccc-3333-3333-3333-000000000003"  # 3 completions, 0 markers
SID_CRON="dddddddd-4444-4444-4444-000000000004"  # cron session — must be excluded

# Build the store: one session_nodes row per session (non-cron for the first
# three, cron for SID_CRON), plus each session's completions.
mk_store "${DB}"
mk_session "${DB}" "${SID_FULL}" "agent:main:full" "" 400
mk_session "${DB}" "${SID_PART}" "agent:main:part" "" 300
mk_session "${DB}" "${SID_NONE}" "agent:main:none" "" 200
mk_session "${DB}" "${SID_CRON}" "agent:main:cron:default" "cron" 500

write_session "${DB}" "${SID_FULL}" 3
write_session "${DB}" "${SID_PART}" 3
write_session "${DB}" "${SID_NONE}" 3
write_session "${DB}" "${SID_CRON}" 2

# Build marker files
write_markers "${TMP_MARKERS}/${SID_FULL}.jsonl" 3
write_markers "${TMP_MARKERS}/${SID_PART}.jsonl" 1
# SID_NONE: no marker file (intentional)
write_markers "${TMP_MARKERS}/${SID_CRON}.jsonl" 2

# ---------------------------------------------------------------------------
# Capture full output for all scenario assertions
# ---------------------------------------------------------------------------
OUTPUT=$(run_verify "${TMP_HOME}" 2>&1)
EXIT_CODE=$?

if [[ "${EXIT_CODE}" -eq 0 ]]; then
  pass "verify-markers.sh exits 0"
else
  fail "verify-markers.sh exited non-zero (exit ${EXIT_CODE})"
fi

# ---------------------------------------------------------------------------
# Test 1: Session with 3 completions + 3 markers → gap 0, coverage 100%
# ---------------------------------------------------------------------------
# The script outputs columns: session_id | completions | markers | gap | coverage%
# We look for the SID_FULL line and verify its values.

SID_FULL_LINE=$(echo "${OUTPUT}" | grep "${SID_FULL}" || true)
if [[ -n "${SID_FULL_LINE}" ]]; then
  pass "SID_FULL (3c/3m) appears in output"

  if echo "${SID_FULL_LINE}" | grep -qE '[[:space:]]3[[:space:]]+3[[:space:]]'; then
    pass "SID_FULL shows 3 completions and 3 markers"
  else
    fail "SID_FULL line does not show 3 completions/3 markers: '${SID_FULL_LINE}'"
  fi

  if echo "${SID_FULL_LINE}" | grep -qE '[[:space:]]0[[:space:]]+100%'; then
    pass "SID_FULL shows gap 0 and coverage 100%"
  else
    fail "SID_FULL line does not show gap 0 / 100%: '${SID_FULL_LINE}'"
  fi
else
  fail "SID_FULL not found in output"
  fail "SID_FULL shows 3 completions and 3 markers (skipped — row missing)"
  fail "SID_FULL shows gap 0 and coverage 100% (skipped — row missing)"
fi

# ---------------------------------------------------------------------------
# Test 2: Session with 3 completions + 1 marker → gap 2, coverage ~33%
# ---------------------------------------------------------------------------
SID_PART_LINE=$(echo "${OUTPUT}" | grep "${SID_PART}" || true)
if [[ -n "${SID_PART_LINE}" ]]; then
  pass "SID_PART (3c/1m) appears in output"

  if echo "${SID_PART_LINE}" | grep -qE '[[:space:]]3[[:space:]]+1[[:space:]]'; then
    pass "SID_PART shows 3 completions and 1 marker"
  else
    fail "SID_PART line does not show 3 completions/1 marker: '${SID_PART_LINE}'"
  fi

  # gap=2, coverage=33% (round(1/3*100)=33)
  if echo "${SID_PART_LINE}" | grep -qE '[[:space:]]2[[:space:]]+33%'; then
    pass "SID_PART shows gap 2 and coverage 33%"
  else
    fail "SID_PART line does not show gap 2 / 33%: '${SID_PART_LINE}'"
  fi
else
  fail "SID_PART not found in output"
  fail "SID_PART shows 3 completions and 1 marker (skipped — row missing)"
  fail "SID_PART shows gap 2 and coverage 33% (skipped — row missing)"
fi

# ---------------------------------------------------------------------------
# Test 3: Session with 3 completions + 0 markers (no marker file) → gap 3, coverage 0%
# ---------------------------------------------------------------------------
SID_NONE_LINE=$(echo "${OUTPUT}" | grep "${SID_NONE}" || true)
if [[ -n "${SID_NONE_LINE}" ]]; then
  pass "SID_NONE (3c/0m) appears in output"

  if echo "${SID_NONE_LINE}" | grep -qE '[[:space:]]3[[:space:]]+0[[:space:]]'; then
    pass "SID_NONE shows 3 completions and 0 markers"
  else
    fail "SID_NONE line does not show 3 completions/0 markers: '${SID_NONE_LINE}'"
  fi

  if echo "${SID_NONE_LINE}" | grep -qE '[[:space:]]3[[:space:]]+0%'; then
    pass "SID_NONE shows gap 3 and coverage 0%"
  else
    fail "SID_NONE line does not show gap 3 / 0%: '${SID_NONE_LINE}'"
  fi
else
  fail "SID_NONE not found in output"
  fail "SID_NONE shows 3 completions and 0 markers (skipped — row missing)"
  fail "SID_NONE shows gap 3 and coverage 0% (skipped — row missing)"
fi

# ---------------------------------------------------------------------------
# Test 4: Cron session is excluded from per-session output
# ---------------------------------------------------------------------------
if echo "${OUTPUT}" | grep -q "${SID_CRON}"; then
  fail "cron session SID_CRON appears in output (should be excluded)"
else
  pass "cron session SID_CRON is excluded from per-session output"
fi

# ---------------------------------------------------------------------------
# Test 5: Summary line reports correct totals
# Non-cron sessions: SID_FULL(3c/3m) + SID_PART(3c/1m) + SID_NONE(3c/0m)
# Total completions=9, total markers=4, total gap=5, coverage=round(4/9*100)=44%
# ---------------------------------------------------------------------------
SUMMARY_LINE=$(echo "${OUTPUT}" | grep '^TOTAL:' || true)
if [[ -n "${SUMMARY_LINE}" ]]; then
  pass "TOTAL summary line present"

  if echo "${SUMMARY_LINE}" | grep -q "9 completions"; then
    pass "summary shows 9 total completions"
  else
    fail "summary does not show 9 completions: '${SUMMARY_LINE}'"
  fi

  if echo "${SUMMARY_LINE}" | grep -q "4 markers"; then
    pass "summary shows 4 total markers"
  else
    fail "summary does not show 4 markers: '${SUMMARY_LINE}'"
  fi

  if echo "${SUMMARY_LINE}" | grep -q "5 gap"; then
    pass "summary shows 5 total gap"
  else
    fail "summary does not show 5 gap: '${SUMMARY_LINE}'"
  fi

  if echo "${SUMMARY_LINE}" | grep -q "44% coverage"; then
    pass "summary shows 44% coverage"
  else
    fail "summary does not show 44% coverage: '${SUMMARY_LINE}'"
  fi
else
  fail "TOTAL summary line not found in output"
  fail "summary shows 9 total completions (skipped)"
  fail "summary shows 4 total markers (skipped)"
  fail "summary shows 5 total gap (skipped)"
  fail "summary shows 44% coverage (skipped)"
fi

# ---------------------------------------------------------------------------
# Test 6 (behavior): two assistant events sharing ONE responseId count as ONE
# completion (D-04's dedup unit, inherited from store_completions).
# ---------------------------------------------------------------------------
TMP_HOME6=$(mktemp -d "${TMPDIR:-/tmp}/test-vm-home6.XXXXXX")
DB6="${TMP_HOME6}/agents/main/agent/openclaw-agent.sqlite"
mkdir -p "${TMP_HOME6}/skills/revenium/markers"
SID6="ee000000-0006-0006-0006-000000000006"
mk_store "${DB6}"
mk_session "${DB6}" "${SID6}" "agent:main:six" "" 100
mk_assistant_event "${DB6}" "${SID6}" 0 "shared-resp" "run-6" 10
mk_assistant_event "${DB6}" "${SID6}" 1 "shared-resp" "run-6" 10

OUTPUT6=$(run_verify "${TMP_HOME6}" 2>&1)
LINE6=$(echo "${OUTPUT6}" | grep "${SID6}" || true)
if echo "${LINE6}" | grep -qE '[[:space:]]1[[:space:]]+0[[:space:]]'; then
  pass "6: two assistant events sharing one responseId count as ONE completion"
else
  fail "6: expected 1 completion for shared responseId (line: '${LINE6}')"
fi
rm -rf "${TMP_HOME6}"

# ---------------------------------------------------------------------------
# Test 7 (behavior): two distinct responseIds under one runId count as TWO
# completions.
# ---------------------------------------------------------------------------
TMP_HOME7=$(mktemp -d "${TMPDIR:-/tmp}/test-vm-home7.XXXXXX")
DB7="${TMP_HOME7}/agents/main/agent/openclaw-agent.sqlite"
mkdir -p "${TMP_HOME7}/skills/revenium/markers"
SID7="ff000000-0007-0007-0007-000000000007"
mk_store "${DB7}"
mk_session "${DB7}" "${SID7}" "agent:main:seven" "" 100
mk_assistant_event "${DB7}" "${SID7}" 0 "distinct-resp-1" "run-7" 10
mk_assistant_event "${DB7}" "${SID7}" 1 "distinct-resp-2" "run-7" 10

OUTPUT7=$(run_verify "${TMP_HOME7}" 2>&1)
LINE7=$(echo "${OUTPUT7}" | grep "${SID7}" || true)
if echo "${LINE7}" | grep -qE '[[:space:]]2[[:space:]]+0[[:space:]]'; then
  pass "7: two distinct responseIds under one runId count as TWO completions"
else
  fail "7: expected 2 completions for distinct responseIds (line: '${LINE7}')"
fi
rm -rf "${TMP_HOME7}"

# ---------------------------------------------------------------------------
# Test 8 (behavior): running the script leaves no skill state directory
# behind (WR-01 / SC-5 no-side-effects property survives the D-10 port).
# ---------------------------------------------------------------------------
TMP_HOME8=$(mktemp -d "${TMPDIR:-/tmp}/test-vm-home8.XXXXXX")
DB8="${TMP_HOME8}/agents/main/agent/openclaw-agent.sqlite"
SID8="aa800000-0008-0008-0008-000000000008"
mk_store "${DB8}"
mk_session "${DB8}" "${SID8}" "agent:main:eight" "" 100
mk_assistant_event "${DB8}" "${SID8}" 0 "resp-8" "run-8" 10
# Deliberately do NOT pre-create ${TMP_HOME8}/skills/revenium — the whole
# point of this test is to confirm the script never creates it.

run_verify "${TMP_HOME8}" >/dev/null 2>&1

if [[ ! -d "${TMP_HOME8}/skills" ]]; then
  pass "8: running the script leaves no skill state directory behind"
else
  fail "8: skills/ directory was created as a side effect: $(find "${TMP_HOME8}/skills" 2>/dev/null | tr '\n' ' ')"
fi
rm -rf "${TMP_HOME8}"

# ---------------------------------------------------------------------------
# Test 9 (behavior): running against a nonexistent store completes (exit 0),
# reports zero completions, and does not abort.
# ---------------------------------------------------------------------------
TMP_HOME9=$(mktemp -d "${TMPDIR:-/tmp}/test-vm-home9.XXXXXX")
# Deliberately create nothing under TMP_HOME9 — no agents/, no store.

exit9=0
OUTPUT9=$(run_verify "${TMP_HOME9}" 2>&1) || exit9=$?

if [[ "${exit9}" -eq 0 ]]; then
  pass "9: verify-markers.sh exits 0 against a nonexistent store"
else
  fail "9: verify-markers.sh exited ${exit9} against a nonexistent store"
fi

if echo "${OUTPUT9}" | grep -q "^TOTAL: 0 completions, 0 markers, 0 gap, 0% coverage$"; then
  pass "9: reports zero completions/markers against a nonexistent store"
else
  fail "9: unexpected output against a nonexistent store: '${OUTPUT9}'"
fi
rm -rf "${TMP_HOME9}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
