#!/usr/bin/env bash
# =============================================================================
# test_write_marker.sh — Integration tests for write-marker.sh (METER-02)
#
# Tests:
#   1. Valid taxonomy label appends an ISO8601 marker line and exits 0
#   2. Unknown label exits non-zero and writes no marker line
#   3. Two rapid invocations yield two lines (flock + O_APPEND, no corruption)
#   4. Session with an assistant completion: marker includes completion_id
#   5. Session with no assistant completion: marker omits completion_id field
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
# Test 4: Session with an assistant completion — marker includes completion_id
#
# The real OpenClaw lifecycle: write-marker.sh is called AFTER the turn's LLM
# completion is appended to the session JSONL. The marker should record the
# .id of that completion so report.sh can do an exact id-keyed match (Phase A).
# ---------------------------------------------------------------------------
SID_WITH_COMP="ccddee11-0002-0002-0002-000000000002"
SESSION_WITH_COMP="${TMP_SESSIONS}/${SID_WITH_COMP}.jsonl"

# Append a session header and an assistant completion with a known .id.
# The session must also have a more recent mtime than FAKE_SESSION so that
# write-marker.sh picks this session as the active one.
EXPECTED_COMP_ID="comp-id-abcdef-123456"
printf '%s\n' \
  '{"type":"session","id":"ccddee11-0002-0002-0002-000000000002","timestamp":"2026-06-01T00:00:00.000Z"}' \
  '{"type":"message","id":"user-001","parentId":"","timestamp":"2026-06-01T12:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}' \
  "{\"type\":\"message\",\"id\":\"${EXPECTED_COMP_ID}\",\"parentId\":\"user-001\",\"timestamp\":\"2026-06-01T12:01:00.000Z\",\"message\":{\"role\":\"assistant\",\"model\":\"claude-sonnet-4-5\",\"stopReason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"usage\":{\"input\":10,\"output\":5,\"totalTokens\":15}}}" \
  > "${SESSION_WITH_COMP}"
# Touch with a newer timestamp so last_completion_info selects this session
touch "${SESSION_WITH_COMP}"

MARKER_FILE_C="${TMP_MARKERS}/${SID_WITH_COMP}.jsonl"
rm -f "${MARKER_FILE_C}"

run_marker "generation" 2>&1 >/dev/null

if [[ -f "${MARKER_FILE_C}" ]]; then
  marker_line_c=$(head -1 "${MARKER_FILE_C}")
  if echo "${marker_line_c}" | python3 -c "
import json, sys
rec = json.loads(sys.stdin.read().strip())
assert rec.get('completion_id') == '${EXPECTED_COMP_ID}', f'completion_id mismatch: {rec}'
assert rec.get('task_type') == 'generation', f'task_type mismatch: {rec}'
" 2>/dev/null; then
    pass "marker includes correct completion_id when session has an assistant completion"
  else
    fail "marker missing or wrong completion_id (line: ${marker_line_c})"
  fi
else
  fail "no marker file written for session-with-completion test"
fi

# ---------------------------------------------------------------------------
# Test 5: Session with no assistant completion — marker omits completion_id
#
# When there is no assistant completion yet (e.g., the agent is still in the
# first turn), write-marker.sh must not emit an empty string for completion_id.
# The field must be absent entirely so report.sh applies Phase D fallback.
# ---------------------------------------------------------------------------
SID_NO_COMP="eeff2233-0003-0003-0003-000000000003"
SESSION_NO_COMP="${TMP_SESSIONS}/${SID_NO_COMP}.jsonl"

# Session file with only a session header and a user message (no assistant reply yet).
# Newer mtime than SESSION_WITH_COMP so write-marker.sh would pick it IF it were
# the one with most-recent assistant completion — but it has none, so mtime tie-
# breaking applies among files with no completion. To force selection of this
# session, we delete the older sessions and leave only this one.
rm -f "${FAKE_SESSION}" "${SESSION_WITH_COMP}"
# Also remove any earlier marker for WITH_COMP session to avoid cross-contamination.
rm -f "${MARKER_FILE_C}"

printf '%s\n' \
  '{"type":"session","id":"eeff2233-0003-0003-0003-000000000003","timestamp":"2026-06-02T00:00:00.000Z"}' \
  '{"type":"message","id":"user-only-001","parentId":"","timestamp":"2026-06-02T09:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"task"}]}}' \
  > "${SESSION_NO_COMP}"
touch "${SESSION_NO_COMP}"

MARKER_FILE_NC="${TMP_MARKERS}/${SID_NO_COMP}.jsonl"
rm -f "${MARKER_FILE_NC}"

run_marker "research" 2>&1 >/dev/null

if [[ -f "${MARKER_FILE_NC}" ]]; then
  marker_line_nc=$(head -1 "${MARKER_FILE_NC}")
  if echo "${marker_line_nc}" | python3 -c "
import json, sys
rec = json.loads(sys.stdin.read().strip())
assert 'completion_id' not in rec, f'completion_id should be absent: {rec}'
assert rec.get('task_type') == 'research', f'task_type mismatch: {rec}'
" 2>/dev/null; then
    pass "marker omits completion_id when session has no assistant completion"
  else
    fail "marker should not have completion_id field (line: ${marker_line_nc})"
  fi
else
  fail "no marker file written for session-without-completion test"
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
