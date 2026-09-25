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
# store_db_paths — one absolute store path per line, LC_ALL=C sorted. Honors
# REVENIUM_SESSION_STORE (explicit override — also the Phase 22 SSHFS
# parameterization point and the test override). Emits nothing when no store
# exists anywhere.
# ---------------------------------------------------------------------------
store_db_paths() {
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

store_probe() {
  if [[ -n "${STORE_PROBE_DONE}" ]]; then
    return 0
  fi
  STORE_PROBE_DONE=1
  STORE_PROBE_ERROR=""
  STORE_SCHEMA_MISSING=""

  if ! command -v "${STUB_SQLITE3_BIN:-sqlite3}" >/dev/null 2>&1; then
    STORE_STATE="UNREADABLE"
    STORE_PATHS_TRIED="${SESSION_STORE_GLOB}"
    STORE_PROBE_ERROR="sqlite3 binary not found on PATH. Install sqlite3 (e.g. 'apt-get install sqlite3' or 'brew install sqlite3') and re-run."
    return 0
  fi

  local _ss_paths
  _ss_paths="$(store_db_paths)"
  STORE_PATHS_TRIED="${_ss_paths:-${SESSION_STORE_GLOB}}"

  if [[ -z "${_ss_paths}" ]]; then
    STORE_STATE="UNREADABLE"
    STORE_PROBE_ERROR="No session store found under ${SESSION_STORE_GLOB} (or ${SESSION_STORE_OVERRIDE_VAR} override)."
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
  done <<< "${_ss_paths}"

  if [[ "${_ss_total}" -eq 0 ]]; then
    STORE_STATE="EMPTY"
  else
    STORE_STATE="READABLE"
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
# Executed-mode CLI arm (D-02). Detects execution vs sourcing by comparing
# BASH_SOURCE[0] to $0. Reachable verbs at this stage of the phase: db-paths,
# probe, session-events, completions, max-seq. (The remaining verbs listed in
# 19-01-PLAN.md's artifacts section are added by Task 2.)
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
    session-events)
      store_session_events "$@"
      exit 0
      ;;
    completions)
      store_completions "$@"
      exit 0
      ;;
    max-seq)
      store_max_seq "$@"
      exit 0
      ;;
    *)
      echo "Usage: session-store.sh <verb> [args]" >&2
      echo "Verbs: db-paths probe current-session-id last-completion-id session-key-for-id session-id-for-key parent-session-id root-session-id list-sessions session-events completions tool-calls max-seq null-event-count write-status" >&2
      exit 64
      ;;
  esac
fi
