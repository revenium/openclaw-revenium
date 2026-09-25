#!/usr/bin/env bash
# =============================================================================
# test_session_store.sh — hermetic unit tests for scripts/session-store.sh
# (Phase 19, READ-01/READ-04). Builds synthetic SQLite stores via
# tests/lib/mk-session-store.sh and exercises the store_* function surface
# directly (no report.sh involvement in this file — see test_report_jobs_argv.sh
# and test_report_argv.sh for end-to-end coverage).
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SESSION_STORE_SH="${REPO_ROOT}/scripts/session-store.sh"
MK_LIB="${SCRIPT_DIR}/lib/mk-session-store.sh"
REPORT_SH="${REPO_ROOT}/scripts/report.sh"
STUB_SH="${SCRIPT_DIR}/stub-revenium.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

declare -a TMP_DIRS=()
cleanup() { for d in "${TMP_DIRS[@]+"${TMP_DIRS[@]}"}"; do rm -rf "${d}" 2>/dev/null || true; done; }
trap cleanup EXIT

# Source the fixture library and the library under test in THIS process so
# GROUP: unit tests can call store_* functions directly.
# shellcheck source=lib/mk-session-store.sh
. "${MK_LIB}"
# shellcheck source=../scripts/session-store.sh
. "${SESSION_STORE_SH}"

new_tmp() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-sstore.XXXXXX")
  TMP_DIRS+=("${d}")
  echo "${d}"
}

# =============================================================================
# GROUP: store_db_paths
# =============================================================================
echo "--- GROUP: store_db_paths ---"

D1=$(new_tmp)
DB1="${D1}/agents/main/agent/openclaw-agent.sqlite"
mk_store "${DB1}"
mk_session "${DB1}" "aaaaaaaa-0000-0000-0000-000000000001" "agent:main:main" "" 100

out=$(REVENIUM_SESSION_STORE="${DB1}" OPENCLAW_HOME="${D1}/nonexistent" store_db_paths)
if [[ "${out}" == "${DB1}" ]]; then
  pass "store_db_paths: REVENIUM_SESSION_STORE override honored"
else
  fail "store_db_paths: override not honored (got: ${out})"
fi

D2=$(new_tmp)
DB2="${D2}/agents/dev/agent/openclaw-agent.sqlite"
mk_store "${DB2}"
mk_session "${DB2}" "aaaaaaaa-0000-0000-0000-000000000002" "agent:dev:main" "" 100
# SESSION_STORE_GLOB is fixed at source time (like common.sh's SESSIONS_DIR);
# a fresh subshell that sources the library under the new OPENCLAW_HOME
# mirrors how a real caller (which sets OPENCLAW_HOME before sourcing) works.
out=$(OPENCLAW_HOME="${D2}" bash -c "unset REVENIUM_SESSION_STORE; . '${SESSION_STORE_SH}'; store_db_paths")
if [[ "${out}" == "${DB2}" ]]; then
  pass "store_db_paths: finds a store under a non-main agent id"
else
  fail "store_db_paths: did not find non-main agent store (got: ${out})"
fi

# =============================================================================
# GROUP: store_probe
# =============================================================================
echo "--- GROUP: store_probe ---"

D3=$(new_tmp)
DB3="${D3}/agents/main/agent/openclaw-agent.sqlite"
mk_store "${DB3}"
mk_session "${DB3}" "aaaaaaaa-0000-0000-0000-000000000003" "agent:main:main" "" 100
mk_assistant_event "${DB3}" "aaaaaaaa-0000-0000-0000-000000000003" 1 "msg_r1" "run_r1" 150

if REVENIUM_SESSION_STORE="${DB3}" bash -c ". '${SESSION_STORE_SH}'; store_probe; [[ \"\${STORE_STATE}\" == READABLE ]]"; then
  pass "store_probe: READABLE for a populated store"
else
  fail "store_probe: expected READABLE for populated store"
fi

D4=$(new_tmp)
DB4="${D4}/agents/main/agent/openclaw-agent.sqlite"
mk_store "${DB4}"
mk_session "${DB4}" "aaaaaaaa-0000-0000-0000-000000000004" "agent:main:cron:x" "cron" 100
if REVENIUM_SESSION_STORE="${DB4}" bash -c ". '${SESSION_STORE_SH}'; store_probe; [[ \"\${STORE_STATE}\" == EMPTY ]]"; then
  pass "store_probe: EMPTY for a store with zero non-cron sessions"
else
  fail "store_probe: expected EMPTY for cron-only store"
fi

if REVENIUM_SESSION_STORE="${D4}/does-not-exist.sqlite" bash -c ". '${SESSION_STORE_SH}'; store_probe; [[ \"\${STORE_STATE}\" == UNREADABLE ]]"; then
  pass "store_probe: UNREADABLE for an absent file"
else
  fail "store_probe: expected UNREADABLE for absent file"
fi

D5=$(new_tmp)
DB5="${D5}/agents/main/agent/openclaw-agent.sqlite"
mkdir -p "$(dirname "${DB5}")"
sqlite3 "${DB5}" "CREATE TABLE session_nodes (session_key TEXT PRIMARY KEY, current_session_id TEXT, updated_at INTEGER, created_via TEXT); CREATE TABLE transcript_events (session_id TEXT, seq INTEGER, created_at INTEGER);"
if REVENIUM_SESSION_STORE="${DB5}" bash -c ". '${SESSION_STORE_SH}'; store_probe; [[ \"\${STORE_STATE}\" == UNREADABLE ]]"; then
  pass "store_probe: UNREADABLE for a store whose transcript_events lacks event_json"
else
  fail "store_probe: expected UNREADABLE for missing event_json column"
fi

# =============================================================================
# GROUP: store_completions (D-04 dedup adjacency)
# =============================================================================
echo "--- GROUP: store_completions ---"

D6=$(new_tmp)
DB6="${D6}/agents/main/agent/openclaw-agent.sqlite"
mk_store "${DB6}"
mk_session "${DB6}" "aaaaaaaa-0000-0000-0000-00000000000a" "agent:main:main" "" 100
mk_assistant_event "${DB6}" "aaaaaaaa-0000-0000-0000-00000000000a" 1 "msg_A" "run_1" 100
mk_assistant_event "${DB6}" "aaaaaaaa-0000-0000-0000-00000000000a" 2 "msg_A" "run_1" 100
mk_assistant_event "${DB6}" "aaaaaaaa-0000-0000-0000-00000000000a" 3 "msg_B" "run_1" 200

rows=$(REVENIUM_SESSION_STORE="${DB6}" store_completions "aaaaaaaa-0000-0000-0000-00000000000a" -1)
row_count=$(printf '%s\n' "${rows}" | grep -c . || true)
if [[ "${row_count}" -eq 2 ]]; then
  pass "store_completions: 3 rows (2 sharing responseId, 1 distinct) collapse to 2"
else
  fail "store_completions: expected 2 rows, got ${row_count}: ${rows}"
fi

first_row=$(printf '%s\n' "${rows}" | head -1)
first_seq=$(printf '%s' "${first_row}" | awk -F$'\x1f' '{print $3}')
if [[ "${first_seq}" == "1" ]]; then
  pass "store_completions: msg_A's row carries the lower seq (1)"
else
  fail "store_completions: expected msg_A row seq=1, got ${first_seq}"
fi

# =============================================================================
# GROUP: store_session_events (NULL event_json skip + seq ordering)
# =============================================================================
echo "--- GROUP: store_session_events ---"

D7=$(new_tmp)
DB7="${D7}/agents/main/agent/openclaw-agent.sqlite"
mk_store "${DB7}"
mk_session "${DB7}" "aaaaaaaa-0000-0000-0000-00000000000b" "agent:main:main" "" 100
mk_event "${DB7}" "aaaaaaaa-0000-0000-0000-00000000000b" 1 '{"type":"message","seq":1}'
# seq 2: event_json IS NULL — a zstd-compacted row (RESEARCH Pitfall 3).
sqlite3 "${DB7}" "INSERT INTO transcript_events (session_id, seq, event_json, created_at, event_zstd, event_utf8_bytes, navigation_json) VALUES ('aaaaaaaa-0000-0000-0000-00000000000b', 2, NULL, 2, X'01', 1, '{\"version\":1,\"report\":{\"kind\":\"canonical\"},\"navigation\":{},\"reset\":{},\"model\":{},\"modelBytes\":0,\"modelWithoutCheckpointBytes\":0,\"withoutCustomDataBytes\":0}');"
mk_event "${DB7}" "aaaaaaaa-0000-0000-0000-00000000000b" 3 '{"type":"message","seq":3}'

ev_rows=$(REVENIUM_SESSION_STORE="${DB7}" store_session_events "aaaaaaaa-0000-0000-0000-00000000000b" -1)
ev_count=$(printf '%s\n' "${ev_rows}" | grep -c . || true)
if [[ "${ev_count}" -eq 2 ]]; then
  pass "store_session_events: NULL event_json row (seq 2) is skipped"
else
  fail "store_session_events: expected 2 rows, got ${ev_count}: ${ev_rows}"
fi
if printf '%s\n' "${ev_rows}" | head -1 | grep -q '"seq":1' && printf '%s\n' "${ev_rows}" | tail -1 | grep -q '"seq":3'; then
  pass "store_session_events: emits rows in seq order (1 then 3)"
else
  fail "store_session_events: seq ordering wrong: ${ev_rows}"
fi

# =============================================================================
# GROUP: read-only connection enforcement (T-19-03)
# =============================================================================
echo "--- GROUP: read-only enforcement ---"

D8=$(new_tmp)
DB8="${D8}/agents/main/agent/openclaw-agent.sqlite"
mk_store "${DB8}"
mk_session "${DB8}" "aaaaaaaa-0000-0000-0000-00000000000c" "agent:main:main" "" 100

write_err=$(sqlite3 -cmd "PRAGMA busy_timeout=5000;" "file:${DB8}?mode=ro" "INSERT INTO session_nodes (session_key, current_session_id, entry_json, updated_at) VALUES ('x','y','{}',1);" 2>&1 1>/dev/null) || true
if printf '%s' "${write_err}" | grep -qi "readonly database"; then
  pass "read-only connection: an INSERT over the library's connection string is rejected"
else
  fail "read-only connection: INSERT not rejected as expected: ${write_err}"
fi

grep_count=$(grep -v '^#' "${SESSION_STORE_SH}" | grep -c 'mode=ro' || true)
if [[ "${grep_count}" -eq 1 ]]; then
  pass "exactly one connection URI (mode=ro) in session-store.sh"
else
  fail "expected exactly 1 'mode=ro' occurrence, got ${grep_count}"
fi

like_count=$(grep -v '^#' "${SESSION_STORE_SH}" | grep -c 'LIKE' || true)
if [[ "${like_count}" -eq 0 ]]; then
  pass "no substring/LIKE correlation anywhere in session-store.sh (D-19)"
else
  fail "expected 0 'LIKE' occurrences, got ${like_count}"
fi

# =============================================================================
# GROUP: store_current_session_id (D-10)
# =============================================================================
echo "--- GROUP: store_current_session_id ---"

D9=$(new_tmp)
DB9="${D9}/agents/main/agent/openclaw-agent.sqlite"
mk_store "${DB9}"
mk_session "${DB9}" "aaaaaaaa-0000-0000-0000-00000000000d" "agent:main:chat" "" 200
mk_session "${DB9}" "aaaaaaaa-0000-0000-0000-00000000000e" "agent:main:cron:x" "cron" 300
out=$(REVENIUM_SESSION_STORE="${DB9}" store_current_session_id)
if [[ "${out}" == "aaaaaaaa-0000-0000-0000-00000000000d" ]]; then
  pass "store_current_session_id: chat session wins over a newer cron session"
else
  fail "store_current_session_id: expected the chat session id, got '${out}'"
fi

D10=$(new_tmp)
DB10="${D10}/agents/main/agent/openclaw-agent.sqlite"
mk_store "${DB10}"
mk_session "${DB10}" "aaaaaaaa-0000-0000-0000-00000000000f" "agent:main:zzz" "" 200
mk_session "${DB10}" "aaaaaaaa-0000-0000-0000-000000000010" "agent:main:aaa" "" 200
stable=true
for _i in 1 2 3 4 5 6 7 8 9 10; do
  tie_out=$(REVENIUM_SESSION_STORE="${DB10}" store_current_session_id)
  [[ "${tie_out}" != "aaaaaaaa-0000-0000-0000-000000000010" ]] && stable=false
done
if [[ "${stable}" == "true" ]]; then
  pass "store_current_session_id: tie on updated_at breaks by session_key ascending, stable across 10 calls"
else
  fail "store_current_session_id: tie-break unstable (got ${tie_out} on a later call)"
fi

D11=$(new_tmp)
out=$(REVENIUM_SESSION_STORE="${D11}/no-such-store.sqlite" store_current_session_id)
if [[ -z "${out}" ]]; then
  pass "store_current_session_id: empty string (exit 0) when no store exists"
else
  fail "store_current_session_id: expected empty output, got '${out}'"
fi

# =============================================================================
# GROUP: session key <-> session id translation (Pitfall 2)
# =============================================================================
echo "--- GROUP: session key/id translation ---"

D12=$(new_tmp)
DB12="${D12}/agents/main/agent/openclaw-agent.sqlite"
mk_store "${DB12}"
mk_session "${DB12}" "aaaaaaaa-0000-0000-0000-000000000011" "agent:main:subagent:aaaaaaaa-0000-0000-0000-000000000011" "" 100

key_out=$(REVENIUM_SESSION_STORE="${DB12}" store_session_key_for_id "aaaaaaaa-0000-0000-0000-000000000011")
if [[ "${key_out}" == "agent:main:subagent:aaaaaaaa-0000-0000-0000-000000000011" ]]; then
  pass "store_session_key_for_id: returns the subagent window's session key"
else
  fail "store_session_key_for_id: expected the subagent key, got '${key_out}'"
fi

id_out=$(REVENIUM_SESSION_STORE="${DB12}" store_session_id_for_key "${key_out}")
if [[ "${id_out}" == "aaaaaaaa-0000-0000-0000-000000000011" ]]; then
  pass "store_session_id_for_key: round-trips back to the node's current_session_id"
else
  fail "store_session_id_for_key: expected the session id, got '${id_out}'"
fi

# =============================================================================
# GROUP: store_root_session_id (parent walk + cycle guard)
# =============================================================================
echo "--- GROUP: store_root_session_id ---"

D13=$(new_tmp)
DB13="${D13}/agents/main/agent/openclaw-agent.sqlite"
mk_store "${DB13}"
mk_session "${DB13}" "aaaaaaaa-0000-0000-0000-000000000020" "agent:main:root" "" 100
mk_session "${DB13}" "aaaaaaaa-0000-0000-0000-000000000021" "agent:main:child" "" 200
sqlite3 "${DB13}" "UPDATE session_windows SET parent_session_key='agent:main:root' WHERE session_id='aaaaaaaa-0000-0000-0000-000000000021';"

root_out=$(REVENIUM_SESSION_STORE="${DB13}" store_root_session_id "aaaaaaaa-0000-0000-0000-000000000021")
if [[ "${root_out}" == "aaaaaaaa-0000-0000-0000-000000000020" ]]; then
  pass "store_root_session_id: resolves a child to its recorded parent"
else
  fail "store_root_session_id: expected the root id, got '${root_out}'"
fi

# Self-referencing parent chain — must return after at most 10 hops, not loop.
D14=$(new_tmp)
DB14="${D14}/agents/main/agent/openclaw-agent.sqlite"
mk_store "${DB14}"
mk_session "${DB14}" "aaaaaaaa-0000-0000-0000-000000000030" "agent:main:self" "" 100
sqlite3 "${DB14}" "UPDATE session_windows SET parent_session_key='agent:main:self' WHERE session_id='aaaaaaaa-0000-0000-0000-000000000030';"
cycle_out=$(REVENIUM_SESSION_STORE="${DB14}" store_root_session_id "aaaaaaaa-0000-0000-0000-000000000030" 2>/dev/null)
if [[ -n "${cycle_out}" ]]; then
  pass "store_root_session_id: self-referencing parent chain terminates (returns after <=10 hops)"
else
  fail "store_root_session_id: cycle guard did not terminate/return a value"
fi

# =============================================================================
# GROUP: store_tool_calls (duration extraction)
# =============================================================================
echo "--- GROUP: store_tool_calls ---"

D15=$(new_tmp)
DB15="${D15}/agents/main/agent/openclaw-agent.sqlite"
mk_store "${DB15}"
mk_session "${DB15}" "aaaaaaaa-0000-0000-0000-000000000040" "agent:main:main" "" 100
mk_toolcall_pair "${DB15}" "aaaaaaaa-0000-0000-0000-000000000040" 1 "toolu_dur2085" "exec" 2085 false

tc_row=$(REVENIUM_SESSION_STORE="${DB15}" store_tool_calls "aaaaaaaa-0000-0000-0000-000000000040" -1)
tc_duration=$(printf '%s' "${tc_row}" | awk -F$'\x1f' '{print $4}')
if [[ "${tc_duration}" == "2085" ]]; then
  pass "store_tool_calls: duration 2085 extracted as the fourth field"
else
  fail "store_tool_calls: expected fourth field 2085, got '${tc_duration}' (row: ${tc_row})"
fi

# =============================================================================
# GROUP: injection rejection (T-19-01) across store_* functions
# =============================================================================
echo "--- GROUP: injection rejection ---"

D16=$(new_tmp)
DB16="${D16}/agents/main/agent/openclaw-agent.sqlite"
mk_store "${DB16}"
mk_session "${DB16}" "aaaaaaaa-0000-0000-0000-000000000050" "agent:main:main" "" 100
EVIL_ID="x'; DROP TABLE session_nodes; --"

for fn in store_completions store_session_events store_max_seq store_last_completion_id store_null_event_count store_tool_calls store_parent_session_id store_session_key_for_id; do
  fn_out=$(REVENIUM_SESSION_STORE="${DB16}" "${fn}" "${EVIL_ID}" 2>/dev/null)
  fn_rc=$?
  survives=$(sqlite3 "${DB16}" "SELECT count(*) FROM session_nodes;")
  if [[ -z "${fn_out}" && "${fn_rc}" -eq 0 && "${survives}" -eq 1 ]]; then
    pass "injection rejection: ${fn} emits nothing, exits 0, table intact"
  else
    fail "injection rejection: ${fn} misbehaved (out='${fn_out}' rc=${fn_rc} survives=${survives})"
  fi
done

# =============================================================================
# GROUP: store_write_status sanitization (T-19-02)
# =============================================================================
echo "--- GROUP: store_write_status ---"

D17=$(new_tmp)
READ_PATH_STATUS_FILE="${D17}/read-path-status.json"
dirty_error="$(printf 'a\nb\x1fc')"
STORE_PATHS_TRIED="" STORE_SCHEMA_MISSING="" READ_PATH_STATUS_FILE="${READ_PATH_STATUS_FILE}" store_write_status "UNREADABLE" "${dirty_error}"
if [[ -f "${READ_PATH_STATUS_FILE}" ]]; then
  error_text_value=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['error_text'])" "${READ_PATH_STATUS_FILE}")
  if [[ "${error_text_value}" != *$'\n'* && "${error_text_value}" != *$'\x1f'* ]]; then
    pass "store_write_status: error_text contains neither a newline nor a \\x1f byte"
  else
    fail "store_write_status: error_text still contains a separator byte: $(printf '%s' "${error_text_value}" | od -c | head -1)"
  fi
  state_value=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['state'])" "${READ_PATH_STATUS_FILE}")
  if [[ "${state_value}" == "UNREADABLE" ]]; then
    pass "store_write_status: state field round-trips correctly"
  else
    fail "store_write_status: expected state UNREADABLE, got '${state_value}'"
  fi
else
  fail "store_write_status: did not write ${READ_PATH_STATUS_FILE}"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""
[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0
