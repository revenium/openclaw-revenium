#!/usr/bin/env bash
# =============================================================================
# test_write_marker.sh — Integration tests for write-marker.sh (METER-02, D-10)
#
# Rebuilt on the SQLite session-store fixture harness (tests/lib/mk-session-store.sh)
# for Phase 19 plan 19-06, which ports write-marker.sh's current-session
# resolution off the transcript-filename glob onto
# scripts/session-store.sh :: store_current_session_id / store_last_completion_id.
#
# Tests:
#   1. Valid taxonomy label appends an ISO8601 marker line and exits 0;
#      session with no completions omits the completion_id field
#   2. Unknown label exits non-zero and writes no marker line
#   3. Two rapid invocations yield two lines (flock + O_APPEND, no corruption)
#   4. Session with two completions: marker's completion_id is the responseId
#      of the LATEST usage-bearing assistant event (highest seq)
#   5. A cron session newer than a chat session: marker files under the chat
#      (non-cron) session, never the cron session
#   6. No non-cron session anywhere in the store: pseudo-id fallback fires
#   7. Unknown task-type is still rejected even when store resolution would
#      otherwise succeed (no marker escapes under any session)
#   8. Path-traversal guard rejects a resolved id that does not match the
#      permitted id/pseudo-id shape
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WRITE_MARKER="${REPO_ROOT}/scripts/write-marker.sh"
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
TMP_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-wm-home.XXXXXX")
TMP_STATE="${TMP_HOME}/skills/revenium"
TMP_MARKERS="${TMP_STATE}/markers"
TMP_TAXONOMY="${TMP_STATE}/task-taxonomy.json"
DB="${TMP_HOME}/agents/main/agent/openclaw-agent.sqlite"

mkdir -p "${TMP_STATE}"

# Seed taxonomy (copy from repo root)
cp "${REPO_ROOT}/task-taxonomy.json" "${TMP_TAXONOMY}"

cleanup() {
  rm -rf "${TMP_HOME}"
}
trap cleanup EXIT

# Helper: run write-marker.sh with the tmp OPENCLAW_HOME
run_marker() {
  OPENCLAW_HOME="${TMP_HOME}" bash "${WRITE_MARKER}" "$@"
}

# ---------------------------------------------------------------------------
# Test 1: Valid label, session with no completions yet — exits 0, prints
# "marker written: <path>", appends one ISO8601 line omitting completion_id.
# ---------------------------------------------------------------------------
SID1="aabbccdd-0001-0001-0001-000000000001"
mk_store "${DB}"
mk_session "${DB}" "${SID1}" "agent:main:main" "" 100

output=$(run_marker "research" 2>&1)
exit_code=$?

if [[ "${exit_code}" -eq 0 ]]; then
  pass "valid label (research) exits 0"
else
  fail "valid label (research) exits non-zero (got ${exit_code}, output: ${output})"
fi

if echo "${output}" | grep -q "marker written:"; then
  pass "valid label prints 'marker written:'"
else
  fail "valid label output missing 'marker written:' (got: ${output})"
fi

MARKER_FILE="${TMP_MARKERS}/${SID1}.jsonl"
if [[ -f "${MARKER_FILE}" ]]; then
  pass "marker file created at expected path (store-resolved session id)"
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
  if echo "${marker_line}" | python3 -c "
import json, sys, re
line = sys.stdin.read().strip()
rec = json.loads(line)
assert rec.get('task_type') == 'research', f'bad task_type: {rec}'
assert re.match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$', rec.get('ts','')), f'bad ts: {rec}'
assert 'completion_id' not in rec, f'completion_id should be absent (no completions in store): {rec}'
" 2>/dev/null; then
    pass "marker line has ISO8601 ts, task_type=research, and no completion_id"
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
run_marker "bogus_label_not_in_taxonomy" >/dev/null 2>&1 && bad_exit=$? || bad_exit=$?

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
rm -f "${MARKER_FILE}"

run_marker "generation" >/dev/null 2>&1
run_marker "analysis" >/dev/null 2>&1

two_count=$(wc -l < "${MARKER_FILE}" | tr -d ' ')
if [[ "${two_count}" -eq 2 ]]; then
  pass "two invocations yield exactly 2 lines"
else
  fail "two invocations yielded ${two_count} lines (expected 2)"
fi

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
# Test 4 (behavior): session with TWO completions — marker's completion_id
# equals the responseId of the LATEST usage-bearing assistant event (highest
# seq), resolved via store_last_completion_id.
# ---------------------------------------------------------------------------
SID4="ccddee11-0002-0002-0002-000000000002"
mk_store "${DB}"
mk_session "${DB}" "${SID4}" "agent:main:main" "" 100
mk_assistant_event "${DB}" "${SID4}" 0 "msg_wm_001" "run-4" 10
mk_assistant_event "${DB}" "${SID4}" 1 "msg_wm_002" "run-4" 20

MARKER_FILE_4="${TMP_MARKERS}/${SID4}.jsonl"
rm -f "${MARKER_FILE_4}"

run_marker "generation" >/dev/null 2>&1

if [[ -f "${MARKER_FILE_4}" ]]; then
  marker_line_4=$(head -1 "${MARKER_FILE_4}")
  if echo "${marker_line_4}" | python3 -c "
import json, sys
rec = json.loads(sys.stdin.read().strip())
assert rec.get('completion_id') == 'msg_wm_002', f'completion_id mismatch: {rec}'
assert rec.get('task_type') == 'generation', f'task_type mismatch: {rec}'
" 2>/dev/null; then
    pass "marker's completion_id is the responseId of the latest of two completions (msg_wm_002)"
  else
    fail "marker missing or wrong completion_id (line: ${marker_line_4})"
  fi
else
  fail "no marker file written for two-completions session test"
fi

# ---------------------------------------------------------------------------
# Test 5 (behavior): a cron session newer than a chat session — the marker
# files under the chat (non-cron) session, never the cron session.
# ---------------------------------------------------------------------------
CHAT_SID5="aa000000-0005-0005-0005-000000000005"
CRON_SID5="bb000000-0005-0005-0005-000000000006"
mk_store "${DB}"
mk_session "${DB}" "${CHAT_SID5}" "agent:main:chat" "" 100
mk_session "${DB}" "${CRON_SID5}" "agent:main:cron:x" "cron" 999

MARKER_FILE_CHAT5="${TMP_MARKERS}/${CHAT_SID5}.jsonl"
MARKER_FILE_CRON5="${TMP_MARKERS}/${CRON_SID5}.jsonl"
rm -f "${MARKER_FILE_CHAT5}" "${MARKER_FILE_CRON5}"

run_marker "research" >/dev/null 2>&1

if [[ -f "${MARKER_FILE_CHAT5}" && ! -f "${MARKER_FILE_CRON5}" ]]; then
  pass "marker files under the chat session, never the newer cron session"
else
  fail "expected marker under ${CHAT_SID5} only (chat=$([ -f "${MARKER_FILE_CHAT5}" ] && echo yes || echo no), cron=$([ -f "${MARKER_FILE_CRON5}" ] && echo yes || echo no))"
fi

# ---------------------------------------------------------------------------
# Test 6 (behavior): no non-cron session anywhere in the store — the
# pseudo-id fallback still fires and the marker is still written.
# ---------------------------------------------------------------------------
CRON_ONLY_SID6="cc000000-0006-0006-0006-000000000007"
mk_store "${DB}"
mk_session "${DB}" "${CRON_ONLY_SID6}" "agent:main:cron:y" "cron" 100

# Clear any previously-written pseudo-* markers from earlier runs.
rm -f "${TMP_MARKERS}"/pseudo-*.jsonl

output6=$(run_marker "research" 2>&1)
exit6=$?

if [[ "${exit6}" -eq 0 ]] && echo "${output6}" | grep -q "marker written:"; then
  pass "pseudo-id fallback still writes a marker when no non-cron session exists"
else
  fail "pseudo-id fallback did not write a marker (exit=${exit6}, output: ${output6})"
fi

pseudo_files=("${TMP_MARKERS}"/pseudo-*.jsonl)
if [[ -e "${pseudo_files[0]}" ]]; then
  pass "marker filed under a pseudo-<timestamp> id, not the cron session"
else
  fail "no pseudo-*.jsonl marker file found"
fi

# ---------------------------------------------------------------------------
# Test 7 (behavior): unknown task-type is still rejected even when store
# resolution would otherwise succeed — no marker escapes under any session.
# ---------------------------------------------------------------------------
SID7="dd000000-0007-0007-0007-000000000008"
mk_store "${DB}"
mk_session "${DB}" "${SID7}" "agent:main:main" "" 100
MARKER_FILE_7="${TMP_MARKERS}/${SID7}.jsonl"
rm -f "${MARKER_FILE_7}"

bad_exit7=0
run_marker "another_bogus_label" >/dev/null 2>&1 && bad_exit7=$? || bad_exit7=$?

if [[ "${bad_exit7}" -ne 0 && ! -f "${MARKER_FILE_7}" ]]; then
  pass "unknown task_type rejected — no marker written under the resolved session"
else
  fail "unknown task_type should reject with no marker (exit=${bad_exit7}, marker exists: $([ -f "${MARKER_FILE_7}" ] && echo yes || echo no))"
fi

# ---------------------------------------------------------------------------
# Test 8 (behavior): path-traversal guard rejects a resolved id that does not
# match the permitted id/pseudo-id shape (T-19-19). Simulates a compromised
# store row rather than trusting store_current_session_id's output blindly.
# ---------------------------------------------------------------------------
mk_store "${DB}"
mk_session "${DB}" "../../etc/passwd" "agent:main:evil" "" 100

output8=$(run_marker "research" 2>&1)
exit8=$?

if [[ "${exit8}" -ne 0 ]] && echo "${output8}" | grep -qi "unsafe sid"; then
  pass "path-traversal guard rejects an unsafe resolved session id"
else
  fail "path-traversal guard did not reject unsafe sid (exit=${exit8}, output: ${output8})"
fi

if [[ ! -e "${TMP_MARKERS}/../../etc/passwd.jsonl" ]] && ! find "${TMP_MARKERS}/.." -name "passwd.jsonl" 2>/dev/null | grep -q .; then
  pass "no marker file written for the unsafe resolved id"
else
  fail "a marker file was written despite the unsafe resolved id"
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
