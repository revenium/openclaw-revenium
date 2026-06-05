#!/usr/bin/env bash
# =============================================================================
# test_verify_markers.sh — Integration tests for scripts/verify-markers.sh (SC-4)
#
# Tests:
#   1. Session with 3 completions + 3 markers → gap 0, coverage 100%
#   2. Session with 3 completions + 1 marker  → gap 2, coverage ~33%
#   3. Session with 3 completions + 0 markers (no marker file) → gap 3, coverage 0%
#   4. Cron session is excluded from per-session output
#   5. Summary line reports correct totals
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERIFY_MARKERS="${REPO_ROOT}/scripts/verify-markers.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Test setup: build a minimal tmp OPENCLAW_HOME tree
# ---------------------------------------------------------------------------
TMP_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-vm-home.XXXXXX")
TMP_SESSIONS="${TMP_HOME}/agents/main/sessions"
TMP_STATE="${TMP_HOME}/skills/revenium"
TMP_MARKERS="${TMP_STATE}/markers"

mkdir -p "${TMP_SESSIONS}" "${TMP_STATE}" "${TMP_MARKERS}"

cleanup() { rm -rf "${TMP_HOME}"; }
trap cleanup EXIT

# Helper: run verify-markers.sh under isolated OPENCLAW_HOME
run_verify() {
  OPENCLAW_HOME="${TMP_HOME}" bash "${VERIFY_MARKERS}" "$@"
}

# ---------------------------------------------------------------------------
# Helper: write N assistant-completion records to a session JSONL
# ---------------------------------------------------------------------------
write_session() {
  local path="$1"
  local sid="$2"
  local n_completions="$3"

  printf '{"type":"session","id":"%s","timestamp":"2026-01-01T00:00:00.000Z"}\n' "${sid}" > "${path}"
  for i in $(seq 1 "${n_completions}"); do
    printf '{"type":"message","id":"comp-%s-%02d","parentId":"","timestamp":"2026-01-01T%02d:00:00.000Z","message":{"role":"assistant","model":"claude-sonnet","content":[{"type":"text","text":"response %d"}]}}\n' \
      "${sid:0:8}" "${i}" "${i}" "${i}" >> "${path}"
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

# Build session files
write_session "${TMP_SESSIONS}/${SID_FULL}.jsonl" "${SID_FULL}" 3
write_session "${TMP_SESSIONS}/${SID_PART}.jsonl" "${SID_PART}" 3
write_session "${TMP_SESSIONS}/${SID_NONE}.jsonl" "${SID_NONE}" 3
write_session "${TMP_SESSIONS}/${SID_CRON}.jsonl" "${SID_CRON}" 2

# Build marker files
write_markers "${TMP_MARKERS}/${SID_FULL}.jsonl" 3
write_markers "${TMP_MARKERS}/${SID_PART}.jsonl" 1
# SID_NONE: no marker file (intentional)
write_markers "${TMP_MARKERS}/${SID_CRON}.jsonl" 2

# Register the cron session in sessions.json so verify-markers.sh excludes it
cat > "${TMP_SESSIONS}/sessions.json" <<SESSIONS_EOF
{
  "agent:main:cron:default": "${SID_CRON}"
}
SESSIONS_EOF

# ---------------------------------------------------------------------------
# Capture full output for all scenario assertions
# ---------------------------------------------------------------------------
OUTPUT=$(run_verify 2>&1)
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
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
