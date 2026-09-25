#!/usr/bin/env bash
# =============================================================================
# test_read_path_e2e.sh — Phase 19 assembled-system hermetic test.
#
# Every plan in this phase (19-01 through 19-06) proved ONE seam in isolation:
# the SQLite store surface, the sidecar hooks, the toolCall/completion scans,
# the root-session resolver, the marker resolvers. Nothing until now has
# proven they COMPOSE — a mismatched identifier or a mismatched sidecar path
# is a silent failure by construction in every one of those per-seam suites,
# because each one builds its own consistent fixture. This suite builds ONE
# synthetic store + ONE hand-written sidecar file and drives report.sh
# through every layer in a single tick, exactly as plan 19-07 Task 1
# prescribes.
#
# GROUP map:
#   GROUP1  — sidecar-primary path: one completion + one tool call on a
#             subagent session linked to a root via the hand-written sidecar.
#             Exactly one metered completion, one tool-event, both attributed
#             to the ROOT session. Also proves the tick never writes a halt
#             record and never touches guardrail-status.json.
#   GROUP1B — the SAME store, ticked again unchanged: zero additional
#             completion/tool-event CLI calls (ledger-gated idempotency).
#   GROUP2  — sidecar removed entirely; the store's own
#             session_windows.parent_session_key column is the only source of
#             parentage. Root attribution still holds (D-08 fallback).
#   GROUP3  — neither the sidecar nor the store's parentage columns answer.
#             The session must attribute to itself (fail-open, D-09).
#   GROUP4  — a store missing a required schema column (READ-04 UNREADABLE):
#             the tick exits non-zero and the missing column name is recorded
#             in read-path-status.json.
#   GROUP5  — WR-01 blast radius: a two-agent host where agents/main is
#             healthy and agents/dev is schema-drifted. The healthy store's
#             completion is still metered (exit 0), the log names the
#             drifted store, and read-path-status.json records READABLE with
#             unhealthy_paths naming agents/dev. A second sub-case with BOTH
#             agents drifted still classifies UNREADABLE and exits non-zero.
#
# Fixture construction note: the sidecar file in every GROUP is written BY
# HAND, in exactly the shape plan 19-03 pinned (plugin/src/gate.js ::
# appendSidecarEdge/readSidecarEdges) — never by calling the plugin or
# get-root-session-id.py's own writer. This is the contract check between the
# plugin's writer and the resolver's reader: if either drifts, this test
# breaks even though each side's own unit tests still pass.
#
# SECURITY (T-04-09 / V5): this test never `eval`s or string-interpolates
# captured argv. All argv assertions use grep/awk on the argv capture file.
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
# count_grep <pattern> <file> — count of matching lines (0 on no match/no file).
# ---------------------------------------------------------------------------
count_grep() {
  local pattern="$1" file="${2:-/dev/null}"
  local r
  r=$(grep -c "${pattern}" "${file}" 2>/dev/null; exit 0)
  echo "${r:-0}"
}

# ---------------------------------------------------------------------------
# count_adjacent <token1> <token2> <file> — count of consecutive-line pairs.
# ---------------------------------------------------------------------------
count_adjacent() {
  local t1="$1" t2="$2" afile="$3"
  awk -v t1="${t1}" -v t2="${t2}" '
    prev==t1 && $0==t2 {count++}
    {prev=$0}
    END {print count+0}
  ' "${afile}" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# count_triplet <token1> <token2> <token3> <file> — count of consecutive
# 3-line runs. Used to subtract capability-probe invocations (e.g.
# "meter completion --help") from a real-call count.
# ---------------------------------------------------------------------------
count_triplet() {
  local t1="$1" t2="$2" t3="$3" afile="$4"
  awk -v t1="${t1}" -v t2="${t2}" -v t3="${t3}" '
    p2==t1 && p1==t2 && $0==t3 {count++}
    {p2=p1; p1=$0}
    END {print count+0}
  ' "${afile}" 2>/dev/null || echo 0
}

# real_calls <verb1> <verb2> <file> — adjacent-pair count minus the
# "<verb1> <verb2> --help" capability-probe triplet, i.e. only real
# invocations (e.g. real_calls meter completion / real_calls meter tool-event).
real_calls() {
  local v1="$1" v2="$2" afile="$3"
  echo $(( $(count_adjacent "${v1}" "${v2}" "${afile}") - $(count_triplet "${v1}" "${v2}" "--help" "${afile}") ))
}

# ---------------------------------------------------------------------------
# make_e2e_home — a fresh tmp OPENCLAW_HOME at the real
# agents/<agentId>/agent/openclaw-agent.sqlite layout, with
# skills/revenium/scripts/{get-root-session-id.py,session-store.sh} symlinked
# from the repo (get-root-session-id.py's store-CLI subprocess call is
# resolved relative to ITS OWN file path — see scripts/get-root-session-id.py
# :: _store_cli — so both must be deployed side by side, exactly mirroring
# a real skill install and the pattern tests/test_report_jobs_argv.sh and
# tests/test_guardrail_argv.sh already use).
# ---------------------------------------------------------------------------
make_e2e_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-e2e-home.XXXXXX")
  mkdir -p "${d}/skills/revenium/markers" "${d}/skills/revenium/scripts" "${d}/agents/main/agent"
  ln -sf "${REPO_ROOT}/scripts/get-root-session-id.py" \
         "${d}/skills/revenium/scripts/get-root-session-id.py"
  ln -sf "${REPO_ROOT}/scripts/session-store.sh" \
         "${d}/skills/revenium/scripts/session-store.sh"
  echo '{}' > "${d}/revenium-offsets.json"
  touch "${d}/revenium-reported.ledger" "${d}/revenium-jobs.ledger" \
        "${d}/revenium-tools.ledger" "${d}/revenium-tool-events.ledger"
  echo '{"organizationName":"TestOrg"}' > "${d}/skills/revenium/config.json"
  echo "${d}"
}

db_for() { echo "$1/agents/main/agent/openclaw-agent.sqlite"; }

# ---------------------------------------------------------------------------
# write_sidecar_edge <home> <child_key> <parent_key> [run_id]
#   Hand-written, independent of plugin/src/gate.js :: appendSidecarEdge —
#   this is the contract check between that writer and the resolver's reader
#   (scripts/get-root-session-id.py :: _read_sidecar_edges), so it must NOT
#   call either. Schema copied verbatim from 19-03-SUMMARY.md's own record
#   shape: event, childSessionKey, parentSessionKey, runId, capturedAt.
# ---------------------------------------------------------------------------
write_sidecar_edge() {
  local home="$1" child_key="$2" parent_key="$3" run_id="${4:-run-e2e}"
  mkdir -p "${home}/skills/revenium"
  printf '%s\n' "{\"event\":\"spawned\",\"childSessionKey\":\"${child_key}\",\"parentSessionKey\":\"${parent_key}\",\"runId\":\"${run_id}\",\"capturedAt\":\"2026-09-25T00:00:00.000Z\"}" \
    >> "${home}/skills/revenium/subagent-edges.jsonl"
}

# ---------------------------------------------------------------------------
# build_broken_store <db> — a store missing session_nodes.session_key (one of
# the four columns store_probe's schema-drift check requires), so store_probe
# must classify it UNREADABLE and name the missing column (READ-04).
# ---------------------------------------------------------------------------
build_broken_store() {
  local db="$1"
  mkdir -p "$(dirname "${db}")"
  rm -f "${db}"
  _mk_write "${db}" "
CREATE TABLE session_nodes (
  current_session_id TEXT,
  entry_json TEXT,
  entry_valid INTEGER DEFAULT 0,
  updated_at INTEGER,
  created_via TEXT
);
CREATE TABLE transcript_events (
  session_id TEXT,
  seq INTEGER,
  event_json TEXT,
  created_at INTEGER
);
"
}

# ---------------------------------------------------------------------------
# Fake HOME setup: stub on PATH via fake HOME/.local/bin/revenium.
# ---------------------------------------------------------------------------
TMP_FAKE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-e2e-fakehome.XXXXXX")
TMP_LOCAL_BIN="${TMP_FAKE_HOME}/.local/bin"
mkdir -p "${TMP_LOCAL_BIN}"
ln -sf "${STUB_SH}" "${TMP_LOCAL_BIN}/revenium"

declare -a TMP_HOMES=()
declare -a TMP_ARGV_FILES=()

cleanup() {
  local d
  for d in "${TMP_HOMES[@]+"${TMP_HOMES[@]}"}"; do
    rm -rf "${d}" 2>/dev/null || true
  done
  for d in "${TMP_ARGV_FILES[@]+"${TMP_ARGV_FILES[@]}"}"; do
    rm -f "${d}" 2>/dev/null || true
  done
  rm -rf "${TMP_FAKE_HOME}" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# run_tick <openclaw_home> <argv_file>
#   Runs report.sh with the stub on PATH, WITHOUT swallowing the exit code
#   (unlike the other report.sh test harnesses' run_report helper) — GROUP4
#   needs the real non-zero exit status from an UNREADABLE store.
# ---------------------------------------------------------------------------
run_tick() {
  local home="$1" argv_file="$2"
  STUB_REVENIUM_ARGV_FILE="${argv_file}" \
  OPENCLAW_HOME="${home}" \
  HOME="${TMP_FAKE_HOME}" \
  bash "${REPORT_SH}" >"${home}/.tick-out.log" 2>&1
}

# ===========================================================================
# GROUP1: sidecar-primary path — one store, one tick, every layer
# ===========================================================================
echo "--- GROUP1: sidecar-primary root attribution, one completion + one tool call ---"

ROOT_SID_A="a1000000-aaaa-aaaa-aaaa-a10000000001"
SUB_SID_A="a1000000-bbbb-bbbb-bbbb-a10000000002"
ROOT_KEY_A="agent:main:root-a"
SUB_KEY_A="agent:main:sub-a"

HOME_A=$(make_e2e_home)
TMP_HOMES+=("${HOME_A}")
DB_A=$(db_for "${HOME_A}")
mk_store "${DB_A}"
mk_session "${DB_A}" "${ROOT_SID_A}" "${ROOT_KEY_A}" "" 100
mk_session "${DB_A}" "${SUB_SID_A}" "${SUB_KEY_A}" "" 200
mk_assistant_event "${DB_A}" "${SUB_SID_A}" 0 "resp-sub-a-001" "run-a" 111 "claude-sonnet-4-6" "2026-09-25T01:00:00.000Z" "stop"
mk_toolcall_pair "${DB_A}" "${SUB_SID_A}" 1 "toolu-e2e-a-001" "read" 123 "false"
write_sidecar_edge "${HOME_A}" "${SUB_KEY_A}" "${ROOT_KEY_A}"

ARGV_A1=$(mktemp "${TMPDIR:-/tmp}/test-e2e-argv-a1.XXXXXX")
TMP_ARGV_FILES+=("${ARGV_A1}")
run_tick "${HOME_A}" "${ARGV_A1}"
RC_A1=$?

if [[ "${RC_A1}" -eq 0 ]]; then
  pass "GROUP1: tick over the sidecar-linked fixture exits 0"
else
  fail "GROUP1: tick exited ${RC_A1} (expected 0) — see ${HOME_A}/.tick-out.log"
fi

TX_COUNT_A1=$(count_grep '^TX:' "${HOME_A}/revenium-reported.ledger")
if [[ "${TX_COUNT_A1}" -eq 1 ]]; then
  pass "GROUP1: exactly one metered completion (TX ledger)"
else
  fail "GROUP1: expected 1 TX ledger line, got ${TX_COUNT_A1}"
fi

TOOLEV_COUNT_A1=$(count_grep '^TOOLEV:' "${HOME_A}/revenium-tool-events.ledger")
if [[ "${TOOLEV_COUNT_A1}" -eq 1 ]]; then
  pass "GROUP1: exactly one tool-event (TOOLEV ledger)"
else
  fail "GROUP1: expected 1 TOOLEV ledger line, got ${TOOLEV_COUNT_A1}"
fi

REAL_COMPLETIONS_A1=$(real_calls "meter" "completion" "${ARGV_A1}")
if [[ "${REAL_COMPLETIONS_A1}" -eq 1 ]]; then
  pass "GROUP1: exactly one real 'meter completion' call (capability probe excluded)"
else
  fail "GROUP1: expected 1 real meter-completion call, got ${REAL_COMPLETIONS_A1}"
fi

REAL_TOOLEVENTS_A1=$(real_calls "meter" "tool-event" "${ARGV_A1}")
if [[ "${REAL_TOOLEVENTS_A1}" -eq 1 ]]; then
  pass "GROUP1: exactly one real 'meter tool-event' call (capability probe excluded)"
else
  fail "GROUP1: expected 1 real meter-tool-event call, got ${REAL_TOOLEVENTS_A1}"
fi

ROOT_AGENT_COUNT_A1=$(count_adjacent "--agent" "openclaw-${ROOT_SID_A}" "${ARGV_A1}")
if [[ "${ROOT_AGENT_COUNT_A1}" -eq 2 ]]; then
  pass "GROUP1: both the completion and the tool-event attribute --agent to the ROOT session"
else
  fail "GROUP1: expected 2 occurrences of --agent openclaw-${ROOT_SID_A}, got ${ROOT_AGENT_COUNT_A1}"
fi

SUB_AGENT_COUNT_A1=$(count_adjacent "--agent" "openclaw-${SUB_SID_A}" "${ARGV_A1}")
if [[ "${SUB_AGENT_COUNT_A1}" -eq 0 ]]; then
  pass "GROUP1: the subagent's OWN id is never used as --agent"
else
  fail "GROUP1: subagent id leaked into --agent (${SUB_AGENT_COUNT_A1} occurrence(s))"
fi

STATUS_A1="${HOME_A}/skills/revenium/read-path-status.json"
if [[ -f "${STATUS_A1}" ]] && grep -qF '"state": "READABLE"' "${STATUS_A1}"; then
  pass "GROUP1: read-path-status.json records READABLE"
else
  fail "GROUP1: read-path-status.json missing or not READABLE (${STATUS_A1})"
fi

if [[ ! -e "${HOME_A}/skills/revenium/guardrail-status.json" ]]; then
  pass "GROUP1: the tick never creates/touches guardrail-status.json"
else
  fail "GROUP1: guardrail-status.json was unexpectedly created"
fi

if grep -q '^JOB:halt:' "${HOME_A}/revenium-jobs.ledger" 2>/dev/null; then
  fail "GROUP1: the tick wrote a halt record with no halt condition present"
else
  pass "GROUP1: the tick never writes a halt record"
fi

# ===========================================================================
# GROUP1B: the SAME store, ticked again unchanged — idempotency
# ===========================================================================
echo ""
echo "--- GROUP1B: second tick over the unchanged fixture — zero additional calls ---"

ARGV_A2=$(mktemp "${TMPDIR:-/tmp}/test-e2e-argv-a2.XXXXXX")
TMP_ARGV_FILES+=("${ARGV_A2}")
run_tick "${HOME_A}" "${ARGV_A2}"
RC_A2=$?

if [[ "${RC_A2}" -eq 0 ]]; then
  pass "GROUP1B: second tick over the unchanged fixture exits 0"
else
  fail "GROUP1B: second tick exited ${RC_A2} (expected 0) — see ${HOME_A}/.tick-out.log"
fi

TX_COUNT_A2=$(count_grep '^TX:' "${HOME_A}/revenium-reported.ledger")
if [[ "${TX_COUNT_A2}" -eq 1 ]]; then
  pass "GROUP1B: TX ledger still holds exactly one entry (no double-billing)"
else
  fail "GROUP1B: TX ledger grew to ${TX_COUNT_A2} entries after an unchanged second tick"
fi

TOOLEV_COUNT_A2=$(count_grep '^TOOLEV:' "${HOME_A}/revenium-tool-events.ledger")
if [[ "${TOOLEV_COUNT_A2}" -eq 1 ]]; then
  pass "GROUP1B: TOOLEV ledger still holds exactly one entry (no double-billing)"
else
  fail "GROUP1B: TOOLEV ledger grew to ${TOOLEV_COUNT_A2} entries after an unchanged second tick"
fi

REAL_COMPLETIONS_A2=$(real_calls "meter" "completion" "${ARGV_A2}")
if [[ "${REAL_COMPLETIONS_A2}" -eq 0 ]]; then
  pass "GROUP1B: zero additional real 'meter completion' calls on the second tick"
else
  fail "GROUP1B: expected 0 additional meter-completion calls, got ${REAL_COMPLETIONS_A2}"
fi

REAL_TOOLEVENTS_A2=$(real_calls "meter" "tool-event" "${ARGV_A2}")
if [[ "${REAL_TOOLEVENTS_A2}" -eq 0 ]]; then
  pass "GROUP1B: zero additional real 'meter tool-event' calls on the second tick"
else
  fail "GROUP1B: expected 0 additional meter-tool-event calls, got ${REAL_TOOLEVENTS_A2}"
fi

# ===========================================================================
# GROUP2: sidecar removed — store's own parentage column is the only source
# ===========================================================================
echo ""
echo "--- GROUP2: no sidecar — session_windows.parent_session_key still attributes to root ---"

ROOT_SID_B="b2000000-aaaa-aaaa-aaaa-b20000000001"
SUB_SID_B="b2000000-bbbb-bbbb-bbbb-b20000000002"
ROOT_KEY_B="agent:main:root-b"
SUB_KEY_B="agent:main:sub-b"

HOME_B=$(make_e2e_home)
TMP_HOMES+=("${HOME_B}")
DB_B=$(db_for "${HOME_B}")
mk_store "${DB_B}"
mk_session "${DB_B}" "${ROOT_SID_B}" "${ROOT_KEY_B}" "" 100
mk_session "${DB_B}" "${SUB_SID_B}" "${SUB_KEY_B}" "" 200
mk_assistant_event "${DB_B}" "${SUB_SID_B}" 0 "resp-sub-b-001" "run-b" 111 "claude-sonnet-4-6" "2026-09-25T01:00:00.000Z" "stop"
# No sidecar file at all in HOME_B — the store's own parent_session_key
# column (session_windows) is the ONLY source. mk-session-store.sh has no
# convenience wrapper for this column, so it is set directly via the same
# read-write connection mk_session itself uses.
_mk_write "${DB_B}" "UPDATE session_windows SET parent_session_key='${ROOT_KEY_B}' WHERE session_id='${SUB_SID_B}';"

ARGV_B=$(mktemp "${TMPDIR:-/tmp}/test-e2e-argv-b.XXXXXX")
TMP_ARGV_FILES+=("${ARGV_B}")
run_tick "${HOME_B}" "${ARGV_B}"
RC_B=$?

if [[ "${RC_B}" -eq 0 ]]; then
  pass "GROUP2: tick over the store-parentage-only fixture exits 0"
else
  fail "GROUP2: tick exited ${RC_B} (expected 0) — see ${HOME_B}/.tick-out.log"
fi

TX_COUNT_B=$(count_grep '^TX:' "${HOME_B}/revenium-reported.ledger")
if [[ "${TX_COUNT_B}" -eq 1 ]]; then
  pass "GROUP2: exactly one metered completion"
else
  fail "GROUP2: expected 1 TX ledger line, got ${TX_COUNT_B}"
fi

ROOT_AGENT_COUNT_B=$(count_adjacent "--agent" "openclaw-${ROOT_SID_B}" "${ARGV_B}")
if [[ "${ROOT_AGENT_COUNT_B}" -eq 1 ]]; then
  pass "GROUP2: with no sidecar present, the store's parent_session_key column still resolves to the ROOT session"
else
  fail "GROUP2: expected 1 occurrence of --agent openclaw-${ROOT_SID_B}, got ${ROOT_AGENT_COUNT_B}"
fi

SUB_AGENT_COUNT_B=$(count_adjacent "--agent" "openclaw-${SUB_SID_B}" "${ARGV_B}")
if [[ "${SUB_AGENT_COUNT_B}" -eq 0 ]]; then
  pass "GROUP2: the subagent's own id is never used as --agent when the store fallback answers"
else
  fail "GROUP2: subagent id leaked into --agent (${SUB_AGENT_COUNT_B} occurrence(s))"
fi

# ===========================================================================
# GROUP3: neither source answers — falls open to the session's own id
# ===========================================================================
echo ""
echo "--- GROUP3: neither sidecar nor store parentage — attributes to the subagent itself ---"

SUB_SID_C="c3000000-cccc-cccc-cccc-c30000000003"
SUB_KEY_C="agent:main:sub-c"

HOME_C=$(make_e2e_home)
TMP_HOMES+=("${HOME_C}")
DB_C=$(db_for "${HOME_C}")
mk_store "${DB_C}"
mk_session "${DB_C}" "${SUB_SID_C}" "${SUB_KEY_C}" "" 100
mk_assistant_event "${DB_C}" "${SUB_SID_C}" 0 "resp-sub-c-001" "run-c" 111 "claude-sonnet-4-6" "2026-09-25T01:00:00.000Z" "stop"
# No sidecar edge anywhere and no store parentage column set — neither
# source has an answer, so get_root_session_id must fail open to the
# session's own id (D-09).

ARGV_C=$(mktemp "${TMPDIR:-/tmp}/test-e2e-argv-c.XXXXXX")
TMP_ARGV_FILES+=("${ARGV_C}")
run_tick "${HOME_C}" "${ARGV_C}"
RC_C=$?

if [[ "${RC_C}" -eq 0 ]]; then
  pass "GROUP3: tick over the unlinked session exits 0"
else
  fail "GROUP3: tick exited ${RC_C} (expected 0) — see ${HOME_C}/.tick-out.log"
fi

TX_COUNT_C=$(count_grep '^TX:' "${HOME_C}/revenium-reported.ledger")
if [[ "${TX_COUNT_C}" -eq 1 ]]; then
  pass "GROUP3: exactly one metered completion"
else
  fail "GROUP3: expected 1 TX ledger line, got ${TX_COUNT_C}"
fi

SELF_AGENT_COUNT_C=$(count_adjacent "--agent" "openclaw-${SUB_SID_C}" "${ARGV_C}")
if [[ "${SELF_AGENT_COUNT_C}" -eq 1 ]]; then
  pass "GROUP3: with neither source answering, the session attributes to itself"
else
  fail "GROUP3: expected --agent openclaw-${SUB_SID_C} exactly once, got ${SELF_AGENT_COUNT_C}"
fi

# ===========================================================================
# GROUP4: a store missing a required schema column — READ-04 UNREADABLE
# ===========================================================================
echo ""
echo "--- GROUP4: schema-missing store — non-zero exit, missing column named in status file ---"

HOME_D=$(make_e2e_home)
TMP_HOMES+=("${HOME_D}")
DB_D=$(db_for "${HOME_D}")
build_broken_store "${DB_D}"

ARGV_D=$(mktemp "${TMPDIR:-/tmp}/test-e2e-argv-d.XXXXXX")
TMP_ARGV_FILES+=("${ARGV_D}")
run_tick "${HOME_D}" "${ARGV_D}"
RC_D=$?

if [[ "${RC_D}" -ne 0 ]]; then
  pass "GROUP4: tick against a schema-missing store exits non-zero"
else
  fail "GROUP4: tick exited 0 against a schema-missing store (expected non-zero)"
fi

STATUS_D="${HOME_D}/skills/revenium/read-path-status.json"
if [[ -f "${STATUS_D}" ]] && grep -qF 'session_nodes.session_key' "${STATUS_D}" && grep -qF '"state": "UNREADABLE"' "${STATUS_D}"; then
  pass "GROUP4: read-path-status.json records UNREADABLE and names the missing column (session_nodes.session_key)"
else
  fail "GROUP4: read-path-status.json missing, not UNREADABLE, or does not name the missing column (${STATUS_D})"
fi

TX_COUNT_D=$(count_grep '^TX:' "${HOME_D}/revenium-reported.ledger")
if [[ "${TX_COUNT_D}" -eq 0 ]]; then
  pass "GROUP4: no completion is metered when the store is unreadable"
else
  fail "GROUP4: expected 0 TX ledger lines against an unreadable store, got ${TX_COUNT_D}"
fi

# ===========================================================================
# GROUP5: two-agent host, one healthy + one drifted — WR-01 blast-radius fix
# ===========================================================================
echo ""
echo "--- GROUP5: two-agent host — a drifted agents/dev store no longer blacks out agents/main ---"

ROOT_SID_E="e5000000-aaaa-aaaa-aaaa-e50000000001"

HOME_E=$(make_e2e_home)
TMP_HOMES+=("${HOME_E}")
DB_E_MAIN=$(db_for "${HOME_E}")
mk_store "${DB_E_MAIN}"
mk_session "${DB_E_MAIN}" "${ROOT_SID_E}" "agent:main:root-e" "" 100
mk_assistant_event "${DB_E_MAIN}" "${ROOT_SID_E}" 0 "resp-e-001" "run-e" 111 "claude-sonnet-4-6" "2026-09-25T01:00:00.000Z" "stop"

DB_E_DEV="${HOME_E}/agents/dev/agent/openclaw-agent.sqlite"
build_broken_store "${DB_E_DEV}"

ARGV_E=$(mktemp "${TMPDIR:-/tmp}/test-e2e-argv-e.XXXXXX")
TMP_ARGV_FILES+=("${ARGV_E}")
run_tick "${HOME_E}" "${ARGV_E}"
RC_E=$?

if [[ "${RC_E}" -eq 0 ]]; then
  pass "GROUP5: tick exits 0 with a drifted sibling store present"
else
  fail "GROUP5: tick exited ${RC_E} (expected 0) — see ${HOME_E}/.tick-out.log"
fi

TX_COUNT_E=$(count_grep '^TX:' "${HOME_E}/revenium-reported.ledger")
if [[ "${TX_COUNT_E}" -eq 1 ]]; then
  pass "GROUP5: exactly one metered completion from the healthy agents/main store"
else
  fail "GROUP5: expected 1 TX ledger line, got ${TX_COUNT_E}"
fi

REAL_COMPLETIONS_E=$(real_calls "meter" "completion" "${ARGV_E}")
if [[ "${REAL_COMPLETIONS_E}" -eq 1 ]]; then
  pass "GROUP5: exactly one real 'meter completion' call (capability probe excluded)"
else
  fail "GROUP5: expected 1 real meter-completion call, got ${REAL_COMPLETIONS_E}"
fi

if grep -q "agents/dev" "${HOME_E}/.tick-out.log"; then
  pass "GROUP5: the tick's log output names the drifted agents/dev store"
else
  fail "GROUP5: the drifted store's path was not named in the tick log"
fi

STATUS_E="${HOME_E}/skills/revenium/read-path-status.json"
if [[ -f "${STATUS_E}" ]] && grep -qF '"state": "READABLE"' "${STATUS_E}"; then
  pass "GROUP5: read-path-status.json records READABLE despite the drifted sibling"
else
  fail "GROUP5: read-path-status.json missing or not READABLE (${STATUS_E})"
fi

UNHEALTHY_LEN_E=$(python3 -c "
import json
d = json.load(open('${STATUS_E}'))
print(len(d.get('unhealthy_paths', [])))
" 2>/dev/null || echo "-1")
UNHEALTHY_HAS_DEV_E=$(python3 -c "
import json
d = json.load(open('${STATUS_E}'))
print('yes' if any('agents/dev' in p for p in d.get('unhealthy_paths', [])) else 'no')
" 2>/dev/null || echo "no")
if [[ "${UNHEALTHY_LEN_E}" -eq 1 && "${UNHEALTHY_HAS_DEV_E}" == "yes" ]]; then
  pass "GROUP5: read-path-status.json's unhealthy_paths has length 1 and names the drifted agents/dev store"
else
  fail "GROUP5: unhealthy_paths wrong (len=${UNHEALTHY_LEN_E} has_dev=${UNHEALTHY_HAS_DEV_E})"
fi

# --- Both agents drifted: still classifies UNREADABLE, still exits non-zero ---
HOME_F=$(make_e2e_home)
TMP_HOMES+=("${HOME_F}")
DB_F_MAIN=$(db_for "${HOME_F}")
build_broken_store "${DB_F_MAIN}"
DB_F_DEV="${HOME_F}/agents/dev/agent/openclaw-agent.sqlite"
build_broken_store "${DB_F_DEV}"

ARGV_F=$(mktemp "${TMPDIR:-/tmp}/test-e2e-argv-f.XXXXXX")
TMP_ARGV_FILES+=("${ARGV_F}")
run_tick "${HOME_F}" "${ARGV_F}"
RC_F=$?

if [[ "${RC_F}" -ne 0 ]]; then
  pass "GROUP5: both-agents-drifted host still exits non-zero"
else
  fail "GROUP5: both-agents-drifted host exited 0 (expected non-zero)"
fi

STATUS_F="${HOME_F}/skills/revenium/read-path-status.json"
if [[ -f "${STATUS_F}" ]] && grep -qF '"state": "UNREADABLE"' "${STATUS_F}"; then
  pass "GROUP5: both-agents-drifted host's read-path-status.json still records UNREADABLE"
else
  fail "GROUP5: both-agents-drifted status not UNREADABLE (${STATUS_F})"
fi

TX_COUNT_F=$(count_grep '^TX:' "${HOME_F}/revenium-reported.ledger")
if [[ "${TX_COUNT_F}" -eq 0 ]]; then
  pass "GROUP5: both-agents-drifted host meters nothing"
else
  fail "GROUP5: expected 0 TX ledger lines for both-agents-drifted, got ${TX_COUNT_F}"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "==========================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "==========================================="

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
