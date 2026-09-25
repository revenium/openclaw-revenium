#!/usr/bin/env bash
# =============================================================================
# session-store.sh — The single owner of every read of OpenClaw 2.0's SQLite
# session store (D-01/D-02, Phase 19 READ-01/READ-04).
#
# DUAL-MODE:
#   SOURCED by scripts/report.sh, scripts/guardrail-check.sh,
#   scripts/write-marker.sh, scripts/write-job-marker.sh,
#   scripts/verify-markers.sh — callers get the store_* function surface.
#   EXECUTED (bash scripts/session-store.sh <verb> [args]) — a CLI dispatcher
#   so scripts/get-root-session-id.py and the marker scripts' Python heredocs
#   can reach the store without sourcing bash (D-02).
#
# Callers MAY define info()/warn()/error()/fail() BEFORE sourcing this file
# (e.g. common.sh's or report.sh's own); a defensive fallback is provided
# below for direct/hermetic sourcing (this file's own unit tests).
#
# CRITICAL DISCIPLINE: every store_* function's STDOUT IS ITS RETURN VALUE.
# All diagnostics (info/warn/error, raw sqlite stderr) go to stderr. Never let
# a diagnostic corrupt a row stream captured via command substitution.
#
# Usage (sourced):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${SCRIPT_DIR}/session-store.sh"
#   store_probe; echo "${STORE_STATE}"
#
# Usage (executed):
#   bash scripts/session-store.sh probe
#   bash scripts/session-store.sh current-session-id
# =============================================================================
# NOTE: No `set -e` here — this is a sourced library. Callers that set -e will
# keep it. Adding -e here would cause unexpected exits in the caller's context.
set -uo pipefail

declare -F info  >/dev/null 2>&1 || info()  { echo "[INFO ] $*" >&2; }
declare -F warn  >/dev/null 2>&1 || warn()  { echo "[WARN ] $*" >&2; }
declare -F error >/dev/null 2>&1 || error() { echo "[ERROR] $*" >&2; }
declare -F fail  >/dev/null 2>&1 || fail()  { echo ""; echo "  ✗ $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# OPENCLAW_HOME / STATE_DIR — derive only if the caller has not already
# defined them, mirroring scripts/common.sh:17-53 (including the sandbox
# descend into ${OPENCLAW_HOME}/.openclaw). Deliberately does NOT
# `mkdir -p "${STATE_DIR}"` — verify-markers.sh refuses to inherit that side
# effect from common.sh, and a purely-read library should not create dirs.
# ---------------------------------------------------------------------------
if [[ -z "${OPENCLAW_HOME:-}" ]]; then
  _ss_home=""
  for _ss_candidate in "${HOME}/.openclaw" "/home/ubuntu/.openclaw"; do
    if [[ -d "${_ss_candidate}/agents" ]]; then
      _ss_home="${_ss_candidate}"
      break
    fi
  done
  OPENCLAW_HOME="${_ss_home:-${HOME}/.openclaw}"
  unset _ss_home _ss_candidate
fi

if [[ ! -d "${OPENCLAW_HOME}/agents" && -d "${OPENCLAW_HOME}/.openclaw/agents" ]]; then
  OPENCLAW_HOME="${OPENCLAW_HOME}/.openclaw"
fi

STATE_DIR="${STATE_DIR:-${OPENCLAW_HOME}/skills/revenium}"

# ---------------------------------------------------------------------------
# Constants — defensive fallbacks so this file works whether or not
# scripts/common.sh (which defines the canonical copies) was sourced first.
# ---------------------------------------------------------------------------
SESSION_STORE_GLOB="${SESSION_STORE_GLOB:-${OPENCLAW_HOME}/agents/*/agent/openclaw-agent.sqlite}"
SESSION_STORE_OVERRIDE_VAR="${SESSION_STORE_OVERRIDE_VAR:-REVENIUM_SESSION_STORE}"
READ_PATH_STATUS_FILE="${READ_PATH_STATUS_FILE:-${STATE_DIR}/read-path-status.json}"
SQLITE_BUSY_TIMEOUT_MS="${SQLITE_BUSY_TIMEOUT_MS:-5000}"

# ---------------------------------------------------------------------------
# _store_valid_id / _store_valid_key / _store_sql_quote — T-19-01 mitigation.
# Every function that accepts a session id or key MUST validate first (emit
# nothing, warn to stderr, return non-zero on rejection) and embed the value
# only through _store_sql_quote.
# ---------------------------------------------------------------------------
_store_valid_id() {
  [[ "${1:-}" =~ ^[0-9a-fA-F][0-9a-fA-F-]{7,63}$ ]]
}

_store_valid_key() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9:._-]{0,199}$ ]]
}

_store_sql_quote() {
  local v="${1:-}"
  printf '%s' "${v//\'/\'\'}"
}

# _store_valid_seq <value> — defensive validation for the after_seq cursor
# argument, which also gets embedded directly into SQL text.
_store_valid_seq() {
  [[ "${1:-}" =~ ^-?[0-9]+$ ]]
}

# _store_valid_db_path <path> — CR-01/T-19-27..29 mitigation. A store path
# becomes part of a sqlite connection URI (`file:<path>?mode=ro`); a literal
# `?`, `#`, or `%` in the path is a URI metacharacter that truncates or
# reinterprets the URI, silently dropping the read-only parameter and
# falling through to a read-write-and-create connection. Reject any
# candidate whose bytes fall outside this anchored allowlist BEFORE it ever
# reaches a connection string: absolute path only (leading `/`), remaining
# bytes drawn ONLY from A-Za-z0-9 plus / . _ - + : @ , = ~. Verified
# sufficient for every real host path family this project targets:
# ${HOME}/.openclaw/agents/<id>/agent/openclaw-agent.sqlite, the sandbox
# /sandbox/.openclaw/... form, and both Linux /tmp/... and macOS
# /var/folders/<a>/<b>/T/... test temp roots.
_store_valid_db_path() {
  [[ "${1:-}" =~ ^/[A-Za-z0-9/._+:@,=~-]+$ ]]
}

# ---------------------------------------------------------------------------
# store_sql <db_path> <sql> — THE ONLY place a sqlite connection is
# constructed (T-19-03). Read-only URI, explicit busy_timeout, no retry or
# backoff wrapper (spike 011: proven clean over a 62-tick soak). stderr is
# captured into STORE_LAST_SQL_ERROR; the child's exit status is returned.
# ---------------------------------------------------------------------------
# _store_sqlite_flags — SQLite CLI releases from ~3.45.0 onward escape
# control characters in query output using caret notation by default (e.g.
# char(31) prints as the two bytes "^_" instead of the single 0x1F byte) —
# a terminal-injection hardening feature that silently corrupts every
# \x1f-separated row this file's entire contract depends on. `-escape off`
# restores raw-byte output; older CLIs (pre-hardening) predate the flag
# entirely and never escaped in the first place, so probe support once and
# cache it rather than assuming either behavior.
_STORE_SQLITE_FLAGS_INIT=""
_STORE_SQLITE_FLAGS=()
_store_sqlite_flags() {
  [[ -n "${_STORE_SQLITE_FLAGS_INIT}" ]] && return 0
  _STORE_SQLITE_FLAGS_INIT=1
  if "${STUB_SQLITE3_BIN:-sqlite3}" -escape off ":memory:" "SELECT 1;" >/dev/null 2>&1; then
    _STORE_SQLITE_FLAGS=(-escape off)
  fi
  return 0
}

STORE_LAST_SQL_ERROR=""

store_sql() {
  local db_path="$1" sql="$2"
  local stderr_tmp stdout_tmp rc
  # CR-01 defense-in-depth: store_db_paths already gates both its sources
  # (glob arm and REVENIUM_SESSION_STORE override), but any future caller
  # reaching store_sql directly must not be able to bypass the allowlist —
  # this is the only place a connection is actually built. Validate BEFORE
  # anything else, including the flags probe and the mktemp calls, so a
  # rejected path never touches the sqlite3 binary at all.
  if ! _store_valid_db_path "${db_path}"; then
    STORE_LAST_SQL_ERROR="store_sql: rejected db_path outside the safe path allowlist: ${db_path:0:64}"
    return 1
  fi
  _store_sqlite_flags
  stderr_tmp=$(mktemp "${TMPDIR:-/tmp}/store-sql-err.XXXXXX")
  stdout_tmp=$(mktemp "${TMPDIR:-/tmp}/store-sql-out.XXXXXX")
  "${STUB_SQLITE3_BIN:-sqlite3}" "${_STORE_SQLITE_FLAGS[@]}" -cmd "PRAGMA busy_timeout=${SQLITE_BUSY_TIMEOUT_MS};" \
    "file:${db_path}?mode=ro" "${sql}" >"${stdout_tmp}" 2>"${stderr_tmp}"
  rc=$?
  STORE_LAST_SQL_ERROR="$(cat "${stderr_tmp}" 2>/dev/null)"
  rm -f "${stderr_tmp}"
  # The -cmd "PRAGMA busy_timeout=<N>" itself emits a result row (the new
  # timeout value) BEFORE the main SQL's own output — confirmed both live
  # (schema-capture.sql.txt's own captured "5000" line, right after each
  # "-- CELL ..." header) and reproduced against this project's sqlite3
  # build. Strip exactly one leading line when it matches the configured
  # timeout value, never more (a legitimate result whose first row happens
  # to equal the timeout is vanishingly unlikely and not worth a fragile
  # positional assumption beyond "at most one line").
  if [[ "$(head -n1 "${stdout_tmp}" 2>/dev/null)" == "${SQLITE_BUSY_TIMEOUT_MS}" ]]; then
    tail -n +2 "${stdout_tmp}"
  else
    cat "${stdout_tmp}"
  fi
  rm -f "${stdout_tmp}"
  return "${rc}"
}

# ---------------------------------------------------------------------------
# store_db_paths_raw — every candidate path UNFILTERED (override arm or glob
# arm), one absolute store path per line, LC_ALL=C sorted in the glob arm.
# Honors REVENIUM_SESSION_STORE (explicit override — also the Phase 22 SSHFS
# parameterization point and the test override). Emits nothing when no store
# exists anywhere. This is the audit-trail source for STORE_PATHS_TRIED — a
# rejected candidate must still appear here even though store_db_paths
# below will filter it out.
# ---------------------------------------------------------------------------
store_db_paths_raw() {
  if [[ -n "${REVENIUM_SESSION_STORE:-}" ]]; then
    printf '%s\n' "${REVENIUM_SESSION_STORE}"
    return 0
  fi
  local _ss_f
  # Intentional unquoted glob expansion (SESSION_STORE_GLOB carries a `*`
  # segment); nullglob-safe via the existence check below.
  # shellcheck disable=SC2086
  for _ss_f in ${SESSION_STORE_GLOB}; do
    [[ -e "${_ss_f}" ]] && printf '%s\n' "${_ss_f}"
  done | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# store_db_paths — the filtered reader every existing caller keeps using.
# Reads store_db_paths_raw and, for each candidate, either emits it or warns
# (bounded to 64 characters) and skips it — CR-01: both the glob result and
# the REVENIUM_SESSION_STORE override pass through the same
# _store_valid_db_path gate, so a candidate carrying a URI metacharacter (or
# any other byte outside the safe path allowlist) never reaches a
# connection string.
# ---------------------------------------------------------------------------
store_db_paths() {
  local _ss_raw _ss_p
  _ss_raw="$(store_db_paths_raw)"
  [[ -z "${_ss_raw}" ]] && return 0
  while IFS= read -r _ss_p; do
    [[ -z "${_ss_p}" ]] && continue
    if _store_valid_db_path "${_ss_p}"; then
      printf '%s\n' "${_ss_p}"
    else
      warn "store_db_paths: rejected candidate path outside the safe path allowlist: ${_ss_p:0:64}"
    fi
  done <<< "${_ss_raw}"
}

# ---------------------------------------------------------------------------
# store_probe — runs at most once per process (STORE_PROBE_DONE guard) and
# sets STORE_STATE (READABLE|EMPTY|UNREADABLE), STORE_PROBE_ERROR,
# STORE_PATHS_TRIED, STORE_SCHEMA_MISSING. Modeled on report.sh's
# JOBS_CLI_CAPABLE probe-once-and-cache shape (D-15's schema-drift probe).
# ---------------------------------------------------------------------------
STORE_PROBE_DONE=""
STORE_STATE=""
STORE_PROBE_ERROR=""
STORE_PATHS_TRIED=""
STORE_SCHEMA_MISSING=""
STORE_REJECTED_PATHS=""
STORE_REJECTED_COUNT=0
STORE_UNREADABLE_WARNED=""

store_probe() {
  if [[ -n "${STORE_PROBE_DONE}" ]]; then
    return 0
  fi
  STORE_PROBE_DONE=1
  STORE_PROBE_ERROR=""
  STORE_SCHEMA_MISSING=""
  STORE_REJECTED_PATHS=""
  STORE_REJECTED_COUNT=0

  if ! command -v "${STUB_SQLITE3_BIN:-sqlite3}" >/dev/null 2>&1; then
    STORE_STATE="UNREADABLE"
    STORE_PATHS_TRIED="${SESSION_STORE_GLOB}"
    STORE_PROBE_ERROR="sqlite3 binary not found on PATH. Install sqlite3 (e.g. 'apt-get install sqlite3' or 'brew install sqlite3') and re-run."
    return 0
  fi

  # STORE_PATHS_TRIED is sourced from the RAW candidate list, never the
  # filtered one — a rejected path that disappeared from this audit trail
  # would take the only operator-visible record of the rejection with it
  # (T-19-29). Compute the rejected set here, in this parent-shell scope, by
  # diffing raw against filtered — store_db_paths runs its own warn() inside
  # a command-substitution subshell and cannot write back to the caller.
  local _ss_raw _ss_filtered _ss_p _ss_rejected="" _ss_rejected_count=0
  _ss_raw="$(store_db_paths_raw)"
  _ss_filtered="$(store_db_paths)"
  STORE_PATHS_TRIED="${_ss_raw:-${SESSION_STORE_GLOB}}"

  if [[ -n "${_ss_raw}" ]]; then
    while IFS= read -r _ss_p; do
      [[ -z "${_ss_p}" ]] && continue
      if ! printf '%s\n' "${_ss_filtered}" | grep -qxF "${_ss_p}"; then
        _ss_rejected="${_ss_rejected}${_ss_p}"$'\n'
        _ss_rejected_count=$(( _ss_rejected_count + 1 ))
      fi
    done <<< "${_ss_raw}"
  fi
  STORE_REJECTED_PATHS="${_ss_rejected%$'\n'}"
  STORE_REJECTED_COUNT="${_ss_rejected_count}"

  if [[ -z "${_ss_filtered}" ]]; then
    STORE_STATE="UNREADABLE"
    if [[ "${STORE_REJECTED_COUNT}" -gt 0 ]]; then
      local _ss_first_rejected
      _ss_first_rejected="$(printf '%s\n' "${STORE_REJECTED_PATHS}" | head -1)"
      STORE_PROBE_ERROR="${STORE_REJECTED_COUNT} candidate path(s) rejected for characters outside the safe path allowlist; first: ${_ss_first_rejected:0:64}"
    else
      STORE_PROBE_ERROR="No session store found under ${SESSION_STORE_GLOB} (or ${SESSION_STORE_OVERRIDE_VAR} override)."
    fi
    return 0
  fi

  local _ss_db _ss_info _ss_missing _ss_total=0 _ss_cnt _ss_col
  _ss_missing=""
  while IFS= read -r _ss_db; do
    [[ -z "${_ss_db}" ]] && continue

    _ss_info="$(store_sql "${_ss_db}" "PRAGMA table_info(transcript_events);")"
    if [[ $? -ne 0 ]]; then
      STORE_STATE="UNREADABLE"
      STORE_PROBE_ERROR="${STORE_LAST_SQL_ERROR}"
      return 0
    fi
    if ! printf '%s\n' "${_ss_info}" | grep -q 'event_json'; then
      _ss_missing="${_ss_missing}transcript_events.event_json"$'\n'
    fi

    _ss_info="$(store_sql "${_ss_db}" "PRAGMA table_info(session_nodes);")"
    if [[ $? -ne 0 ]]; then
      STORE_STATE="UNREADABLE"
      STORE_PROBE_ERROR="${STORE_LAST_SQL_ERROR}"
      return 0
    fi
    for _ss_col in created_via updated_at current_session_id session_key; do
      if ! printf '%s\n' "${_ss_info}" | grep -q "${_ss_col}"; then
        _ss_missing="${_ss_missing}session_nodes.${_ss_col}"$'\n'
      fi
    done

    if [[ -n "${_ss_missing}" ]]; then
      STORE_STATE="UNREADABLE"
      STORE_SCHEMA_MISSING="${_ss_missing%$'\n'}"
      STORE_PROBE_ERROR="Schema drift detected on ${_ss_db} — missing columns: ${STORE_SCHEMA_MISSING//$'\n'/, }"
      return 0
    fi

    _ss_cnt="$(store_sql "${_ss_db}" "SELECT count(*) FROM session_nodes WHERE created_via IS NULL OR created_via != 'cron';")"
    if [[ $? -ne 0 ]]; then
      STORE_STATE="UNREADABLE"
      STORE_PROBE_ERROR="${STORE_LAST_SQL_ERROR}"
      return 0
    fi
    _ss_total=$(( _ss_total + ${_ss_cnt:-0} ))
  done <<< "${_ss_filtered}"

  if [[ "${_ss_total}" -eq 0 ]]; then
    STORE_STATE="EMPTY"
  else
    STORE_STATE="READABLE"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# store_warn_if_unreadable [caller_label] — reusable once-per-process warn
# for plan 19-10's four resolvers. Calls store_probe (already memoized),
# emits exactly one `warn` per process — guarded by STORE_UNREADABLE_WARNED
# — only when STORE_STATE is UNREADABLE. Silent for READABLE and EMPTY (a
# fresh/legitimately-empty host must stay quiet — no false alarm). Never
# returns non-zero and never exits: consumers include a script running
# under `set -euo pipefail`.
# ---------------------------------------------------------------------------
store_warn_if_unreadable() {
  local _ss_label="${1:-}"
  store_probe
  if [[ "${STORE_STATE}" != "UNREADABLE" ]]; then
    return 0
  fi
  if [[ -n "${STORE_UNREADABLE_WARNED}" ]]; then
    return 0
  fi
  STORE_UNREADABLE_WARNED=1
  local _ss_paths_joined _ss_error_bounded _ss_label_bounded
  _ss_paths_joined="$(printf '%s' "${STORE_PATHS_TRIED}" | tr '\n' ',' | sed 's/,$//')"
  _ss_error_bounded="${STORE_PROBE_ERROR:0:64}"
  _ss_label_bounded="${_ss_label:0:64}"
  if [[ -n "${_ss_label_bounded}" ]]; then
    warn "${_ss_label_bounded}: session store UNREADABLE (paths tried: ${_ss_paths_joined}) — ${_ss_error_bounded}"
  else
    warn "session store UNREADABLE (paths tried: ${_ss_paths_joined}) — ${_ss_error_bounded}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# store_list_sessions — one row per non-cron session, across every store,
# "<current_session_id>\x1f<session_key>\x1f<created_via>\x1f<updated_at>",
# ORDER BY updated_at DESC, session_key ASC.
# ---------------------------------------------------------------------------
store_list_sessions() {
  local _ss_db
  while IFS= read -r _ss_db; do
    [[ -z "${_ss_db}" ]] && continue
    store_sql "${_ss_db}" "SELECT current_session_id || char(31) || session_key || char(31) || coalesce(created_via,'') || char(31) || updated_at FROM session_nodes WHERE created_via IS NULL OR created_via != 'cron' ORDER BY updated_at DESC, session_key ASC;"
  done < <(store_db_paths)
}

# ---------------------------------------------------------------------------
# store_session_events <sid> [after_seq] — raw event_json rows (newlines
# collapsed to spaces defensively), ORDER BY seq ASC. This is the Pitfall-1
# fix: event_json carries the byte-identical record shape the old transcript
# lines carried, so report.sh's existing jq filters consume it unchanged.
# ---------------------------------------------------------------------------
store_session_events() {
  local sid="$1" after_seq="${2:--1}"
  if ! _store_valid_id "${sid}"; then
    warn "store_session_events: rejected invalid session id"
    return 0
  fi
  _store_valid_seq "${after_seq}" || after_seq=-1
  local q_sid
  q_sid="$(_store_sql_quote "${sid}")"
  local _ss_db
  while IFS= read -r _ss_db; do
    [[ -z "${_ss_db}" ]] && continue
    store_sql "${_ss_db}" "SELECT replace(event_json, char(10), ' ') FROM transcript_events WHERE session_id = '${q_sid}' AND seq > ${after_seq} AND event_json IS NOT NULL ORDER BY seq ASC;"
  done < <(store_db_paths)
}

# ---------------------------------------------------------------------------
# store_max_seq <sid> — coalesce(max(seq), -1) across every store.
# ---------------------------------------------------------------------------
store_max_seq() {
  local sid="$1"
  if ! _store_valid_id "${sid}"; then
    warn "store_max_seq: rejected invalid session id"
    return 0
  fi
  local q_sid
  q_sid="$(_store_sql_quote "${sid}")"
  local _ss_db _ss_val _ss_max=-1
  while IFS= read -r _ss_db; do
    [[ -z "${_ss_db}" ]] && continue
    _ss_val="$(store_sql "${_ss_db}" "SELECT coalesce(max(seq), -1) FROM transcript_events WHERE session_id = '${q_sid}';")"
    if [[ -n "${_ss_val}" && "${_ss_val}" =~ ^-?[0-9]+$ && "${_ss_val}" -gt "${_ss_max}" ]]; then
      _ss_max="${_ss_val}"
    fi
  done < <(store_db_paths)
  printf '%s\n' "${_ss_max}"
}

# ---------------------------------------------------------------------------
# store_completions <sid> [after_seq] — one row per DISTINCT responseId among
# usage-bearing assistant rows (D-04's dedup unit):
#   "<response_id>\x1f<run_id>\x1f<seq>\x1f<event_json>"
# Several rows sharing one responseId (streaming/partial re-emit) collapse to
# one, keyed on the minimum seq. Distinct responseIds under one runId each
# survive as their own row. Correlated only by exact structural equality on
# an extracted JSON value — never a pattern-match/substring scan (D-19).
# ---------------------------------------------------------------------------
store_completions() {
  local sid="$1" after_seq="${2:--1}"
  if ! _store_valid_id "${sid}"; then
    warn "store_completions: rejected invalid session id"
    return 0
  fi
  _store_valid_seq "${after_seq}" || after_seq=-1
  local q_sid
  q_sid="$(_store_sql_quote "${sid}")"
  local sql
  sql="SELECT t.response_id || char(31) || t.run_id || char(31) || t.min_seq || char(31) || te.event_json
FROM (
  SELECT json_extract(event_json,'\$.message.responseId') AS response_id,
         coalesce(json_extract(event_json,'\$.message.__openclaw.runId'),'') AS run_id,
         min(seq) AS min_seq
  FROM transcript_events
  WHERE session_id = '${q_sid}'
    AND json_extract(event_json,'\$.message.role') = 'assistant'
    AND json_extract(event_json,'\$.message.usage') IS NOT NULL
    AND json_extract(event_json,'\$.message.responseId') IS NOT NULL
    AND event_json IS NOT NULL
    AND seq > ${after_seq}
  GROUP BY json_extract(event_json,'\$.message.responseId')
) AS t
JOIN transcript_events AS te ON te.session_id = '${q_sid}' AND te.seq = t.min_seq
ORDER BY t.min_seq ASC;"
  local _ss_db
  while IFS= read -r _ss_db; do
    [[ -z "${_ss_db}" ]] && continue
    store_sql "${_ss_db}" "${sql}"
  done < <(store_db_paths)
}

# ---------------------------------------------------------------------------
# store_current_session_id — D-10's locked mechanism. One row per store:
# "<updated_at>\x1f<session_key>\x1f<current_session_id>" for the newest
# non-cron session (ORDER BY updated_at DESC, session_key ASC LIMIT 1); the
# overall answer is picked across every store the same way, so a tie is
# broken by session_key ascending and stays stable across calls. Emits an
# empty string (exit 0) when nothing qualifies anywhere — fail-open, every
# caller already has a fallback. Supersedes the previous "non-cron
# transcript file whose last assistant completion is most recent" heuristic
# (WR-03): session_nodes.updated_at is maintained by the store on every
# append (a strictly better signal than file mtime), and created_via is a
# schema-enforced enum rather than a key-prefix guess.
# ---------------------------------------------------------------------------
store_current_session_id() {
  local _ss_db _ss_row
  {
    while IFS= read -r _ss_db; do
      [[ -z "${_ss_db}" ]] && continue
      _ss_row="$(store_sql "${_ss_db}" "SELECT updated_at || char(31) || session_key || char(31) || current_session_id FROM session_nodes WHERE created_via IS NULL OR created_via != 'cron' ORDER BY updated_at DESC, session_key ASC LIMIT 1;")"
      [[ -n "${_ss_row}" ]] && printf '%s\n' "${_ss_row}"
    done < <(store_db_paths)
  } | LC_ALL=C sort -t $'\x1f' -k1,1nr -k2,2 | head -1 | awk -F$'\x1f' '{print $3}'
}

# ---------------------------------------------------------------------------
# store_last_completion_id <sid> — the responseId of the highest-seq
# usage-bearing assistant row in this session, or empty. MUST be the same
# identifier store_completions emits as response_id — write-marker.sh (plan
# 19-06) stamps this as completion_id, and report.sh's Phase A exact-match
# correlation depends on the two values agreeing.
# ---------------------------------------------------------------------------
store_last_completion_id() {
  local sid="$1"
  if ! _store_valid_id "${sid}"; then
    warn "store_last_completion_id: rejected invalid session id"
    return 0
  fi
  local q_sid
  q_sid="$(_store_sql_quote "${sid}")"
  local _ss_db _ss_val
  while IFS= read -r _ss_db; do
    [[ -z "${_ss_db}" ]] && continue
    _ss_val="$(store_sql "${_ss_db}" "SELECT json_extract(event_json,'\$.message.responseId') FROM transcript_events WHERE session_id = '${q_sid}' AND json_extract(event_json,'\$.message.role') = 'assistant' AND json_extract(event_json,'\$.message.usage') IS NOT NULL AND event_json IS NOT NULL ORDER BY seq DESC LIMIT 1;")"
    if [[ -n "${_ss_val}" ]]; then
      printf '%s\n' "${_ss_val}"
      return 0
    fi
  done < <(store_db_paths)
  return 0
}

# ---------------------------------------------------------------------------
# store_tool_calls <sid> [after_seq] — one row per toolCall content item,
# LEFT JOINed to its toolResult (a call with no result yet still emits a row
# with an empty result side):
#   "<tool_call_id>\x1f<tool_name>\x1f<call_ts>\x1f<duration_ms>\x1f<is_error>\x1f<error_msg>"
# The call side ITERATES content items via json_each — never a fixed content
# position, because the tool call is not always the second content item
# (sample-rows.txt: content[1] in the observed live turn). error_msg is the
# first text content item of an erroring result, truncated to 256 chars with
# every newline/CR/tab/char(31) replaced by a space (matches the current
# Python scan's sanitization — an unescaped separator byte shifts every
# downstream field). Joined by exact structural equality on toolCallId/id
# only — never a pattern-match operator, never a substring scan (D-19).
# ---------------------------------------------------------------------------
store_tool_calls() {
  local sid="$1" after_seq="${2:--1}"
  if ! _store_valid_id "${sid}"; then
    warn "store_tool_calls: rejected invalid session id"
    return 0
  fi
  _store_valid_seq "${after_seq}" || after_seq=-1
  local q_sid
  q_sid="$(_store_sql_quote "${sid}")"
  local sql
  sql="WITH calls AS (
  SELECT json_extract(value,'\$.id') AS tool_call_id,
         json_extract(value,'\$.name') AS tool_name,
         json_extract(transcript_events.event_json,'\$.timestamp') AS call_ts,
         seq AS call_seq
  FROM transcript_events, json_each(transcript_events.event_json,'\$.message.content')
  WHERE session_id = '${q_sid}'
    AND json_extract(transcript_events.event_json,'\$.message.role') = 'assistant'
    AND json_extract(value,'\$.type') = 'toolCall'
    AND transcript_events.event_json IS NOT NULL
    AND seq > ${after_seq}
)
SELECT calls.tool_call_id || char(31) || calls.tool_name || char(31) || coalesce(calls.call_ts,'') || char(31)
  || coalesce(json_extract(res.event_json,'\$.message.details.durationMs'), 0) || char(31)
  || CASE WHEN json_extract(res.event_json,'\$.message.isError') IN (1,'true') THEN 'true' ELSE 'false' END || char(31)
  || coalesce(replace(replace(replace(replace(
       substr((SELECT json_extract(v.value,'\$.text') FROM json_each(res.event_json,'\$.message.content') AS v
                WHERE json_extract(v.value,'\$.type') = 'text' ORDER BY v.key LIMIT 1), 1, 256)
     , char(10), ' '), char(13), ' '), char(9), ' '), char(31), ' '), '')
FROM calls
LEFT JOIN transcript_events AS res
  ON res.session_id = '${q_sid}'
  AND json_extract(res.event_json,'\$.message.role') = 'toolResult'
  AND json_extract(res.event_json,'\$.message.toolCallId') = calls.tool_call_id
ORDER BY calls.call_seq ASC;"
  local _ss_db
  while IFS= read -r _ss_db; do
    [[ -z "${_ss_db}" ]] && continue
    store_sql "${_ss_db}" "${sql}"
  done < <(store_db_paths)
}

# ---------------------------------------------------------------------------
# store_null_event_count <sid> [after_seq] — count of rows where
# event_json IS NULL (RESEARCH Pitfall 3: a compacted row with event_zstd
# populated instead). Callers log this at INFO when non-zero — never
# silently drop it.
# ---------------------------------------------------------------------------
store_null_event_count() {
  local sid="$1" after_seq="${2:--1}"
  if ! _store_valid_id "${sid}"; then
    warn "store_null_event_count: rejected invalid session id"
    return 0
  fi
  _store_valid_seq "${after_seq}" || after_seq=-1
  local q_sid
  q_sid="$(_store_sql_quote "${sid}")"
  local _ss_db _ss_val total=0
  while IFS= read -r _ss_db; do
    [[ -z "${_ss_db}" ]] && continue
    _ss_val="$(store_sql "${_ss_db}" "SELECT count(*) FROM transcript_events WHERE session_id = '${q_sid}' AND seq > ${after_seq} AND event_json IS NULL;")"
    [[ "${_ss_val}" =~ ^[0-9]+$ ]] && total=$(( total + _ss_val ))
  done < <(store_db_paths)
  printf '%s\n' "${total}"
}

# ---------------------------------------------------------------------------
# store_session_key_for_id <session_id> — session_windows, NOT session_nodes:
# session_nodes holds only the CURRENT session id per key, so a historical or
# ended subagent window has no row there.
# ---------------------------------------------------------------------------
store_session_key_for_id() {
  local sid="$1"
  if ! _store_valid_id "${sid}"; then
    warn "store_session_key_for_id: rejected invalid session id"
    return 0
  fi
  local q_sid
  q_sid="$(_store_sql_quote "${sid}")"
  local _ss_db _ss_val
  while IFS= read -r _ss_db; do
    [[ -z "${_ss_db}" ]] && continue
    _ss_val="$(store_sql "${_ss_db}" "SELECT session_key FROM session_windows WHERE session_id = '${q_sid}' LIMIT 1;")"
    if [[ -n "${_ss_val}" ]]; then
      printf '%s\n' "${_ss_val}"
      return 0
    fi
  done < <(store_db_paths)
  return 0
}

# ---------------------------------------------------------------------------
# store_session_id_for_key <session_key> — session_nodes.current_session_id.
# Together with store_session_key_for_id, closes the session-KEY vs
# session-ID gap (RESEARCH Pitfall 2): hook payloads carry keys, this
# project's resolver contract carries ids.
# ---------------------------------------------------------------------------
store_session_id_for_key() {
  local skey="$1"
  if ! _store_valid_key "${skey}"; then
    warn "store_session_id_for_key: rejected invalid session key"
    return 0
  fi
  local q_key
  q_key="$(_store_sql_quote "${skey}")"
  local _ss_db _ss_val
  while IFS= read -r _ss_db; do
    [[ -z "${_ss_db}" ]] && continue
    _ss_val="$(store_sql "${_ss_db}" "SELECT current_session_id FROM session_nodes WHERE session_key = '${q_key}' LIMIT 1;")"
    if [[ -n "${_ss_val}" ]]; then
      printf '%s\n' "${_ss_val}"
      return 0
    fi
  done < <(store_db_paths)
  return 0
}

# ---------------------------------------------------------------------------
# store_parent_session_id <sid> — ONE hop. Translates the id to its key, then
# selects the first non-null of session_windows.parent_session_key/spawned_by
# (queried by session_id — session_windows' own primary key), then
# session_nodes.parent_session_key/spawned_by/fork_source_session_key
# (queried by the translated key), then translates that parent key back to a
# session id. Emits empty when no parent is recorded. These columns are
# confirmed present in schema but NEVER confirmed populated with live data —
# exactly why D-08 makes this the FALLBACK behind the subagent-hook sidecar.
# ---------------------------------------------------------------------------
store_parent_session_id() {
  local sid="$1"
  if ! _store_valid_id "${sid}"; then
    warn "store_parent_session_id: rejected invalid session id"
    return 0
  fi
  local key
  key="$(store_session_key_for_id "${sid}")"
  [[ -z "${key}" ]] && return 0
  local q_sid q_key parent_key="" _ss_db
  q_sid="$(_store_sql_quote "${sid}")"
  q_key="$(_store_sql_quote "${key}")"
  while IFS= read -r _ss_db; do
    [[ -z "${_ss_db}" ]] && continue
    parent_key="$(store_sql "${_ss_db}" "SELECT coalesce(
      (SELECT parent_session_key FROM session_windows WHERE session_id = '${q_sid}' LIMIT 1),
      (SELECT spawned_by FROM session_windows WHERE session_id = '${q_sid}' LIMIT 1),
      (SELECT parent_session_key FROM session_nodes WHERE session_key = '${q_key}' LIMIT 1),
      (SELECT spawned_by FROM session_nodes WHERE session_key = '${q_key}' LIMIT 1),
      (SELECT fork_source_session_key FROM session_nodes WHERE session_key = '${q_key}' LIMIT 1)
    );")"
    [[ -n "${parent_key}" ]] && break
  done < <(store_db_paths)
  [[ -z "${parent_key}" ]] && return 0
  store_session_id_for_key "${parent_key}"
}

# ---------------------------------------------------------------------------
# store_root_session_id <sid> — the locked D-01 name. Walks
# store_parent_session_id at most ten times (the same max_depth guard
# get-root-session-id.py uses), emitting the last non-empty id reached, or
# the input sid when the first hop is empty. Never emits nothing for a valid
# input.
# ---------------------------------------------------------------------------
store_root_session_id() {
  local sid="$1"
  if ! _store_valid_id "${sid}"; then
    warn "store_root_session_id: rejected invalid session id"
    printf '%s\n' "${sid}"
    return 0
  fi
  local current="${sid}" parent hop
  for (( hop = 0; hop < 10; hop++ )); do
    parent="$(store_parent_session_id "${current}")"
    [[ -z "${parent}" ]] && break
    current="${parent}"
  done
  printf '%s\n' "${current}"
}

# ---------------------------------------------------------------------------
# store_write_status <state> <error_text> — writes READ_PATH_STATUS_FILE via
# an env-passing python3 heredoc (never ${} interpolation — Bash 3.2 safety),
# atomically (tempfile + os.replace in the same directory, mirroring
# guardrail-check.sh's guardrail-status.json precedent, D-14). Before
# writing error_text, strips every character whose code point is below 32
# and every \x7f, then truncates to 512 characters — T-19-02: the raw
# sqlite diagnostic can echo session-derived bytes into a durable file other
# processes read.
# ---------------------------------------------------------------------------
store_write_status() {
  local state="$1" error_text="${2:-}"
  local store_count
  store_count="$(store_db_paths | grep -c . || true)"
  READ_PATH_STATUS_FILE="${READ_PATH_STATUS_FILE}" \
  RP_STATE="${state}" \
  RP_ERROR="${error_text}" \
  RP_PATHS="${STORE_PATHS_TRIED:-}" \
  RP_SCHEMA_MISSING="${STORE_SCHEMA_MISSING:-}" \
  RP_REJECTED="${STORE_REJECTED_PATHS:-}" \
  RP_STORE_COUNT="${store_count:-0}" \
  python3 - <<'PY' 2>/dev/null || true
import json, os, tempfile
from datetime import datetime, timezone
from pathlib import Path

status_file = Path(os.environ['READ_PATH_STATUS_FILE'])
raw_error = os.environ.get('RP_ERROR', '')
# T-19-02: strip control chars below 32 and 0x7f, then truncate to 512 chars.
cleaned_error = ''.join(ch for ch in raw_error if ord(ch) >= 32 and ch != '\x7f')[:512]

paths_tried = [p for p in os.environ.get('RP_PATHS', '').split('\n') if p]
schema_missing = [c for c in os.environ.get('RP_SCHEMA_MISSING', '').split('\n') if c]
rejected_paths = [p for p in os.environ.get('RP_REJECTED', '').split('\n') if p]

data = {
    'state': os.environ.get('RP_STATE', ''),
    'timestamp': datetime.now(timezone.utc).isoformat(),
    'paths_tried': paths_tried,
    'error_text': cleaned_error,
    'schema_missing': schema_missing,
    'rejected_paths': rejected_paths,
    'store_count': int(os.environ.get('RP_STORE_COUNT', '0') or 0),
}

status_file.parent.mkdir(parents=True, exist_ok=True)
tmp_fd, tmp_path = tempfile.mkstemp(
    dir=str(status_file.parent),
    prefix='.read-path-status-',
    suffix='.tmp',
)
try:
    with os.fdopen(tmp_fd, 'w', encoding='utf-8') as f:
        f.write(json.dumps(data, indent=2) + '\n')
    os.replace(tmp_path, str(status_file))
finally:
    try:
        os.unlink(tmp_path)
    except FileNotFoundError:
        pass
PY
}

# ---------------------------------------------------------------------------
# Executed-mode CLI arm (D-02). Detects execution vs sourcing by comparing
# BASH_SOURCE[0] to $0. This is how get-root-session-id.py (plan 19-05) and
# the marker heredocs (plan 19-06) reach the store from Python without
# sourcing bash. `probe` prints the resolved STORE_STATE on stdout and exits
# 0 for READABLE/EMPTY, 2 for UNREADABLE. An unknown verb prints the verb
# list to stderr and exits 64.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _ss_verb="${1:-}"
  shift || true
  case "${_ss_verb}" in
    db-paths)
      store_db_paths
      exit 0
      ;;
    probe)
      store_probe
      echo "${STORE_STATE}"
      case "${STORE_STATE}" in
        READABLE|EMPTY) exit 0 ;;
        *) exit 2 ;;
      esac
      ;;
    current-session-id)
      store_current_session_id
      exit 0
      ;;
    last-completion-id)
      store_last_completion_id "$@"
      exit 0
      ;;
    session-key-for-id)
      store_session_key_for_id "$@"
      exit 0
      ;;
    session-id-for-key)
      store_session_id_for_key "$@"
      exit 0
      ;;
    parent-session-id)
      store_parent_session_id "$@"
      exit 0
      ;;
    root-session-id)
      store_root_session_id "$@"
      exit 0
      ;;
    list-sessions)
      store_list_sessions
      exit 0
      ;;
    session-events)
      store_session_events "$@"
      exit 0
      ;;
    completions)
      store_completions "$@"
      exit 0
      ;;
    tool-calls)
      store_tool_calls "$@"
      exit 0
      ;;
    max-seq)
      store_max_seq "$@"
      exit 0
      ;;
    null-event-count)
      store_null_event_count "$@"
      exit 0
      ;;
    write-status)
      store_write_status "$@"
      exit 0
      ;;
    *)
      echo "Usage: session-store.sh <verb> [args]" >&2
      echo "Verbs: db-paths probe current-session-id last-completion-id session-key-for-id session-id-for-key parent-session-id root-session-id list-sessions session-events completions tool-calls max-seq null-event-count write-status" >&2
      exit 64
      ;;
  esac
fi
