#!/usr/bin/env bash
# =============================================================================
# test_write_marker.sh — Integration tests for write-marker.sh (METER-02)
#
# Tests:
#   1. Valid taxonomy label appends an ISO8601 marker line and exits 0
#   2. Unknown label exits non-zero and writes no marker line
#   3. Two rapid invocations yield two lines (flock + O_APPEND, no corruption)
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WRITE_MARKER="${REPO_ROOT}/scripts/write-marker.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Test setup: build a minimal tmp OPENCLAW_HOME tree
# ---------------------------------------------------------------------------
TMP_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-wm-home.XXXXXX")
TMP_SESSIONS="${TMP_HOME}/agents/main/sessions"
TMP_STATE="${TMP_HOME}/skills/revenium"
TMP_MARKERS="${TMP_STATE}/markers"
TMP_TAXONOMY="${TMP_STATE}/task-taxonomy.json"

mkdir -p "${TMP_SESSIONS}" "${TMP_STATE}"

# Seed taxonomy (copy from repo root)
cp "${REPO_ROOT}/task-taxonomy.json" "${TMP_TAXONOMY}"

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

# Helper: run write-marker.sh with the tmp OPENCLAW_HOME
run_marker() {
  OPENCLAW_HOME="${TMP_HOME}" bash "${WRITE_MARKER}" "$@"
}

# ---------------------------------------------------------------------------
# Test 1: Valid label — exits 0, prints "marker written: <path>",
#         appends one ISO8601 line to markers/<sid>.jsonl
# ---------------------------------------------------------------------------
output=$(run_marker "research" 2>&1)
exit_code=$?

if [[ "${exit_code}" -eq 0 ]]; then
  pass "valid label (research) exits 0"
else
  fail "valid label (research) exits non-zero (got ${exit_code})"
fi

if echo "${output}" | grep -q "marker written:"; then
  pass "valid label prints 'marker written:'"
else
  fail "valid label output missing 'marker written:' (got: ${output})"
fi

MARKER_FILE="${TMP_MARKERS}/${FAKE_SID}.jsonl"
if [[ -f "${MARKER_FILE}" ]]; then
  pass "marker file created at expected path"
else
  fail "marker file not found at ${MARKER_FILE}"
fi

if [[ -f "${MARKER_FILE}" ]]; then
  line_count=$(wc -l < "${MARKER_FILE}" | tr -d ' ')
  if [[ "${line_count}" -eq 1 ]]; then
    pass "marker file has exactly 1 line after first invocation"
  else
    fail "marker file has ${line_count} lines (expected 1)"
  fi

  marker_line=$(head -1 "${MARKER_FILE}")
  # Validate ISO8601 ts field
  if echo "${marker_line}" | python3 -c "
import json, sys, re
line = sys.stdin.read().strip()
rec = json.loads(line)
assert rec.get('task_type') == 'research', f'bad task_type: {rec}'
assert re.match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$', rec.get('ts','')), f'bad ts: {rec}'
" 2>/dev/null; then
    pass "marker line has ISO8601 ts and task_type=research"
  else
    fail "marker line malformed: ${marker_line}"
  fi
fi

# Validate markers/ dir is mode 0700
if [[ -d "${TMP_MARKERS}" ]]; then
  dir_perms=$(stat -f "%Lp" "${TMP_MARKERS}" 2>/dev/null || stat -c "%a" "${TMP_MARKERS}" 2>/dev/null || echo "unknown")
  if [[ "${dir_perms}" == "700" ]]; then
    pass "markers/ directory is mode 0700"
  else
    fail "markers/ directory mode is ${dir_perms} (expected 700)"
  fi
fi

# ---------------------------------------------------------------------------
# Test 2: Unknown label — exits non-zero, no marker line written
# ---------------------------------------------------------------------------
before_count=0
if [[ -f "${MARKER_FILE}" ]]; then
  before_count=$(wc -l < "${MARKER_FILE}" | tr -d ' ')
fi

bad_exit=0
run_marker "bogus_label_not_in_taxonomy" 2>&1 && bad_exit=$? || bad_exit=$?

if [[ "${bad_exit}" -ne 0 ]]; then
  pass "unknown label exits non-zero (exit ${bad_exit})"
else
  fail "unknown label exited 0 (should be non-zero)"
fi

after_count=0
if [[ -f "${MARKER_FILE}" ]]; then
  after_count=$(wc -l < "${MARKER_FILE}" | tr -d ' ')
fi

if [[ "${after_count}" -eq "${before_count}" ]]; then
  pass "unknown label does not append any marker line"
else
  fail "unknown label appended a line (before=${before_count}, after=${after_count})"
fi

# ---------------------------------------------------------------------------
# Test 3: Two rapid invocations — two lines in the marker file, no corruption
# ---------------------------------------------------------------------------
# Reset marker file
rm -f "${MARKER_FILE}"

run_marker "generation" 2>&1 >/dev/null
run_marker "analysis" 2>&1 >/dev/null

two_count=$(wc -l < "${MARKER_FILE}" | tr -d ' ')
if [[ "${two_count}" -eq 2 ]]; then
  pass "two invocations yield exactly 2 lines"
else
  fail "two invocations yielded ${two_count} lines (expected 2)"
fi

# Each line must be valid JSON
if [[ "${two_count}" -ge 1 ]]; then
  valid_lines=0
  while IFS= read -r ml; do
    if echo "${ml}" | python3 -c "import json,sys; r=json.loads(sys.stdin.read()); assert 'ts' in r and 'task_type' in r" 2>/dev/null; then
      ((valid_lines++)) || true
    fi
  done < "${MARKER_FILE}"

  if [[ "${valid_lines}" -eq "${two_count}" ]]; then
    pass "all ${two_count} lines are valid JSON with ts and task_type"
  else
    fail "only ${valid_lines} of ${two_count} lines are valid JSON"
  fi
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
