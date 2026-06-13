#!/usr/bin/env bash
# =============================================================================
# test_write_job_marker.sh — Integration tests for write-job-marker.sh
#
# Tests cover JOBDEC-01, JOBDEC-03, JOBDEC-04 (Wave 0 RED harness).
# This harness is intentionally RED until plan 02 ships write-job-marker.sh.
#
# Tests:
#   1.  Valid well-formed call — exits 0 + prints "job marker written:" + file created
#   2.  Valid call — written record has all 7 mandatory fields, kind:"job", ISO8601 ts
#   3.  Valid call — markers/ dir is mode 0700
#   4.  Unknown job_type — exits non-zero, no line appended
#   5.  Invalid status value — exits non-zero, no line appended
#   6.  Missing mandatory flag — exits non-zero
#   7.  Two rapid invocations — exactly 2 non-corrupt lines (flock + O_APPEND)
#   8.  failure_reason present for FAILED, absent for SUCCESS and CANCELLED
#   9.  Field with : sanitized to _ in written record
#  10.  Field with | sanitized to _ in written record
#  11.  Field with embedded newline does not break JSONL line count
#  12.  Field longer than length cap (300 chars) truncated to <= 256 chars in record
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WRITE_JOB_MARKER="${REPO_ROOT}/scripts/write-job-marker.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Test setup: build a minimal tmp OPENCLAW_HOME tree
# ---------------------------------------------------------------------------
TMP_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-wjm-home.XXXXXX")
TMP_SESSIONS="${TMP_HOME}/agents/main/sessions"
TMP_STATE="${TMP_HOME}/skills/revenium"
TMP_MARKERS="${TMP_STATE}/markers"
TMP_JOB_TAXONOMY="${TMP_STATE}/job-taxonomy.json"

mkdir -p "${TMP_SESSIONS}" "${TMP_STATE}"

# Seed job taxonomy (copy from repo root)
cp "${REPO_ROOT}/job-taxonomy.json" "${TMP_JOB_TAXONOMY}"

# Create a fake interactive session file (UUID-named)
FAKE_SID="aabbccdd-0001-0001-0001-000000000001"
FAKE_SESSION="${TMP_SESSIONS}/${FAKE_SID}.jsonl"
echo '{"type":"session","id":"aabbccdd-0001-0001-0001-000000000001","timestamp":"2026-01-01T00:00:00.000Z"}' \
  > "${FAKE_SESSION}"
touch "${FAKE_SESSION}"  # set mtime to now (freshest file)

cleanup() {
  rm -rf "${TMP_HOME}"
}
trap cleanup EXIT

# Helper: run write-job-marker.sh with the tmp OPENCLAW_HOME
run_job_marker() {
  OPENCLAW_HOME="${TMP_HOME}" bash "${WRITE_JOB_MARKER}" "$@"
}

# ---------------------------------------------------------------------------
# Test 1: Valid well-formed call — exits 0, prints "job marker written: <path>",
#         creates the marker file
# ---------------------------------------------------------------------------
output=$(run_job_marker \
  --job-id "add-pagination-endpoint-3b1e" \
  --job-name "Add pagination to users endpoint" \
  --job-type "feature_development" \
  --status "SUCCESS" 2>&1)
exit_code=$?

if [[ "${exit_code}" -eq 0 ]]; then
  pass "valid call exits 0"
else
  fail "valid call exits non-zero (got ${exit_code})"
fi

if echo "${output}" | grep -q "job marker written:"; then
  pass "valid call prints 'job marker written:'"
else
  fail "valid call output missing 'job marker written:' (got: ${output})"
fi

MARKER_FILE="${TMP_MARKERS}/${FAKE_SID}.jsonl"
if [[ -f "${MARKER_FILE}" ]]; then
  pass "marker file created at expected path"
else
  fail "marker file not found at ${MARKER_FILE}"
fi

# ---------------------------------------------------------------------------
# Test 2: Written record has all 7 mandatory fields, kind:"job", ISO8601 ts
# ---------------------------------------------------------------------------
if [[ -f "${MARKER_FILE}" ]]; then
  marker_line=$(head -1 "${MARKER_FILE}")
  if echo "${marker_line}" | python3 -c "
import json, sys, re
line = sys.stdin.read().strip()
rec = json.loads(line)
# Check kind field
assert rec.get('kind') == 'job', f'kind field wrong or missing: {rec}'
# Check all 7 mandatory fields present
for field in ('kind', 'ts', 'sid', 'agentic_job_id', 'job_name', 'job_type', 'status'):
    assert field in rec, f'missing mandatory field: {field} in {rec}'
# Check ISO8601 ts
assert re.fullmatch(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$', rec.get('ts','')), f'bad ts: {rec}'
# Check expected values
assert rec.get('job_type') == 'feature_development', f'job_type mismatch: {rec}'
assert rec.get('status') == 'SUCCESS', f'status mismatch: {rec}'
" 2>/dev/null; then
    pass "record has all 7 mandatory fields, kind:job, and ISO8601 ts"
  else
    fail "record malformed or missing mandatory fields: ${marker_line}"
  fi
else
  fail "marker file not present; cannot check record shape"
fi

# ---------------------------------------------------------------------------
# Test 3: markers/ dir is mode 0700
# ---------------------------------------------------------------------------
if [[ -d "${TMP_MARKERS}" ]]; then
  dir_perms=$(stat -f "%Lp" "${TMP_MARKERS}" 2>/dev/null || stat -c "%a" "${TMP_MARKERS}" 2>/dev/null || echo "unknown")
  if [[ "${dir_perms}" == "700" ]]; then
    pass "markers/ directory is mode 0700"
  else
    fail "markers/ directory mode is ${dir_perms} (expected 700)"
  fi
else
  fail "markers/ directory does not exist"
fi

# ---------------------------------------------------------------------------
# Test 4: Unknown job_type — exits non-zero, no marker line appended
# ---------------------------------------------------------------------------
before_count=0
if [[ -f "${MARKER_FILE}" ]]; then
  before_count=$(wc -l < "${MARKER_FILE}" | tr -d ' ')
fi

bad_exit=0
run_job_marker \
  --job-id "test-unknown-type-0001" \
  --job-name "test job" \
  --job-type "bogus_not_in_taxonomy" \
  --status "SUCCESS" 2>&1 && bad_exit=$? || bad_exit=$?

if [[ "${bad_exit}" -ne 0 ]]; then
  pass "unknown job_type exits non-zero (exit ${bad_exit})"
else
  fail "unknown job_type exited 0 (should be non-zero)"
fi

after_count=0
if [[ -f "${MARKER_FILE}" ]]; then
  after_count=$(wc -l < "${MARKER_FILE}" | tr -d ' ')
fi

if [[ "${after_count}" -eq "${before_count}" ]]; then
  pass "unknown job_type does not append any marker line"
else
  fail "unknown job_type appended a line (before=${before_count}, after=${after_count})"
fi

# ---------------------------------------------------------------------------
# Test 5: Invalid status value — exits non-zero, no marker line appended
# ---------------------------------------------------------------------------
before_count=0
if [[ -f "${MARKER_FILE}" ]]; then
  before_count=$(wc -l < "${MARKER_FILE}" | tr -d ' ')
fi

bad_exit=0
run_job_marker \
  --job-id "test-bad-status-0001" \
  --job-name "test job" \
  --job-type "feature_development" \
  --status "INVALID_STATUS" 2>&1 && bad_exit=$? || bad_exit=$?

if [[ "${bad_exit}" -ne 0 ]]; then
  pass "invalid status exits non-zero (exit ${bad_exit})"
else
  fail "invalid status exited 0 (should be non-zero)"
fi

after_count=0
if [[ -f "${MARKER_FILE}" ]]; then
  after_count=$(wc -l < "${MARKER_FILE}" | tr -d ' ')
fi

if [[ "${after_count}" -eq "${before_count}" ]]; then
  pass "invalid status does not append any marker line"
else
  fail "invalid status appended a line (before=${before_count}, after=${after_count})"
fi

# ---------------------------------------------------------------------------
# Test 6: Missing mandatory flag — exits non-zero
# ---------------------------------------------------------------------------
bad_exit=0
run_job_marker \
  --job-id "test-missing-flag-0001" \
  --job-name "test job" \
  --job-type "feature_development" 2>&1 && bad_exit=$? || bad_exit=$?
# --status is missing

if [[ "${bad_exit}" -ne 0 ]]; then
  pass "missing mandatory flag exits non-zero (exit ${bad_exit})"
else
  fail "missing mandatory flag exited 0 (should be non-zero)"
fi

# ---------------------------------------------------------------------------
# Test 7: Two rapid invocations — exactly 2 non-corrupt lines (flock + O_APPEND)
# ---------------------------------------------------------------------------
rm -f "${MARKER_FILE}"

run_job_marker \
  --job-id "concurrent-test-001a" \
  --job-name "Concurrent test job A" \
  --job-type "testing" \
  --status "SUCCESS" 2>&1 >/dev/null

run_job_marker \
  --job-id "concurrent-test-001b" \
  --job-name "Concurrent test job B" \
  --job-type "bug_fix" \
  --status "CANCELLED" 2>&1 >/dev/null

if [[ -f "${MARKER_FILE}" ]]; then
  two_count=$(wc -l < "${MARKER_FILE}" | tr -d ' ')
  if [[ "${two_count}" -eq 2 ]]; then
    pass "two rapid invocations yield exactly 2 lines (flock + O_APPEND)"
  else
    fail "two invocations yielded ${two_count} lines (expected 2)"
  fi

  # Each line must be valid JSON with required fields
  valid_lines=0
  while IFS= read -r ml; do
    if echo "${ml}" | python3 -c "
import json, sys
r = json.loads(sys.stdin.read().strip())
assert 'kind' in r and r['kind'] == 'job'
assert 'ts' in r and 'sid' in r and 'agentic_job_id' in r
" 2>/dev/null; then
      ((valid_lines++)) || true
    fi
  done < "${MARKER_FILE}"

  if [[ "${valid_lines}" -eq "${two_count}" ]]; then
    pass "both lines are valid JSON with kind:job and required fields"
  else
    fail "only ${valid_lines} of ${two_count} lines are valid JSON"
  fi
else
  fail "marker file not found after two invocations"
fi

# ---------------------------------------------------------------------------
# Test 8: failure_reason present for FAILED, absent for SUCCESS and CANCELLED
# ---------------------------------------------------------------------------
rm -f "${MARKER_FILE}"

# FAILED with failure_reason
run_job_marker \
  --job-id "test-failed-reason-001" \
  --job-name "Failed job" \
  --job-type "debugging" \
  --status "FAILED" \
  --failure-reason "could not reproduce the bug" 2>&1 >/dev/null

# SUCCESS — no failure_reason
run_job_marker \
  --job-id "test-success-nofailure-001" \
  --job-name "Success job" \
  --job-type "feature_development" \
  --status "SUCCESS" 2>&1 >/dev/null

# CANCELLED — no failure_reason
run_job_marker \
  --job-id "test-cancelled-nofailure-001" \
  --job-name "Cancelled job" \
  --job-type "research" \
  --status "CANCELLED" 2>&1 >/dev/null

if [[ -f "${MARKER_FILE}" ]]; then
  failure_check=$(MARKER_PATH="${MARKER_FILE}" python3 -c "
import json, os
mf = os.environ['MARKER_PATH']
lines = open(mf).read().strip().splitlines()
assert len(lines) == 3, f'expected 3 lines, got {len(lines)}'
records = [json.loads(l) for l in lines]
failed_rec = next((r for r in records if r.get('status') == 'FAILED'), None)
success_rec = next((r for r in records if r.get('status') == 'SUCCESS'), None)
cancelled_rec = next((r for r in records if r.get('status') == 'CANCELLED'), None)
assert failed_rec is not None, 'FAILED record not found'
assert success_rec is not None, 'SUCCESS record not found'
assert cancelled_rec is not None, 'CANCELLED record not found'
assert 'failure_reason' in failed_rec, f'failure_reason absent from FAILED: {failed_rec}'
assert 'failure_reason' not in success_rec, f'failure_reason present in SUCCESS: {success_rec}'
assert 'failure_reason' not in cancelled_rec, f'failure_reason present in CANCELLED: {cancelled_rec}'
print('OK')
" 2>&1)
  if echo "${failure_check}" | grep -q "^OK"; then
    pass "failure_reason present for FAILED, absent for SUCCESS and CANCELLED"
  else
    fail "failure_reason conditionality check failed: ${failure_check}"
  fi
else
  fail "marker file not found for failure_reason conditionality test"
fi

# ---------------------------------------------------------------------------
# Test 9: Field with : sanitized to _ in written record
# ---------------------------------------------------------------------------
rm -f "${MARKER_FILE}"

run_job_marker \
  --job-id "test-colon-sanitize-001" \
  --job-name "foo:bar" \
  --job-type "feature_development" \
  --status "SUCCESS" 2>&1 >/dev/null

if [[ -f "${MARKER_FILE}" ]]; then
  colon_line=$(head -1 "${MARKER_FILE}")
  if echo "${colon_line}" | python3 -c "
import json, sys
rec = json.loads(sys.stdin.read().strip())
name = rec.get('job_name', '')
assert ':' not in name, f'colon not sanitized in job_name: {name!r}'
assert 'foo_bar' in name or name == 'foo_bar', f'expected foo_bar in job_name, got: {name!r}'
" 2>/dev/null; then
    pass "field with : sanitized to _ in written record"
  else
    fail "field with : was NOT sanitized (line: ${colon_line})"
  fi
else
  fail "marker file not found for colon-sanitization test"
fi

# ---------------------------------------------------------------------------
# Test 10: Field with | sanitized to _ in written record
# ---------------------------------------------------------------------------
rm -f "${MARKER_FILE}"

run_job_marker \
  --job-id "test-pipe-sanitize-001" \
  --job-name "foo|bar" \
  --job-type "feature_development" \
  --status "SUCCESS" 2>&1 >/dev/null

if [[ -f "${MARKER_FILE}" ]]; then
  pipe_line=$(head -1 "${MARKER_FILE}")
  if echo "${pipe_line}" | python3 -c "
import json, sys
rec = json.loads(sys.stdin.read().strip())
name = rec.get('job_name', '')
assert '|' not in name, f'pipe not sanitized in job_name: {name!r}'
assert 'foo_bar' in name or name == 'foo_bar', f'expected foo_bar in job_name, got: {name!r}'
" 2>/dev/null; then
    pass "field with | sanitized to _ in written record"
  else
    fail "field with | was NOT sanitized (line: ${pipe_line})"
  fi
else
  fail "marker file not found for pipe-sanitization test"
fi

# ---------------------------------------------------------------------------
# Test 11: Field with embedded newline does not break JSONL line count
# ---------------------------------------------------------------------------
rm -f "${MARKER_FILE}"

# Pass a job_name that contains a literal newline (via $'...' quoting)
run_job_marker \
  --job-id "test-newline-sanitize-001" \
  --job-name $'foo\nbar' \
  --job-type "feature_development" \
  --status "SUCCESS" 2>&1 >/dev/null

if [[ -f "${MARKER_FILE}" ]]; then
  newline_count=$(wc -l < "${MARKER_FILE}" | tr -d ' ')
  if [[ "${newline_count}" -eq 1 ]]; then
    pass "embedded newline in field does not break JSONL line count (1 line written)"
  else
    fail "JSONL has ${newline_count} lines after embedded-newline test (expected 1)"
  fi
  # Also verify the line is valid JSON
  newline_line=$(head -1 "${MARKER_FILE}")
  if echo "${newline_line}" | python3 -c "import json,sys; json.loads(sys.stdin.read().strip())" 2>/dev/null; then
    pass "record with sanitized newline is valid JSON"
  else
    fail "record with sanitized newline is not valid JSON: ${newline_line}"
  fi
else
  fail "marker file not found for newline-sanitization test"
fi

# ---------------------------------------------------------------------------
# Test 12: Field longer than length cap (300 chars) truncated to <= 256 chars
# ---------------------------------------------------------------------------
rm -f "${MARKER_FILE}"

LONG_NAME=$(python3 -c "print('a' * 300)")

run_job_marker \
  --job-id "test-length-cap-001" \
  --job-name "${LONG_NAME}" \
  --job-type "feature_development" \
  --status "SUCCESS" 2>&1 >/dev/null

if [[ -f "${MARKER_FILE}" ]]; then
  cap_line=$(head -1 "${MARKER_FILE}")
  if echo "${cap_line}" | python3 -c "
import json, sys
rec = json.loads(sys.stdin.read().strip())
name = rec.get('job_name', '')
assert len(name) <= 256, f'job_name length {len(name)} exceeds 256-char cap: {name[:50]!r}...'
" 2>/dev/null; then
    pass "field longer than length cap truncated to <= 256 chars in written record"
  else
    fail "field longer than length cap NOT truncated (line: ${cap_line})"
  fi
else
  fail "marker file not found for length-cap test"
fi

# ---------------------------------------------------------------------------
# Tests 13-17: lifecycle (RUNNING open + --close terminal + state file)
# ---------------------------------------------------------------------------
MARKER_FILE_LC="${TMP_MARKERS}/${FAKE_SID}.jsonl"
STATE_FILE_LC="${TMP_MARKERS}/${FAKE_SID}.current-job.json"

# Test 13: RUNNING accepted — exit 0, record has status RUNNING and NO
# completion_id (open markers stamp by interval, not by id), state file written.
output=$(run_job_marker \
  --job-id "lifecycle-arc-13aa" \
  --job-name "Lifecycle arc" \
  --job-type "testing" \
  --status "RUNNING" 2>&1)
rc=$?
rec13=$(grep '"agentic_job_id":"lifecycle-arc-13aa"' "${MARKER_FILE_LC}" | tail -1)
if [[ ${rc} -eq 0 ]] && echo "${rec13}" | grep -q '"status":"RUNNING"' \
   && ! echo "${rec13}" | grep -q 'completion_id' \
   && grep -q '"agentic_job_id": "lifecycle-arc-13aa"' "${STATE_FILE_LC}" 2>/dev/null; then
  pass "13: RUNNING marker written (no completion_id) + current-job state file recorded"
else
  fail "13: RUNNING lifecycle open failed (rc=${rc}, rec=${rec13:0:120}, state=$(cat "${STATE_FILE_LC}" 2>/dev/null | head -c 80))"
fi

# Test 14: --close SUCCESS — reuses id/name/type from state, clears state file.
output=$(run_job_marker --close --status "SUCCESS" 2>&1)
rc=$?
rec14=$(grep '"agentic_job_id":"lifecycle-arc-13aa"' "${MARKER_FILE_LC}" | tail -1)
if [[ ${rc} -eq 0 ]] && echo "${rec14}" | grep -q '"status":"SUCCESS"' \
   && echo "${rec14}" | grep -q '"job_type":"testing"' \
   && [[ ! -f "${STATE_FILE_LC}" ]]; then
  pass "14: --close reuses open job id/type from state and clears the state file"
else
  fail "14: --close failed (rc=${rc}, rec=${rec14:0:120}, state-exists=$([[ -f ${STATE_FILE_LC} ]] && echo yes || echo no))"
fi

# Test 15: --close with no open job — exits non-zero, no marker appended.
lines_before=$(grep -c '' "${MARKER_FILE_LC}" 2>/dev/null || echo 0)
output=$(run_job_marker --close --status "SUCCESS" 2>&1)
rc=$?
lines_after=$(grep -c '' "${MARKER_FILE_LC}" 2>/dev/null || echo 0)
if [[ ${rc} -ne 0 && "${lines_before}" -eq "${lines_after}" ]]; then
  pass "15: --close with no open job exits non-zero and appends nothing"
else
  fail "15: expected non-zero + no append (rc=${rc}, lines ${lines_before}->${lines_after})"
fi

# Test 16: --close --status RUNNING — rejected (close needs a terminal status).
output=$(run_job_marker --close --job-id "x-16aa" --job-name "X" --job-type "testing" --status "RUNNING" 2>&1)
rc=$?
if [[ ${rc} -ne 0 ]]; then
  pass "16: --close --status RUNNING rejected"
else
  fail "16: --close --status RUNNING was accepted (rc=0)"
fi

# Test 17: --close with explicit --job-id works without a state file.
output=$(run_job_marker --close --job-id "explicit-close-17aa" --job-name "Explicit close" --job-type "testing" --status "CANCELLED" 2>&1)
rc=$?
if [[ ${rc} -eq 0 ]] && grep -q '"agentic_job_id":"explicit-close-17aa"' "${MARKER_FILE_LC}"; then
  pass "17: --close with explicit --job-id works without state file"
else
  fail "17: explicit-id close failed (rc=${rc})"
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
