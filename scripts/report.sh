#!/usr/bin/env bash
# =============================================================================
# Revenium Metering Reporter for OpenClaw
# Reads session JSONL files, extracts token usage, ships to Revenium
# via `revenium meter completion`.
# =============================================================================

set -uo pipefail
# Note: -e removed because grep/cut pipelines legitimately return non-zero
# when no matches are found, and we handle those cases explicitly.

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
# Allow OPENCLAW_HOME override via env (e.g. sandbox where $HOME != host home).
# Probe common locations to find the real OpenClaw directory.
OPENCLAW_HOME="${OPENCLAW_HOME:-}"
if [[ -z "${OPENCLAW_HOME}" ]]; then
  for candidate in "${HOME}/.openclaw" "/home/ubuntu/.openclaw"; do
    if [[ -d "${candidate}/agents" ]]; then
      OPENCLAW_HOME="${candidate}"
      break
    fi
  done
  OPENCLAW_HOME="${OPENCLAW_HOME:-${HOME}/.openclaw}"
fi

SESSIONS_DIR="${OPENCLAW_HOME}/agents/main/sessions"
LEDGER_FILE="${OPENCLAW_HOME}/revenium-reported.ledger"
LOG_FILE="${OPENCLAW_HOME}/revenium-metering.log"
SKILL_DIR="${OPENCLAW_HOME}/skills/revenium"
CONFIG_FILE="${SKILL_DIR}/config.json"
OFFSETS_FILE="${OPENCLAW_HOME}/revenium-offsets.json"
JOBS_LEDGER_FILE="${REVENIUM_JOBS_LEDGER_FILE:-${OPENCLAW_HOME}/revenium-jobs.ledger}"
TOOL_REGISTRY_LEDGER_FILE="${OPENCLAW_HOME}/revenium-tools.ledger"
TOOL_EVENTS_LEDGER_FILE="${OPENCLAW_HOME}/revenium-tool-events.ledger"

# ---------------------------------------------------------------------------
# Phase 4 constants (METER-03 / TRACE-01/02 / D-07)
# ---------------------------------------------------------------------------
# MARKERS_DIR: per-session marker JSONL files written by write-marker.sh
MARKERS_DIR="${SKILL_DIR}/markers"
# REVENIUM_AGENT_PREFIX: prefix for --agent value; root_sid appended per session.
# Supersedes the static "OpenClaw" agent name (D-07).
REVENIUM_AGENT_PREFIX="${REVENIUM_AGENT_PREFIX:-openclaw-}"

# get_root_session_id — wrapper around get-root-session-id.py sidecar.
# Resolves a child session id to its root via JSONL childSessionKey walk.
# Fail-open (D-05/D-06): if python3 absent or sidecar fails, echoes input sid.
# Resolve ONCE per session file (not per completion line) — Pitfall 3.
get_root_session_id() {
  local sid="${1:-}"
  [[ -z "${sid}" ]] && return 0
  if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "${sid}"; return 0
  fi
  OPENCLAW_HOME="${OPENCLAW_HOME}" python3 "${SKILL_DIR}/scripts/get-root-session-id.py" "${sid}" 2>/dev/null \
    || printf '%s\n' "${sid}"
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  local level="$1"; shift
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${level}] $*" | tee -a "${LOG_FILE}" >&2
}

info()  { log "INFO " "$@"; }
warn()  { log "WARN " "$@"; }
error() { log "ERROR" "$@"; }

# ---------------------------------------------------------------------------
# PATH — ensure revenium/jq are discoverable (cron and sandbox have minimal PATH)
# ---------------------------------------------------------------------------
BREW_PREFIX=""
if command -v brew &>/dev/null; then
  BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
fi

for p in \
  "${BREW_PREFIX:+${BREW_PREFIX}/bin}" \
  "${BREW_PREFIX:+${BREW_PREFIX}/sbin}" \
  /home/linuxbrew/.linuxbrew/bin \
  /home/linuxbrew/.linuxbrew/sbin \
  /opt/homebrew/bin \
  /opt/homebrew/sbin \
  /usr/local/bin \
  /usr/bin \
  "${HOME}/go/bin" \
  "${HOME}/.local/bin"; do
  [[ -n "${p}" && -d "${p}" ]] && export PATH="${p}:${PATH}"
done

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
if ! command -v revenium &>/dev/null; then
  warn "revenium CLI not found on PATH — skipping metering."
  exit 0
fi

if ! command -v jq &>/dev/null; then
  warn "jq not found — skipping metering."
  exit 0
fi

if ! revenium config show &>/dev/null; then
  warn "revenium not configured — run /revenium in OpenClaw to set up."
  exit 0
fi

touch "${LEDGER_FILE}"
touch "${JOBS_LEDGER_FILE}"
touch "${TOOL_REGISTRY_LEDGER_FILE}"
touch "${TOOL_EVENTS_LEDGER_FILE}"

# ---------------------------------------------------------------------------
# Read optional organization name from config.json
# ---------------------------------------------------------------------------
ORG_NAME=""
if [[ -f "${CONFIG_FILE}" ]]; then
  ORG_NAME=$(python3 -c "import json; print(json.load(open('${CONFIG_FILE}')).get('organizationName', ''))" 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# Map provider from model string
# OpenClaw JSONL has .message.provider = "bedrock" (the API route),
# but Revenium wants the actual AI provider.
# ---------------------------------------------------------------------------
get_provider() {
  local model="$1"
  case "${model}" in
    *claude*|*anthropic*)  echo "anthropic" ;;
    *gpt-*|*o1-*|*o3-*)   echo "openai" ;;
    *gemini-*)             echo "google" ;;
    *deepseek-*)           echo "deepseek" ;;
    *llama-*|*mistral-*)   echo "meta" ;;
    *)                     echo "unknown" ;;
  esac
}

# ---------------------------------------------------------------------------
# Clean model name — strip routing prefixes like "global."
# "global.anthropic.claude-sonnet-4-6" → "claude-sonnet-4-6"
# ---------------------------------------------------------------------------
clean_model_name() {
  local model="$1"
  # Strip known prefixes
  model="${model#global.}"
  model="${model#anthropic.}"
  model="${model#openai.}"
  model="${model#google.}"
  echo "${model}"
}

# ---------------------------------------------------------------------------
# Map stop reason to Revenium enum
# OpenClaw uses: stop, toolUse, end_turn, max_tokens, etc.
# ---------------------------------------------------------------------------
map_stop_reason() {
  case "${1}" in
    stop|end_turn|endTurn) echo "END" ;;
    stop_sequence)         echo "END_SEQUENCE" ;;
    max_tokens)            echo "TOKEN_LIMIT" ;;
    timeout)               echo "TIMEOUT" ;;
    error)                 echo "ERROR" ;;
    toolUse|tool_use)      echo "END" ;;
    cancelled|canceled)    echo "CANCELLED" ;;
    *)                     echo "END" ;;
  esac
}

# ---------------------------------------------------------------------------
# Offset helpers — track last-processed line count per session (replaces DONE:)
# ---------------------------------------------------------------------------
get_offset() {
  local sid="$1"
  if [[ ! -f "${OFFSETS_FILE}" ]]; then
    echo 0
    return
  fi
  # Env-passing heredoc discipline (T-04-09): pass path + sid via env, never
  # interpolate (sid is a session filename; OFFSETS_FILE path may contain a quote).
  OFFSETS_FILE="${OFFSETS_FILE}" SID="${sid}" python3 - <<'PY' 2>/dev/null || echo 0
import json, os
try:
    d = json.load(open(os.environ['OFFSETS_FILE']))
    print(d.get(os.environ['SID'], 0))
except Exception:
    print(0)
PY
}

set_offset() {
  local sid="$1"
  local count="$2"
  # Env-passing heredoc discipline (T-04-09): pass path, sid, count via env.
  OFFSETS_FILE="${OFFSETS_FILE}" SID="${sid}" COUNT="${count}" python3 - <<'PY' 2>/dev/null || true
import json, os, tempfile
path = os.environ['OFFSETS_FILE']
try:
    d = json.load(open(path))
except Exception:
    d = {}
d[os.environ['SID']] = int(os.environ['COUNT'])
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or '.')
with os.fdopen(fd, 'w') as f:
    json.dump(d, f)
os.rename(tmp, path)
PY
}

# ---------------------------------------------------------------------------
# normalize_tool_id — convert raw session tool name to stable URL-safe --tool-id.
# Rules: __ → -- (MCP separator); _ → -; lowercase via tr (Bash 3.2 safe, no python dep).
# Examples: web_fetch→web-fetch; mcp__ctx7__search→mcp--ctx7--search
# tr is used (not python3) so the tool-id — and thus the registry/event ledger
# keys — stay stable regardless of whether python3 is on the cron PATH (WR-05).
# ---------------------------------------------------------------------------
normalize_tool_id() {
  local raw="$1"
  local normalized="${raw//__/--}"
  normalized="${normalized//_/-}"
  printf '%s' "${normalized}" | tr '[:upper:]' '[:lower:]'
}

# ---------------------------------------------------------------------------
# classify_tool_type — return --tool-type value for revenium tools create.
# MCP tool names contain __ (double-underscore) by OpenClaw convention → MCP_SERVER.
# All others are built-in Claude Code tools → CUSTOM.
# The Revenium API enforces a fixed enum: [SDK, MCP_SERVER, AI_SERVICE, REST_API,
# LOCAL_FUNCTION, CUSTOM]. "BUILTIN" is NOT valid and is rejected HTTP 400, so
# built-ins are reported as CUSTOM (the type the existing tenant tools already use).
# ---------------------------------------------------------------------------
classify_tool_type() {
  local name="$1"
  if [[ "${name}" == *"__"* ]]; then
    echo "MCP_SERVER"
  else
    echo "CUSTOM"
  fi
}

# ---------------------------------------------------------------------------
# _register_tool — register a tool in Revenium on first sight (TOOLEV-01/04).
# Idempotent: skip if TOOL:<tool_id> already in TOOL_REGISTRY_LEDGER_FILE.
# 409-as-success backstop: mirrors jobs create (D-06 equivalent).
# Fail-open: returns 0 on all paths; never blocks tool-event emission.
# CRITICAL (mirrors D-12): NEVER touch failed_count/reported_count.
# ---------------------------------------------------------------------------
_register_tool() {
  local tool_name="$1"
  local tool_id="$2"
  local tool_type="$3"

  if grep -q "^TOOL:${tool_id}:" "${TOOL_REGISTRY_LEDGER_FILE}" 2>/dev/null; then
    return 0  # already registered — idempotent skip (anchored: avoid prefix false-match, e.g. read vs read-file)
  fi

  local reg_cmd=( revenium tools create --name "${tool_name}" --tool-id "${tool_id}" \
                  --tool-type "${tool_type}" --quiet )
  [[ -n "${ORG_NAME:-}" ]] && reg_cmd+=(--organization-name "${ORG_NAME}")

  local reg_out reg_exit
  reg_out=$("${reg_cmd[@]}" 2>&1) && reg_exit=0 || reg_exit=$?

  local reg_success=false
  if [[ "${reg_exit}" -eq 0 ]]; then
    reg_success=true
  elif echo "${reg_out}" | grep -qi "409\|already.exist\|conflict"; then
    reg_success=true  # 409-as-success backstop (mirrors jobs create D-06)
  fi

  if [[ "${reg_success}" == "true" ]]; then
    local reg_ts
    reg_ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
    printf 'TOOL:%s:%s\n' "${tool_id}" "${reg_ts}" >> "${TOOL_REGISTRY_LEDGER_FILE}"
    local tool_id_log="${tool_id:0:64}"
    info "Tool registered: name=${tool_name} id=${tool_id_log} type=${tool_type}"
  else
    local tool_id_log="${tool_id:0:64}"
    warn "Tool registration failed: id=${tool_id_log} exit=${reg_exit} — tool-event emission continues"
    # Fail-open: do NOT return non-zero; do NOT block tool-event emission
  fi
  return 0
}

# ---------------------------------------------------------------------------
# _meter_tool_event — emit one revenium meter tool-event per toolCall.id (TOOLEV-02/04).
# Idempotent: skip if TOOLEV:<toolcall_id> already in TOOL_EVENTS_LEDGER_FILE.
# Fail-open: returns 0 on all paths; NEVER touches failed_count/reported_count.
# --success defaults to false in CLI — always pass explicitly (RESEARCH Pitfall 2).
# CRITICAL (TOOLEV-03): NEVER call meter completion or add --operation-type.
# ---------------------------------------------------------------------------
_meter_tool_event() {
  local toolcall_id="$1"
  local tool_id="$2"
  local ts="$3"          # ISO timestamp (from parent assistant message)
  local duration_ms="$4" # integer, may be 0
  local is_error="$5"    # "true" | "false"
  local error_msg="$6"   # may be empty
  local root_sid="$7"

  local ledger_key="TOOLEV:${toolcall_id}"
  if grep -q "^${ledger_key}$" "${TOOL_EVENTS_LEDGER_FILE}" 2>/dev/null; then
    return 0  # already metered — idempotent skip (anchored: avoid prefix false-match on toolCall ids)
  fi

  local ev_cmd=( revenium meter tool-event
    --tool-id     "${tool_id}"
    --duration-ms "${duration_ms}"
    --timestamp   "${ts}"
    --agent       "${REVENIUM_AGENT_PREFIX}${root_sid}"
    --quiet
  )
  # --success defaults to false in CLI — always explicit (RESEARCH Pitfall 2)
  if [[ "${is_error}" == "true" ]]; then
    ev_cmd+=(--success=false)
    [[ -n "${error_msg}" ]] && ev_cmd+=(--error-message "${error_msg}")
  else
    ev_cmd+=(--success)
  fi
  [[ -n "${ORG_NAME:-}" ]] && ev_cmd+=(--organization-name "${ORG_NAME}")

  local ev_out ev_exit
  ev_out=$("${ev_cmd[@]}" 2>&1) && ev_exit=0 || ev_exit=$?

  if [[ "${ev_exit}" -eq 0 ]]; then
    printf '%s\n' "${ledger_key}" >> "${TOOL_EVENTS_LEDGER_FILE}"
    local tool_id_log="${tool_id:0:64}"
    info "Tool event metered: tool_id=${tool_id_log} duration=${duration_ms}ms"
  else
    local tool_id_log="${tool_id:0:64}"
    warn "Tool event failed: id=${tool_id_log} toolcall=${toolcall_id} exit=${ev_exit} — fail-open"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Post a single completion event to Revenium via CLI
# ---------------------------------------------------------------------------
post_to_revenium() {
  local model="$1"
  local provider="$2"
  local input_tokens="$3"
  local output_tokens="$4"
  local cache_read_tokens="$5"
  local cache_creation_tokens="$6"
  local total_tokens="$7"
  local request_time="$8"
  local response_time="$9"
  local duration_ms="${10}"
  local stop_reason="${11}"
  local transaction_id="${12}"
  local model_source="${13}"
  local is_streamed="${14}"
  local trace_id="${15:-}"
  local operation_type="${16:-CHAT}"
  local system_prompt="${17:-}"
  local input_messages="${18:-}"
  local output_response="${19:-}"
  local root_sid="${20:-}"
  local task_type="${21:-unclassified}"
  local agentic_job_id="${22:-}"
  local agentic_job_name="${23:-}"
  local agentic_job_type="${24:-}"

  local cmd=(
    revenium meter completion
    --model "${model}"
    --provider "${provider}"
    --input-tokens "${input_tokens}"
    --output-tokens "${output_tokens}"
    --total-tokens "${total_tokens}"
    --cache-read-tokens "${cache_read_tokens}"
    --cache-creation-tokens "${cache_creation_tokens}"
    --stop-reason "${stop_reason}"
    --request-time "${request_time}"
    --completion-start-time "${request_time}"
    --response-time "${response_time}"
    --request-duration "${duration_ms}"
    --agent "${REVENIUM_AGENT_PREFIX}${root_sid}"
    --task-type "${task_type:-unclassified}"
    --transaction-id "${transaction_id}"
    --operation-type "${operation_type}"
    --quiet
  )

  # Add trace ID to correlate related completions within a conversation turn
  if [[ -n "${trace_id}" ]]; then
    cmd+=(--trace-id "${trace_id}")
  fi

  # Add model source (e.g., "bedrock") if available
  if [[ -n "${model_source}" ]]; then
    cmd+=(--model-source "${model_source}")
  fi

  # Add streaming flag if the API was a stream type
  if [[ "${is_streamed}" == "true" ]]; then
    cmd+=(--is-streamed)
  fi

  # Add organization name if configured
  if [[ -n "${ORG_NAME}" ]]; then
    cmd+=(--organization-name "${ORG_NAME}")
  fi

  # Add system prompt if available (first user message in the session)
  if [[ -n "${system_prompt}" ]]; then
    cmd+=(--system-prompt "${system_prompt}")
  fi

  # Add input messages (the user message that triggered this completion)
  if [[ -n "${input_messages}" ]]; then
    cmd+=(--input-messages "${input_messages}")
  fi

  # Add output response (the assistant's reply content)
  if [[ -n "${output_response}" ]]; then
    cmd+=(--output-response "${output_response}")
  fi

  # Add agentic job flags when capability probe confirmed and id is non-empty (JLIFE-02)
  # Bash-array discipline (T-06-04 / V5): cmd+=(--flag "$val"), never eval/unquoted.
  if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" ]]; then
    cmd+=(--agentic-job-id "${agentic_job_id}")
    [[ -n "${agentic_job_name}" ]] && cmd+=(--agentic-job-name "${agentic_job_name}")
    [[ -n "${agentic_job_type}" ]] && cmd+=(--agentic-job-type "${agentic_job_type}")
  fi

  local cmd_output cmd_exit
  cmd_output=$("${cmd[@]}" 2>&1) && cmd_exit=0 || cmd_exit=$?

  if [[ "${cmd_exit}" -eq 0 ]]; then
    info "Reported: model=${model} in=${input_tokens} out=${output_tokens} cache_read=${cache_read_tokens} cache_write=${cache_creation_tokens}"
    return 0
  else
    warn "Failed to report: model=${model} txId=${transaction_id} exit=${cmd_exit}"
    warn "Command: ${cmd[*]}"
    warn "Output: ${cmd_output}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Process a single session JSONL file
# ---------------------------------------------------------------------------
process_session() {
  local session_file="$1"
  local session_id
  session_id=$(basename "${session_file}" .jsonl)

  # Change 2 (TRACE-01/02): resolve root session id ONCE per session file.
  # Fail-open to own sid (D-05); belt-and-suspenders fallback via :-.
  local root_sid
  root_sid=$(get_root_session_id "${session_id}")
  root_sid="${root_sid:-${session_id}}"

  # Phase 7 (JROLL-01/02/03): resolve root's agentic_job_id ONCE per subagent
  # session.  Root sessions (root_sid == session_id) skip entirely — Phase 6
  # path is byte-identical (D-09).  Env-passing heredoc discipline (T-04-09):
  # ROOT_SID / MARKERS_DIR passed via env, never interpolated into <<'PY'.
  # Latest kind:job wins (D-05 — linear scan, no sort).
  # Bash locals only — nothing added to _cleanup_session_tmp (Pitfall 5).
  local root_aid="" root_job_name="" root_job_type=""
  if [[ "${root_sid}" != "${session_id}" ]]; then
    local _root_resolve
    _root_resolve=$(
      ROOT_SID="${root_sid}" MARKERS_DIR="${MARKERS_DIR}" python3 - <<'PY' 2>/dev/null || true
import json, os
from pathlib import Path
root_sid = os.environ.get('ROOT_SID', '')
markers_dir = os.environ.get('MARKERS_DIR', '')
if root_sid and markers_dir:
    marker_path = Path(markers_dir) / f"{root_sid}.jsonl"
    if marker_path.exists():
        latest_aid = ''
        latest_name = ''
        latest_type = ''
        try:
            with open(marker_path, 'r', encoding='utf-8') as fh:
                for line in fh:
                    line = line.rstrip('\n')
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except (json.JSONDecodeError, ValueError):
                        continue
                    if not isinstance(rec, dict):
                        continue
                    if rec.get('kind') == 'job':
                        aid = rec.get('agentic_job_id') or ''
                        if isinstance(aid, str) and aid:
                            # Sanitize pipe / newline / colon (parity with WR-01 / D-08)
                            for _bad in ('|', '\n', '\r', ':'):
                                aid = aid.replace(_bad, '_')
                            latest_aid = aid
                            latest_name = str(rec.get('job_name', ''))
                            latest_type = str(rec.get('job_type', ''))
        except OSError:
            pass
        if latest_aid:
            print(f"{latest_aid}\t{latest_name}\t{latest_type}")
PY
    )
    _root_resolve="${_root_resolve%%$'\n'*}"
    if [[ -n "${_root_resolve}" ]]; then
      root_aid="${_root_resolve%%$'\t'*}"
      local _rr2="${_root_resolve#*$'\t'}"
      root_job_name="${_rr2%%$'\t'*}"
      root_job_type="${_rr2#*$'\t'}"
    fi
  fi

  # Change 2 (METER-03 / NP-1 performance): read+sort markers ONCE per session
  # (not per completion line — Pitfall 3). Cache sorted list in a temp file.
  # Each line: "<ts>\t<task_type>\t<completion_id>" (completion_id may be empty
  # for legacy markers written before id-stamping was added).
  # WR-01: declare all per-iteration temp files up front and clean them with a
  # single function-scoped helper. A bare `trap ... EXIT` would be overwritten
  # by the second trap (and by every loop iteration), leaking temp files every
  # tick under cron. Instead we rm explicitly on every return path.
  local markers_cache_file jobs_cache_file msg_meta_file="" user_msgs_file=""
  markers_cache_file=$(mktemp "${TMPDIR:-/tmp}/rv-markers.XXXXXX")
  jobs_cache_file=$(mktemp "${TMPDIR:-/tmp}/rv-jobs.XXXXXX")
  _cleanup_session_tmp() {
    rm -f "${markers_cache_file}" "${jobs_cache_file}" "${msg_meta_file}" "${user_msgs_file}"
  }
  local marker_file="${MARKERS_DIR}/${session_id}.jsonl"
  if [[ -f "${marker_file}" ]]; then
    # Parse marker JSONL: branch on kind.
    #   Task markers (no kind, has task_type): emit to markers_cache_file as
    #     "ts<TAB>task_type<TAB>completion_id", sorted by ts (existing format).
    #   Job markers (kind=="job", has agentic_job_id): emit to jobs_cache_file as
    #     "ts<TAB>agentic_job_id<TAB>job_name<TAB>job_type<TAB>status<TAB>failure_reason<TAB>completion_id",
    #     sorted by ts (Pitfall 2 / NP-1).
    # Per-line try/except for malformed lines (T-04-05).
    # Env-passing heredoc discipline: no ${VAR} interpolation inside <<'PY' (T-04-09).
    # Separate cache files keep the existing task correlation engine untouched (NP-1).
    _MARKER_FILE="${marker_file}" \
    _TASKS_CACHE="${markers_cache_file}" \
    _JOBS_CACHE="${jobs_cache_file}" \
    python3 - <<'PY' 2>/dev/null || true
import json, os, sys
mf = os.environ.get('_MARKER_FILE', '')
tasks_out = os.environ.get('_TASKS_CACHE', '')
jobs_out  = os.environ.get('_JOBS_CACHE', '')
task_rows = []
job_rows  = []
try:
    with open(mf, encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if not line: continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if not isinstance(r, dict): continue
            if r.get('kind') == 'job' and r.get('agentic_job_id'):
                # Job marker — emit to jobs cache
                job_rows.append((
                    r.get('ts', ''),
                    r.get('agentic_job_id', ''),
                    r.get('job_name', ''),
                    r.get('job_type', ''),
                    r.get('status', ''),
                    r.get('failure_reason', ''),
                    r.get('completion_id', ''),
                ))
            elif r.get('ts') and r.get('task_type'):
                # Task marker — emit to tasks cache (existing format)
                task_rows.append((r['ts'], r['task_type'], r.get('completion_id', '')))
except Exception:
    pass
task_rows.sort(key=lambda x: x[0])
job_rows.sort(key=lambda x: x[0])
with open(tasks_out, 'a', encoding='utf-8') as f:
    for ts, tt, cid in task_rows:
        f.write(f"{ts}\t{tt}\t{cid}\n")
with open(jobs_out, 'a', encoding='utf-8') as f:
    for ts, jid, jname, jtype, status, fr, cid in job_rows:
        f.write(f"{ts}\t{jid}\t{jname}\t{jtype}\t{status}\t{fr}\t{cid}\n")
PY
  fi

  # ---------------------------------------------------------------------------
  # Jobs sweep — consume job markers independent of completion timing (JLIFE-01/03).
  # The in-loop create/outcome below only fires while processing a NEW completion
  # whose id matches the marker's completion_id. With a 1-minute cron, an arc's
  # mid-arc completions are routinely metered by EARLIER ticks than the arc-end
  # job marker — the matching completion is then TX-ledger-skipped on every later
  # tick and the job is silently never created (observed live 2026-06-13: marker
  # written 23:53:48 pointing at a completion metered minutes earlier; no job).
  # This sweep runs every tick BEFORE the offset early-return, so markers are
  # consumed even when the session has gone quiet:
  #   - create: ledger-gated, 409-as-success, root sessions only (mirrors in-loop)
  #   - outcome: only when the marker's completion_id is empty OR already
  #     TX-ledgered — a still-pending completion keeps D-09 order (create →
  #     stamp → outcome) by leaving the close to the in-loop path this tick.
  # The in-loop blocks stay: they stamp completions and share the same ledger
  # keys, so create/outcome remain exactly-once.
  # CRITICAL (D-12): own locals; never touches failed_count/reported_count;
  # never returns out of process_session.
  if [[ "${JOBS_CLI_CAPABLE}" == "true" && -s "${jobs_cache_file}" \
     && "${root_sid}" == "${session_id}" ]]; then
    local _sw_ts _sw_aid _sw_aid_raw _sw_name _sw_type _sw_status _sw_freason _sw_cid
    while IFS=$'\t' read -r _sw_ts _sw_aid _sw_name _sw_type _sw_status _sw_freason _sw_cid; do
      if [[ -z "${_sw_aid}" ]]; then
        continue
      fi
      # Sanitize pipe/colon (parity with the rollup resolver, WR-01/D-08).
      # Keep the raw form for same-cache lookups (rows store it unsanitized).
      _sw_aid_raw="${_sw_aid}"
      _sw_aid="${_sw_aid//|/_}"
      _sw_aid="${_sw_aid//:/_}"
      local _sw_aid_log="${_sw_aid:0:64}"

      # --- create (ledger-gated, 409-as-success) ---
      if ! grep -q "^JOB:${_sw_aid}:created:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
        local _sw_create_cmd=( revenium jobs create --agentic-job-id "${_sw_aid}" --quiet )
        if [[ -n "${_sw_name}" ]]; then _sw_create_cmd+=(--name "${_sw_name}"); fi
        if [[ -n "${_sw_type}" ]]; then _sw_create_cmd+=(--type "${_sw_type}"); fi
        local _sw_out _sw_exit
        _sw_out=$("${_sw_create_cmd[@]}" 2>&1) && _sw_exit=0 || _sw_exit=$?
        local _sw_ok=false
        if [[ "${_sw_exit}" -eq 0 ]]; then
          _sw_ok=true
        elif echo "${_sw_out}" | grep -qi "409\|already.exist\|conflict"; then
          _sw_ok=true
        fi
        if [[ "${_sw_ok}" == "true" ]]; then
          local _sw_now
          _sw_now=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
          echo "JOB:${_sw_aid}:created:${_sw_now}" >> "${JOBS_LEDGER_FILE}"
          info "Job created (sweep): agentic_job_id=${_sw_aid_log}"
        else
          warn "jobs create failed (sweep): id=${_sw_aid_log} exit=${_sw_exit} — metering continues"
          continue   # no outcome without a confirmed create
        fi
      fi

      # --- stale-open janitor (lifecycle) ---
      # A RUNNING marker with no terminal row for the same job after
      # REVENIUM_JOB_STALE_HOURS (default 24) is an abandoned arc — close it
      # CANCELLED so Revenium isn't left with phantom running jobs. Halted
      # arcs are already closed by handle_halt; this catches walk-aways.
      if [[ "${_sw_status}" == "RUNNING" ]] \
         && ! grep -q "^JOB:${_sw_aid}:outcome:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
        if ! awk -F'\t' -v id="${_sw_aid_raw}" '$2==id && ($5=="SUCCESS"||$5=="FAILED"||$5=="CANCELLED"){f=1} END{exit !f}' "${jobs_cache_file}" 2>/dev/null; then
          local _sw_stale=""
          _sw_stale=$(TS="${_sw_ts}" MAXH="${REVENIUM_JOB_STALE_HOURS:-24}" python3 - <<'PY' 2>/dev/null || true
import os, time
from datetime import datetime
try:
    ts = datetime.fromisoformat(os.environ['TS'].replace('Z', '+00:00'))
    if (time.time() - ts.timestamp()) > float(os.environ['MAXH']) * 3600:
        print('stale')
except Exception:
    pass
PY
)
          if [[ "${_sw_stale}" == "stale" ]]; then
            local _sw_jout _sw_jexit
            _sw_jout=$(revenium jobs outcome "${_sw_aid}" --result CANCELLED --quiet 2>&1) && _sw_jexit=0 || _sw_jexit=$?
            if [[ "${_sw_jexit}" -eq 0 ]] || echo "${_sw_jout}" | grep -qi "409\|already.exist\|conflict"; then
              local _sw_jnow
              _sw_jnow=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
              echo "JOB:${_sw_aid}:outcome:${_sw_jnow}:CANCELLED" >> "${JOBS_LEDGER_FILE}"
              info "Job closed (stale janitor): agentic_job_id=${_sw_aid_log} result=CANCELLED (open > ${REVENIUM_JOB_STALE_HOURS:-24}h)"
            else
              warn "stale-job close failed: id=${_sw_aid_log} exit=${_sw_jexit} — retry next tick"
            fi
          fi
        fi
      fi

      # --- outcome (terminal markers; ledger-gated) ---
      # Residual edge: a marker whose completion_id never gets TX-ledgered
      # (e.g. a usage-less message) defers here forever — accepted: the cid
      # always references a real assistant message harvested from the session.
      if [[ "${_sw_status}" == "SUCCESS" || "${_sw_status}" == "FAILED" || "${_sw_status}" == "CANCELLED" ]] \
         && ! grep -q "^JOB:${_sw_aid}:outcome:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
        if [[ -z "${_sw_cid}" ]] || grep -q "^TX:${_sw_cid}$" "${LEDGER_FILE}" 2>/dev/null; then
          local _sw_outcome_cmd=( revenium jobs outcome "${_sw_aid}" --result "${_sw_status}" --quiet )
          if [[ "${_sw_status}" == "SUCCESS" ]]; then
            _sw_outcome_cmd+=(--outcome-type CONVERTED)
          fi
          if [[ "${_sw_status}" == "FAILED" && -n "${_sw_freason}" ]]; then
            local _sw_meta
            _sw_meta=$(FR="${_sw_freason}" python3 - <<'PY' 2>/dev/null || true
import json, os
fr = os.environ.get('FR', '').strip()
if fr: print(json.dumps({"failure_reason": fr}, separators=(',', ':')))
PY
)
            _sw_meta="${_sw_meta%%$'\n'*}"
            if [[ -n "${_sw_meta}" ]]; then _sw_outcome_cmd+=(--metadata "${_sw_meta}"); fi
          fi
          local _sw_oout _sw_oexit
          _sw_oout=$("${_sw_outcome_cmd[@]}" 2>&1) && _sw_oexit=0 || _sw_oexit=$?
          local _sw_ook=false
          if [[ "${_sw_oexit}" -eq 0 ]]; then
            _sw_ook=true
          elif echo "${_sw_oout}" | grep -qi "409\|already.exist\|conflict"; then
            _sw_ook=true
          fi
          if [[ "${_sw_ook}" == "true" ]]; then
            local _sw_onow
            _sw_onow=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
            echo "JOB:${_sw_aid}:outcome:${_sw_onow}:${_sw_status}" >> "${JOBS_LEDGER_FILE}"
            info "Job closed (sweep): agentic_job_id=${_sw_aid_log} result=${_sw_status}"
          else
            warn "jobs outcome failed (sweep): id=${_sw_aid_log} exit=${_sw_oexit} — retry next tick"
          fi
        fi
      fi
    done < "${jobs_cache_file}"
  fi

  # Get last processed line offset for this session
  local offset total_lines
  offset=$(get_offset "${session_id}")
  # WR-05: count lines the way `tail -n +N` / `read` actually consume them.
  # `wc -l` counts newline characters, so it undercounts by one when the final
  # line has no trailing newline — leaving the offset short and re-yielding a
  # processed line once it later gets terminated. `grep -c ''` counts the final
  # unterminated line too. (Ledger dedup still protects against double-billing,
  # but the offset arithmetic itself must be correct.)
  total_lines=$(grep -c '' "${session_file}" 2>/dev/null || echo 0)

  # Nothing new to process — replaces the old DONE: skip
  if [[ "${offset}" -ge "${total_lines}" ]]; then
    _cleanup_session_tmp
    return 0
  fi

  # Extract system prompt from the first user message in the session
  local system_prompt=""
  system_prompt=$(jq -r 'select(.type=="message") | .message | select(.role=="user") | .content[] | select(.type=="text") | .text' "${session_file}" 2>/dev/null | head -1 || true)
  # Truncate to 500 chars to avoid overly long CLI args
  if [[ ${#system_prompt} -gt 500 ]]; then
    system_prompt="${system_prompt:0:500}..."
  fi

  # Build lookup files for message metadata (bash 3.x compatible — no associative arrays).
  # These temp files replace declare -A and are used for trace ID walks, duration
  # computation, and user message lookups via grep.
  msg_meta_file=$(mktemp "${TMPDIR:-/tmp}/rv-meta.XXXXXX")
  user_msgs_file=$(mktemp "${TMPDIR:-/tmp}/rv-umsg.XXXXXX")

  # msg_meta_file: TAB-separated "id \t parentId \t role \t timestamp"
  jq -r 'select(.type=="message") | [.id // "", .parentId // "", (.message.role // ""), .timestamp // ""] | @tsv' \
    "${session_file}" 2>/dev/null > "${msg_meta_file}" || true

  # user_msgs_file: TAB-separated "id \t text_content"
  # Content has newlines replaced with \n literal to keep one line per message.
  jq -r 'select(.type=="message") | select(.message.role=="user") |
    [.id, ([.message.content[] | select(.type=="text") | .text] | join("\\n"))] | @tsv' \
    "${session_file}" 2>/dev/null > "${user_msgs_file}" || true

  # Helper: look up a field from msg_meta_file by message ID
  # Usage: meta_lookup ID FIELD_NUM  (2=parentId, 3=role, 4=timestamp)
  # WR-04: match the ID as a literal string (awk $1==id), not a grep regex.
  # IDs from .id/.parentId could contain regex metacharacters; a grep BRE would
  # match the wrong rows and corrupt parent-ts lookups, the trace-id walk, and
  # duration computation.
  meta_lookup() {
    awk -F'\t' -v id="$1" -v f="$2" '$1==id{print $f; exit}' "${msg_meta_file}" 2>/dev/null
  }

  # Helper: look up user message text by ID
  user_msg_lookup() {
    awk -F'\t' -v id="$1" '$1==id{sub(/^[^\t]*\t/, ""); print; exit}' "${user_msgs_file}" 2>/dev/null
  }

  local reported_count=0
  local failed_count=0

  while IFS= read -r line; do
    # Only process assistant message lines with usage data
    if ! echo "${line}" | jq -e 'select(.type=="message") | .message | select(.role=="assistant") | .usage' &>/dev/null 2>&1; then
      continue
    fi

    # Extract all fields from the JSONL structure:
    # .message.model = "global.anthropic.claude-sonnet-4-6"
    # .message.provider = "bedrock" (API route, not AI provider)
    # .message.api = "bedrock-converse-stream" (tells us if streaming)
    # .message.usage.input = input tokens
    # .message.usage.output = output tokens
    # .message.usage.cacheRead = cache read tokens
    # .message.usage.cacheWrite = cache write/creation tokens
    # .message.usage.totalTokens = total
    # .message.stopReason = "stop" | "toolUse" | etc.
    # .id = unique message ID (transaction ID)
    # .timestamp = ISO 8601 timestamp

    local raw_model model provider model_source is_streamed
    local input_tokens output_tokens cache_read cache_create
    local timestamp tx_id stop_reason

    raw_model=$(echo "${line}" | jq -r '.message.model // "unknown"')
    model=$(clean_model_name "${raw_model}")
    provider=$(get_provider "${raw_model}")
    model_source=$(echo "${line}" | jq -r '.message.provider // ""')
    local api_type
    api_type=$(echo "${line}" | jq -r '.message.api // ""')
    is_streamed="false"
    [[ "${api_type}" == *"stream"* ]] && is_streamed="true"

    # WR-07: tolerate both observed usage spellings. OpenClaw fixtures vary
    # between the camelCase form (input/output/cacheRead/cacheWrite/totalTokens)
    # and the Anthropic snake_case form (input_tokens/output_tokens/
    # cache_read_input_tokens/cache_creation_input_tokens, no totalTokens).
    # Accept either, and synthesize total_tokens when the key is absent so the
    # zero-usage skip at the bottom of the loop does not silently drop real
    # usage. NOTE: confirm the canonical production schema (HUMAN VERIFY).
    input_tokens=$(echo "${line}" | jq -r '.message.usage.input // .message.usage.input_tokens // 0')
    output_tokens=$(echo "${line}" | jq -r '.message.usage.output // .message.usage.output_tokens // 0')
    cache_read=$(echo "${line}" | jq -r '.message.usage.cacheRead // .message.usage.cache_read_input_tokens // 0')
    cache_create=$(echo "${line}" | jq -r '.message.usage.cacheWrite // .message.usage.cache_creation_input_tokens // 0')
    total_tokens=$(echo "${line}" | jq -r '
      .message.usage as $u
      | ($u.totalTokens
         // $u.total_tokens
         // (((($u.input // $u.input_tokens // 0)
              + ($u.output // $u.output_tokens // 0)
              + ($u.cacheRead // $u.cache_read_input_tokens // 0)
              + ($u.cacheWrite // $u.cache_creation_input_tokens // 0)))))')
    timestamp=$(echo "${line}" | jq -r '.timestamp // empty' 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    tx_id=$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || echo "${session_id}-$(date +%s%N)")
    stop_reason=$(map_stop_reason "$(echo "${line}" | jq -r '.message.stopReason // "stop"')")

    # Change 3 (METER-03 / NP-1 fix): two-phase task_type lookup.
    # Phase A (exact): if any marker in the session carries completion_id matching
    #   this completion's .id, use that marker's task_type immediately.
    # Phase D (fallback): if no id-match (legacy marker without completion_id, or
    #   no marker references this completion), pick the EARLIEST marker whose
    #   marker_ts >= completion_ts (the first marker written after the completion).
    #   This models the real OpenClaw lifecycle where write-marker.sh runs AFTER
    #   the turn's LLM completion, making the marker's ts always later than the
    #   completion it classifies.
    # Default: unclassified when no marker qualifies (A4).
    # Never aborts the tick (T-04-05). Backward-compatible with legacy markers.
    local task_type="unclassified"
    if [[ -s "${markers_cache_file}" ]]; then
      task_type=$(_MARKERS_CACHE="${markers_cache_file}" COMPLETION_TS="${timestamp}" COMPLETION_ID="${tx_id}" python3 - <<'PY' 2>/dev/null || echo "unclassified"
import os
from datetime import datetime, timezone
mc = os.environ.get('_MARKERS_CACHE', '')
cts_raw = os.environ.get('COMPLETION_TS', '')
cid = os.environ.get('COMPLETION_ID', '')
chosen = 'unclassified'

# WR-02: compare parsed datetimes, not raw strings. Markers are written with
# second precision + 'Z' (...00Z) while completion timestamps carry ms
# (...00.000Z). A lexicographic compare ranks 'Z' (0x5A) > '.' (0x2E), so a
# marker that coincides with the completion's second is wrongly excluded.
def parse_ts(s):
    try: return datetime.fromisoformat(s.replace('Z', '+00:00'))
    except Exception: pass
    for fmt in ('%Y-%m-%dT%H:%M:%S.%fZ', '%Y-%m-%dT%H:%M:%SZ'):
        try: return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except Exception: pass
    return None

rows = []
try:
    with open(mc, encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if not line: continue
            parts = line.split('\t', 2)
            if len(parts) < 2: continue
            ts = parts[0]
            tt = parts[1]
            marker_cid = parts[2] if len(parts) > 2 else ''
            rows.append((ts, tt, marker_cid))
except Exception:
    pass

# --- Phase A: exact completion_id match ---
if cid:
    for ts, tt, marker_cid in rows:
        if marker_cid and marker_cid == cid:
            chosen = tt
            break

# --- Phase D: earliest marker at or after completion ts (fallback) ---
if chosen == 'unclassified':
    cts = parse_ts(cts_raw)
    for ts, tt, marker_cid in rows:
        # Skip markers that have a completion_id: they belong to a specific
        # completion and should not bleed into others via timestamp fallback.
        if marker_cid:
            continue
        mts = parse_ts(ts)
        if mts is not None and cts is not None:
            if mts >= cts:
                chosen = tt
                break
        else:
            # Graceful degradation: raw string compare
            if ts >= cts_raw:
                chosen = tt
                break

print(chosen)
PY
      )
    fi
    # 64-char truncation for log injection mitigation (T-04-08)
    local task_type_log="${task_type:0:64}"

    # Per-completion job correlation (JLIFE-02 / D-01).
    # Reuses the SAME completion_id-exact → ts-fallback engine as task_type.
    # Scans jobs_cache_file (from Task 2); resolves agentic_job_id/name/type/status/failure_reason.
    # All fields default empty when no job row matches (fail-open, D-12).
    # Prior-tick already-TX:-ledgered completions never reach here (continue above).
    local agentic_job_id="" agentic_job_name="" agentic_job_type="" job_status="" failure_reason=""
    if [[ "${JOBS_CLI_CAPABLE}" == "true" && -s "${jobs_cache_file}" ]]; then
      local job_resolve_result
      job_resolve_result=$(_JOBS_CACHE="${jobs_cache_file}" COMPLETION_TS="${timestamp}" COMPLETION_ID="${tx_id}" python3 - <<'PY' 2>/dev/null || true
import os
from datetime import datetime, timezone

jc  = os.environ.get('_JOBS_CACHE', '')
cts_raw = os.environ.get('COMPLETION_TS', '')
cid = os.environ.get('COMPLETION_ID', '')

# WR-02: parse ts rather than lexicographic compare (Pitfall 5)
def parse_ts(s):
    try: return datetime.fromisoformat(s.replace('Z', '+00:00'))
    except Exception: pass
    for fmt in ('%Y-%m-%dT%H:%M:%S.%fZ', '%Y-%m-%dT%H:%M:%SZ'):
        try: return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except Exception: pass
    return None

# Job cache row: ts|agentic_job_id|job_name|job_type|status|failure_reason|completion_id
rows = []
try:
    with open(jc, encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if not line: continue
            parts = line.split('\t', 6)
            if len(parts) < 2: continue
            rows.append(parts)
except Exception:
    pass

chosen = None

# --- Phase A: exact completion_id match ---
if cid:
    for parts in rows:
        row_cid = parts[6] if len(parts) > 6 else ''
        if row_cid and row_cid == cid:
            chosen = parts
            break

# --- Phase C: open-arc interval match (lifecycle, 2026-06-13) ---
# A RUNNING marker opens an arc at its ts; the arc closes at the first
# terminal-status row for the same agentic_job_id (or stays open). A completion
# whose ts falls inside an open interval stamps to that job — this is what
# gives mid-arc spend per-job attribution (end-only markers land too late for
# completions metered by earlier ticks). Latest-starting open interval wins.
# RUNNING markers carry no completion_id, so Phase A never consumes them.
# The synthesized row carries EMPTY status/failure: mid-arc completions must
# stamp, never close (the terminal marker or the sweep does the closing).
if chosen is None:
    cts = parse_ts(cts_raw)
    if cts is not None:
        terminal_ts = {}
        for parts in rows:
            st = parts[4] if len(parts) > 4 else ''
            if st in ('SUCCESS', 'FAILED', 'CANCELLED'):
                jid = parts[1]
                t = parse_ts(parts[0])
                if t is not None and (jid not in terminal_ts or t < terminal_ts[jid]):
                    terminal_ts[jid] = t
        best = None
        best_ts = None
        for parts in rows:
            st = parts[4] if len(parts) > 4 else ''
            if st != 'RUNNING':
                continue
            ots = parse_ts(parts[0])
            if ots is None or ots > cts:
                continue
            jid = parts[1]
            tts = terminal_ts.get(jid)
            if tts is not None and tts < cts:
                continue  # arc closed before this completion
            if best_ts is None or ots > best_ts:
                best_ts = ots
                best = parts
        if best is not None:
            chosen = [best[0], best[1], best[2], best[3], '', '', '']

# --- Phase D: earliest job marker at or after completion ts (fallback) ---
if chosen is None:
    cts = parse_ts(cts_raw)
    for parts in rows:
        row_cid = parts[6] if len(parts) > 6 else ''
        if row_cid:
            continue  # id-keyed: don't bleed via timestamp
        if (parts[4] if len(parts) > 4 else '') == 'RUNNING':
            continue  # open markers are interval-matched in Phase C only
        ts = parts[0]
        mts = parse_ts(ts)
        if mts is not None and cts is not None:
            if mts >= cts:
                chosen = parts
                break
        else:
            if ts >= cts_raw:
                chosen = parts
                break

if chosen is not None:
    jid    = chosen[1] if len(chosen) > 1 else ''
    jname  = chosen[2] if len(chosen) > 2 else ''
    jtype  = chosen[3] if len(chosen) > 3 else ''
    status = chosen[4] if len(chosen) > 4 else ''
    fr     = chosen[5] if len(chosen) > 5 else ''
    print(f"{jid}\t{jname}\t{jtype}\t{status}\t{fr}")
else:
    print('\t\t\t\t')
PY
)
      # Parse tab-separated result (job_id, job_name, job_type, status, failure_reason)
      agentic_job_id="${job_resolve_result%%$'\t'*}"
      local _jrest="${job_resolve_result#*$'\t'}"
      agentic_job_name="${_jrest%%$'\t'*}"
      _jrest="${_jrest#*$'\t'}"
      agentic_job_type="${_jrest%%$'\t'*}"
      _jrest="${_jrest#*$'\t'}"
      job_status="${_jrest%%$'\t'*}"
      failure_reason="${_jrest#*$'\t'}"
      # 64-char truncation for log injection mitigation (T-06-06 / T-04-08)
      local agentic_job_id_log="${agentic_job_id:0:64}"
      if [[ -n "${agentic_job_id}" ]]; then
        info "Job correlation: tx_id=${tx_id} agentic_job_id=${agentic_job_id_log}"
      fi
    fi

    # Phase 7 (JROLL-01/02/03): subagent override — replace same-session
    # correlation with root's job values.  For root sessions (root_sid ==
    # session_id) this block is skipped entirely — Phase 6 path is byte-identical.
    if [[ "${root_sid}" != "${session_id}" ]]; then
      if [[ -n "${root_aid}" ]]; then
        # Inherit root's job for this completion (JROLL-01 / D-02)
        agentic_job_id="${root_aid}"
        agentic_job_name="${root_job_name}"
        agentic_job_type="${root_job_type}"
      else
        # Race window or orphan subagent — omit entirely (JROLL-02 / D-03 / D-04 / D-07)
        # NEVER substitute the subagent's own orphan id (D-04 safety invariant).
        agentic_job_id=""
        agentic_job_name=""
        agentic_job_type=""
      fi
      if [[ -n "${root_aid}" ]]; then
        local root_aid_log="${root_aid:0:64}"
        info "Subagent job rollup: session=${session_id} root=${root_sid} root_aid=${root_aid_log}"
      fi
    fi

    # ---------------------------------------------------------------------------
    # jobs create — in-loop, ledger-gated, 409-as-success, fail-open (JLIFE-01/05)
    # Fires whenever a closing job marker exists for this session (non-empty
    # agentic_job_id resolved above). Gated on JOBS_CLI_CAPABLE (D-11).
    # CRITICAL (D-12 / Pitfall 1): own exit locals; NEVER touch failed_count/
    # reported_count; NEVER return/exit process_session; NEVER reach CR-02 gate.
    # ---------------------------------------------------------------------------
    if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" \
       && "${root_sid}" == "${session_id}" ]]; then
      if grep -q "^JOB:${agentic_job_id}:created:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
        :   # already created — idempotent skip (D-06)
      else
        local jobs_cmd=( revenium jobs create --agentic-job-id "${agentic_job_id}" --quiet )
        [[ -n "${agentic_job_name}" ]] && jobs_cmd+=(--name "${agentic_job_name}")
        [[ -n "${agentic_job_type}" ]] && jobs_cmd+=(--type "${agentic_job_type}")
        # D-04: NO --environment

        local jobs_cmd_output jobs_cmd_exit
        jobs_cmd_output=$("${jobs_cmd[@]}" 2>&1) && jobs_cmd_exit=0 || jobs_cmd_exit=$?

        local jobs_success=false
        if [[ "${jobs_cmd_exit}" -eq 0 ]]; then
          jobs_success=true
        elif echo "${jobs_cmd_output}" | grep -qi "409\|already.exist\|conflict"; then
          jobs_success=true   # 409-as-success backstop (D-06)
        fi

        if [[ "${jobs_success}" == "true" ]]; then
          local jobs_now_ts
          jobs_now_ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
          echo "JOB:${agentic_job_id}:created:${jobs_now_ts}" >> "${JOBS_LEDGER_FILE}"
          info "Job created: agentic_job_id=${agentic_job_id_log}"
        else
          warn "jobs create failed: id=${agentic_job_id_log} exit=${jobs_cmd_exit} — metering continues"
        fi
      fi
    fi

    # Compute request time (parent message timestamp) and duration in ms.
    # The parent's timestamp is when the request was dispatched; this message's
    # timestamp is when the response arrived.
    local request_time="${timestamp}"
    local duration_ms=0
    local parent_id_for_ts parent_ts
    parent_id_for_ts=$(echo "${line}" | jq -r '.parentId // empty' 2>/dev/null || true)
    if [[ -n "${parent_id_for_ts}" ]]; then
      parent_ts=$(meta_lookup "${parent_id_for_ts}" 4)
      if [[ -n "${parent_ts}" ]]; then
        request_time="${parent_ts}"
        # Env-passing heredoc discipline (T-04-09): session timestamps are
        # untrusted; never interpolate them into the python program string.
        duration_ms=$(REQ_TS="${request_time}" RESP_TS="${timestamp}" python3 - <<'PY' 2>/dev/null || echo 0
import os
from datetime import datetime, timezone
def parse_ts(s):
    try: return datetime.fromisoformat(s.replace('Z', '+00:00'))
    except Exception: pass
    for fmt in ('%Y-%m-%dT%H:%M:%S.%fZ', '%Y-%m-%dT%H:%M:%SZ'):
        try: return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except Exception: pass
    return None
t1 = parse_ts(os.environ.get('REQ_TS', ''))
t2 = parse_ts(os.environ.get('RESP_TS', ''))
if t1 and t2:
    print(max(0, int((t2 - t1).total_seconds() * 1000)))
else:
    print(0)
PY
)
      fi
    fi

    # Determine operation type from message content:
    #   TOOL_CALL — completion invokes tools (stopReason=toolUse)
    #   CHAT      — regular text response
    local raw_stop_reason operation_type="CHAT"
    raw_stop_reason=$(echo "${line}" | jq -r '.message.stopReason // "stop"')
    if [[ "${raw_stop_reason}" == "toolUse" || "${raw_stop_reason}" == "tool_use" ]]; then
      operation_type="TOOL_CALL"
    fi

    # Walk the parentId chain to find the originating user message (trace ID).
    # This correlates all assistant completions within a single conversation turn.
    local trace_id=""
    local walk_id="${tx_id}"
    local walk_i=0
    while [[ "${walk_i}" -lt 50 ]]; do  # cap at 50 hops to avoid infinite loops
      walk_i=$((walk_i + 1))
      local walk_parent
      walk_parent=$(meta_lookup "${walk_id}" 2)
      if [[ -z "${walk_parent}" ]]; then
        break
      fi
      local walk_role
      walk_role=$(meta_lookup "${walk_parent}" 3)
      if [[ "${walk_role}" == "user" ]]; then
        trace_id="${walk_parent}"
        break
      fi
      walk_id="${walk_parent}"
    done
    # Fall back to session ID if no user message found in the chain
    trace_id="${trace_id:-${session_id}}"

    # Look up the user message that triggered this completion via parentId
    local parent_id input_msgs_json=""
    parent_id=$(echo "${line}" | jq -r '.parentId // empty' 2>/dev/null || true)
    if [[ -n "${parent_id}" ]]; then
      local user_text
      user_text=$(user_msg_lookup "${parent_id}")
      if [[ -n "${user_text}" ]]; then
        # Format as JSON array with single message object
        input_msgs_json=$(python3 -c "
import json, sys
text = sys.stdin.read()
# Truncate to 1000 chars
if len(text) > 1000:
    text = text[:1000] + '...'
print(json.dumps([{'role': 'user', 'content': text}]))
" <<< "${user_text}" 2>/dev/null || true)
      fi
    fi

    # Extract the assistant's response text content
    local output_resp=""
    output_resp=$(echo "${line}" | jq -r '[.message.content[] | select(.type=="text") | .text] | join("\n")' 2>/dev/null || true)
    # Truncate to 1000 chars
    if [[ ${#output_resp} -gt 1000 ]]; then
      output_resp="${output_resp:0:1000}..."
    fi

    # Skip zero-usage lines
    if [[ "${total_tokens}" -eq 0 ]]; then
      continue
    fi

    # Skip already-reported transactions
    if grep -q "^TX:${tx_id}$" "${LEDGER_FILE}" 2>/dev/null; then
      continue
    fi

    if post_to_revenium \
        "${model}" "${provider}" \
        "${input_tokens}" "${output_tokens}" \
        "${cache_read}" "${cache_create}" \
        "${total_tokens}" \
        "${request_time:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
        "${timestamp:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
        "${duration_ms}" \
        "${stop_reason}" "${tx_id}" \
        "${model_source}" "${is_streamed}" \
        "${trace_id}" "${operation_type}" \
        "${system_prompt}" "${input_msgs_json}" "${output_resp}" \
        "${root_sid}" "${task_type:-unclassified}" \
        "${agentic_job_id}" "${agentic_job_name}" "${agentic_job_type}"; then
      echo "TX:${tx_id}" >> "${LEDGER_FILE}"
      ((reported_count++)) || true
    else
      ((failed_count++)) || true
    fi

    # ---------------------------------------------------------------------------
    # jobs outcome — in-loop, create-confirmed gate, fail-open (JLIFE-03/05)
    # Fires after post_to_revenium (D-09: create → stamp → outcome).
    # Three gates: (1) already closed (idempotent skip); (2) create not confirmed
    # yet (defer/warn, retry next tick, Pitfall 3); (3) else proceed.
    # CRITICAL (D-12 / Pitfall 1): own exit locals; NEVER touch failed_count/
    # reported_count; NEVER return/exit process_session; NEVER reach CR-02 gate.
    # JOUT-01: SUCCESS arcs map to --outcome-type CONVERTED (ports Hermes) so the
    # job's business Outcome Type is not left at Revenium's PENDING default;
    # FAILED/CANCELLED carry no --outcome-type. D-08: failure_reason via
    # --metadata FAILED-only.
    # ---------------------------------------------------------------------------
    # Lifecycle: job_status is empty for completions stamped to an OPEN arc
    # (Phase C) — they must never close the job; the terminal marker does.
    if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" \
       && -n "${job_status}" \
       && "${root_sid}" == "${session_id}" ]]; then
      if grep -q "^JOB:${agentic_job_id}:outcome:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
        :   # already closed — idempotent skip (D-09)
      elif ! grep -q "^JOB:${agentic_job_id}:created:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
        warn "outcome deferred: id=${agentic_job_id_log} — create not yet confirmed (retry next tick)"
      else
        local outcome_cmd=( revenium jobs outcome "${agentic_job_id}" --result "${job_status}" --quiet )
        # JOUT-01: business outcome — a SUCCESS arc maps to CONVERTED so the job's
        # Outcome Type is not left at Revenium's PENDING default. SUCCESS only;
        # FAILED/CANCELLED carry no --outcome-type (Revenium default applies).
        if [[ "${job_status}" == "SUCCESS" ]]; then
          outcome_cmd+=(--outcome-type CONVERTED)
        fi
        # D-08: failure_reason via --metadata only for FAILED status, json.dumps via env heredoc.
        # T-06-08: agent-supplied prose may contain quotes/braces — json.dumps is the ONLY safe path.
        local outcome_metadata=""
        if [[ "${job_status}" == "FAILED" && -n "${failure_reason}" ]]; then
          outcome_metadata=$(FR="${failure_reason}" python3 - <<'PY' 2>/dev/null || true
import json, os
fr = os.environ.get('FR', '').strip()
if fr: print(json.dumps({"failure_reason": fr}, separators=(',', ':')))
PY
)
          outcome_metadata="${outcome_metadata%%$'\n'*}"
          [[ -n "${outcome_metadata}" ]] && outcome_cmd+=(--metadata "${outcome_metadata}")
        fi

        local outcome_cmd_output outcome_cmd_exit
        outcome_cmd_output=$("${outcome_cmd[@]}" 2>&1) && outcome_cmd_exit=0 || outcome_cmd_exit=$?

        local outcome_success=false
        if [[ "${outcome_cmd_exit}" -eq 0 ]]; then
          outcome_success=true
        elif echo "${outcome_cmd_output}" | grep -qi "409\|already.exist\|conflict"; then
          outcome_success=true   # 409-as-success backstop (D-06)
        fi

        if [[ "${outcome_success}" == "true" ]]; then
          local outcome_now_ts
          outcome_now_ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
          echo "JOB:${agentic_job_id}:outcome:${outcome_now_ts}:${job_status}" >> "${JOBS_LEDGER_FILE}"
          info "Outcome reported: agentic_job_id=${agentic_job_id_log} result=${job_status}"
        else
          warn "outcome failed: id=${agentic_job_id_log} exit=${outcome_cmd_exit} — retries next tick"
        fi
      fi
    fi

  done < <(tail -n +$((offset + 1)) "${session_file}")

  if [[ "${reported_count}" -gt 0 ]]; then
    info "Session ${session_id}: reported ${reported_count} events, ${failed_count} failures"
  fi

  # ---------------------------------------------------------------------------
  # toolCall scan loop — AFTER completion metering (TOOLEV-04 sequencing rule).
  # Scans the same session file for toolCall content items; for each:
  #   1. _register_tool (create-once, registry ledger gated)
  #   2. _meter_tool_event (at-most-once, tool-events ledger gated)
  # CRITICAL: NEVER touch failed_count/reported_count; NEVER return/exit.
  # Gated on TOOLS_CLI_CAPABLE (TOOLEV-04).
  # ---------------------------------------------------------------------------
  if [[ "${TOOLS_CLI_CAPABLE}" == "true" ]]; then
    local tool_scan_tmp
    tool_scan_tmp=$(mktemp)

    SESSION_FILE="${session_file}" python3 - <<'PY' 2>/dev/null > "${tool_scan_tmp}" || true
import json, os
from datetime import datetime, timezone

sf = os.environ.get('SESSION_FILE', '')

def parse_ts(s):
    try: return datetime.fromisoformat(s.replace('Z', '+00:00'))
    except Exception: pass
    for fmt in ('%Y-%m-%dT%H:%M:%S.%fZ', '%Y-%m-%dT%H:%M:%SZ'):
        try: return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except Exception: pass
    return None

tool_calls = {}   # toolcall_id -> {name, parent_msg_ts}
tool_results = {} # toolcall_id -> {result_ts, is_error, error_msg}
try:
    with open(sf, encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if not line: continue
            try: r = json.loads(line)
            except: continue
            if r.get('type') != 'message': continue
            msg = r.get('message', {})
            if msg.get('role') == 'assistant':
                for item in msg.get('content', []):
                    if item.get('type') == 'toolCall' and item.get('id'):
                        tool_calls[item['id']] = {
                            'name': item.get('name', 'unknown'),
                            'parent_msg_ts': r.get('timestamp', ''),
                        }
            elif msg.get('role') == 'toolResult':
                tc_id = msg.get('toolCallId')
                if tc_id:
                    err_text = ''
                    if msg.get('isError'):
                        for c in msg.get('content', []):
                            if c.get('type') == 'text':
                                err_text = c.get('text', '')[:256]
                                break
                    # Strip newlines/tabs/field-separator so a multi-line error
                    # can never split into a spurious TSV row (WR-02) or shift fields.
                    for _ch in ('\n', '\r', '\t', '\x1f'):
                        err_text = err_text.replace(_ch, ' ')
                    tool_results[tc_id] = {
                        'result_ts': r.get('timestamp', ''),
                        'is_error': 'true' if msg.get('isError') else 'false',
                        'error_msg': err_text,
                    }
except Exception:
    pass
for tc_id, tc in tool_calls.items():
    tr = tool_results.get(tc_id, {})
    start_ts = parse_ts(tc['parent_msg_ts'])
    end_ts = parse_ts(tr.get('result_ts', ''))
    duration_ms = 0
    if start_ts and end_ts:
        duration_ms = max(0, int((end_ts - start_ts).total_seconds() * 1000))
    # Join with \x1f (unit separator), NOT \t: read's IFS treats tab as
    # whitespace and COLLAPSES empty fields, which would shift every column
    # whenever a tool name (or other middle field) is empty. \x1f is
    # non-whitespace, so empty fields are preserved positionally.
    print('\x1f'.join([
        tc_id, tc['name'], tc['parent_msg_ts'],
        str(duration_ms), tr.get('is_error', 'false'), tr.get('error_msg', ''),
    ]))
PY

    while IFS=$'\x1f' read -r tc_id tool_name parent_ts duration_ms is_error error_msg; do
      [[ -z "${tc_id}" ]] && continue
      # Skip toolCalls with no usable tool name — registering / metering an empty
      # --tool-id produces garbage rows (tools create fails, tool-event is noise).
      [[ -z "${tool_name}" || "${tool_name}" == "unknown" ]] && continue
      local tool_id tool_type
      tool_id=$(normalize_tool_id "${tool_name}")
      tool_type=$(classify_tool_type "${tool_name}")
      [[ -z "${tool_id}" ]] && continue
      # Sanitize before ledger key / log (T-04-08): 64-char truncation applied in helpers
      _register_tool "${tool_name}" "${tool_id}" "${tool_type}"
      _meter_tool_event "${tc_id}" "${tool_id}" "${parent_ts:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
        "${duration_ms:-0}" "${is_error:-false}" "${error_msg:-}" "${root_sid}"
    done < "${tool_scan_tmp}"

    rm -f "${tool_scan_tmp}"
  fi

  # Persist the line offset so next run skips already-processed lines.
  # CR-02: only advance past lines that were all handled. If any completion
  # failed to post (network/API/auth transient), do NOT advance — leave the
  # offset so those lines are re-scanned next tick. Re-processing succeeded
  # lines is safe because the ledger (TX:) dedups them, so no double-billing.
  if [[ "${failed_count}" -eq 0 ]]; then
    set_offset "${session_id}" "${total_lines}"
  else
    warn "Session ${session_id}: ${failed_count} failure(s) — not advancing offset (will retry next tick)"
  fi

  # WR-01: clean this iteration's temp files before the next session.
  _cleanup_session_tmp
}

# ---------------------------------------------------------------------------
# handle_halt — Account-level halt handler (Phase 8 / JHALT-01/02 / D-02).
# Runs ONCE per tick, after the per-session loop, inside main().
# Whole function runs only when JOBS_CLI_CAPABLE==true (D-10).
# Non-fatal: any failure is warn-logged; main() always continues.
#
# Steps:
#   1. Read halt state from guardrail-status.json (fail-open on error).
#   2. Short-circuit when not halted or haltedAt is empty.
#   3. Exactly-once gate: JOB:halt:<haltedAt> in jobs ledger -> skip (D-03).
#   4. Derive deterministic synthetic id: sha1(haltedAt)[:4] (D-09).
#   5. Resolve open jobs from ledger only (created but no outcome) (D-06).
#   6. CANCELLED-close loop: for each open job, outcome CANCELLED (JHALT-01).
#      OR synthetic fallback when open-count was zero (JHALT-02 / D-05 / D-08).
#   7. On success, append JOB:halt:<haltedAt> gate (D-03).
# ---------------------------------------------------------------------------
handle_halt() {
  # --- Step 1: Read halt state from guardrail-status.json (fail-open) ---
  # Env-passing python3 heredoc discipline (T-04-09 / T-08-04):
  # GUARDRAIL_STATUS_FILE is passed via env; <<'PY' single-quoted delimiter
  # prevents any bash expansion inside the heredoc.
  local HALT_STATUS
  HALT_STATUS=$(
    GUARDRAIL_STATUS_FILE="${SKILL_DIR}/guardrail-status.json" \
    python3 - <<'PY' 2>/dev/null || true
import json, os
status_file = os.environ.get('GUARDRAIL_STATUS_FILE', '')
try:
    data = json.load(open(status_file, encoding='utf-8'))
    halted = 'true' if data.get('halted') else 'false'
    halted_at = data.get('haltedAt', '')
    halted_rule = data.get('haltedRule') or {}
    halted_rule_name = halted_rule.get('name', '') if isinstance(halted_rule, dict) else ''
    print(f"HALTED={halted}")
    print(f"HALTED_AT={halted_at}")
    print(f"HALTED_RULE_NAME={halted_rule_name}")
except Exception:
    print("HALTED=false")
    print("HALTED_AT=")
    print("HALTED_RULE_NAME=")
PY
  ) || true

  local HALTED HALTED_AT HALTED_RULE_NAME
  HALTED=$(echo "${HALT_STATUS}" | sed -n 's/^HALTED=//p')
  HALTED_AT=$(echo "${HALT_STATUS}" | sed -n 's/^HALTED_AT=//p')
  HALTED_RULE_NAME=$(echo "${HALT_STATUS}" | sed -n 's/^HALTED_RULE_NAME=//p')

  # --- Step 2: Short-circuit when not halted or haltedAt is empty ---
  if [[ "${HALTED}" != "true" || -z "${HALTED_AT}" ]]; then
    return 0
  fi

  # --- Step 3: Exactly-once gate (D-03) ---
  if grep -q "^JOB:halt:${HALTED_AT}$" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
    return 0   # halt already processed this haltedAt — idempotent skip
  fi

  # --- Step 4: Derive deterministic synthetic id (D-09 / T-08-05) ---
  # haltedAt passes through env; sha1 hex slice is always [a-f0-9]{4} (injection-safe).
  local HALT_HEX
  HALT_HEX=$(
    HALTED_AT="${HALTED_AT}" \
    python3 - <<'PY' 2>/dev/null || true
import hashlib, os
halted_at = os.environ.get('HALTED_AT', '')
h = hashlib.sha1(halted_at.encode('utf-8')).hexdigest()
print(h[:4])
PY
  ) || true
  local synth_id="guardrail-halt-${HALT_HEX}"

  # --- Step 5: Resolve open jobs from ledger only (D-06 / D-07) ---
  # Open job = JOB:<id>:created: line with no matching JOB:<id>:outcome: line.
  # Env-passing heredoc discipline; fail-open on exception (prints nothing).
  # Do NOT read MARKERS_DIR for this (markers can lead the ledger — D-06).
  local OPEN_JOBS
  OPEN_JOBS=$(
    JOBS_LEDGER_FILE="${JOBS_LEDGER_FILE}" \
    python3 - <<'PY' 2>/dev/null || true
import os, re
ledger = os.environ.get('JOBS_LEDGER_FILE', '')
created = set()
closed = set()
try:
    for line in open(ledger, encoding='utf-8'):
        line = line.strip()
        m = re.match(r'^JOB:([^:]+):created:', line)
        if m: created.add(m.group(1))
        m = re.match(r'^JOB:([^:]+):outcome:', line)
        if m: closed.add(m.group(1))
except Exception:
    pass
for jid in sorted(created - closed):
    print(jid)
PY
  ) || true

  local open_count=0
  local open_job_id
  while IFS= read -r open_job_id; do
    [[ -n "${open_job_id}" ]] && ((open_count++)) || true
  done <<< "${OPEN_JOBS}"

  # --- Step 6a: CANCELLED-close loop (JHALT-01 / D-04 / D-08) ---
  # Close ALL open jobs CANCELLED. Synthetic fallback ONLY when open-count was 0.
  local halt_ok=true
  if [[ "${open_count}" -gt 0 ]]; then
    while IFS= read -r open_job_id; do
      [[ -z "${open_job_id}" ]] && continue
      # Per-job outcome idempotency gate (mirrors Phase 6 line 946)
      if grep -q "^JOB:${open_job_id}:outcome:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
        continue   # already closed — idempotent skip
      fi
      local halt_outcome_cmd=( revenium jobs outcome "${open_job_id}" --result CANCELLED --quiet )
      local halt_outcome_output halt_outcome_exit
      halt_outcome_output=$("${halt_outcome_cmd[@]}" 2>&1) && halt_outcome_exit=0 || halt_outcome_exit=$?
      local halt_outcome_success=false
      if [[ "${halt_outcome_exit}" -eq 0 ]]; then
        halt_outcome_success=true
      elif echo "${halt_outcome_output}" | grep -qi "409\|already.exist\|conflict"; then
        halt_outcome_success=true   # 409-as-success backstop
      fi
      if [[ "${halt_outcome_success}" == "true" ]]; then
        local halt_outcome_ts
        halt_outcome_ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
        echo "JOB:${open_job_id}:outcome:${halt_outcome_ts}:CANCELLED" >> "${JOBS_LEDGER_FILE}"
        info "Halt: closed job CANCELLED: id=${open_job_id}"
      else
        warn "Halt: outcome CANCELLED failed: id=${open_job_id} exit=${halt_outcome_exit} — will retry next tick"
        halt_ok=false
      fi
    done <<< "${OPEN_JOBS}"

  else
    # --- Step 6b: Synthetic fallback (JHALT-02 / D-05 / D-08 / D-09) ---
    # ONLY when open-count was 0 — never both paths (D-05/D-08).
    local synth_name="Interrupted by guardrail halt${HALTED_RULE_NAME:+ (${HALTED_RULE_NAME})}"

    # Synthetic create — ledger-gated (idempotent on tick-interrupted create)
    if ! grep -q "^JOB:${synth_id}:created:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
      local synth_create_cmd=( revenium jobs create --agentic-job-id "${synth_id}" \
        --name "${synth_name}" --type "interrupted" --quiet )
      local synth_create_output synth_create_exit
      synth_create_output=$("${synth_create_cmd[@]}" 2>&1) && synth_create_exit=0 || synth_create_exit=$?
      local synth_create_success=false
      if [[ "${synth_create_exit}" -eq 0 ]]; then
        synth_create_success=true
      elif echo "${synth_create_output}" | grep -qi "409\|already.exist\|conflict"; then
        synth_create_success=true
      fi
      if [[ "${synth_create_success}" == "true" ]]; then
        local synth_create_ts
        synth_create_ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
        echo "JOB:${synth_id}:created:${synth_create_ts}" >> "${JOBS_LEDGER_FILE}"
        info "Halt: synthetic interrupted job created: id=${synth_id}"
      else
        warn "Halt: synthetic create failed: id=${synth_id} exit=${synth_create_exit} — will retry next tick"
        halt_ok=false
      fi
    fi

    # Synthetic outcome — ledger-gated (idempotent on tick-interrupted outcome)
    if [[ "${halt_ok}" == "true" ]] && \
       grep -q "^JOB:${synth_id}:created:" "${JOBS_LEDGER_FILE}" 2>/dev/null && \
       ! grep -q "^JOB:${synth_id}:outcome:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
      local synth_outcome_cmd=( revenium jobs outcome "${synth_id}" --result CANCELLED --quiet )
      local synth_outcome_output synth_outcome_exit
      synth_outcome_output=$("${synth_outcome_cmd[@]}" 2>&1) && synth_outcome_exit=0 || synth_outcome_exit=$?
      local synth_outcome_success=false
      if [[ "${synth_outcome_exit}" -eq 0 ]]; then
        synth_outcome_success=true
      elif echo "${synth_outcome_output}" | grep -qi "409\|already.exist\|conflict"; then
        synth_outcome_success=true
      fi
      if [[ "${synth_outcome_success}" == "true" ]]; then
        local synth_outcome_ts
        synth_outcome_ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
        echo "JOB:${synth_id}:outcome:${synth_outcome_ts}:CANCELLED" >> "${JOBS_LEDGER_FILE}"
        info "Halt: synthetic interrupted job closed CANCELLED: id=${synth_id}"
      else
        warn "Halt: synthetic outcome CANCELLED failed: id=${synth_id} exit=${synth_outcome_exit} — will retry next tick"
        halt_ok=false
      fi
    fi
  fi

  # --- Step 7: Append halt gate (D-03) ---
  # ONLY on success (all terminal records written or 409-confirmed).
  # On hard failure, do NOT append so halt retries next tick.
  if [[ "${halt_ok}" == "true" ]]; then
    echo "JOB:halt:${HALTED_AT}" >> "${JOBS_LEDGER_FILE}"
    info "Halt: processed halt at haltedAt=${HALTED_AT} (gate written)"
  else
    warn "Halt: one or more jobs calls failed — JOB:halt gate NOT written (will retry next tick)"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  info "=== Revenium Metering Reporter starting ==="

  if [[ ! -d "${SESSIONS_DIR}" ]]; then
    SESSIONS_DIR=$(find "${OPENCLAW_HOME}" -name "*.jsonl" -path "*/sessions/*" \
      -exec dirname {} \; 2>/dev/null | sort -u | head -1 || true)
    if [[ -z "${SESSIONS_DIR}" ]]; then
      warn "No session files found. OpenClaw may not have run yet."
      exit 0
    fi
    info "Found sessions at: ${SESSIONS_DIR}"
  fi

  local total_files=0
  while IFS= read -r -d '' session_file; do
    ((total_files++)) || true
    process_session "${session_file}"
  done < <(find "${SESSIONS_DIR}" -name "*.jsonl" -print0 2>/dev/null)

  # Account-level halt handler (Phase 8 / D-02): runs once per tick, after the
  # per-session loop. Non-fatal: any error is warn-logged; main() continues.
  # The entire handler is inside the JOBS_CLI_CAPABLE guard (D-10).
  if [[ "${JOBS_CLI_CAPABLE}" == "true" ]]; then
    handle_halt || warn "Halt handler encountered an unexpected error — metering unaffected"
  fi

  info "=== Done. Processed ${total_files} session file(s). ==="
}

# ---------------------------------------------------------------------------
# JOBS_CLI_CAPABLE — one-time dual capability probe per cron tick (D-11).
# Set true only if BOTH `revenium jobs --help` exits 0 AND
# `revenium meter completion --help` output contains --agentic-job-id.
# On probe failure, warn once and leave JOBS_CLI_CAPABLE=false so all job
# work is skipped; metering ships byte-identical to v1.0.
# Probe runs ONCE at startup (before main); the boolean is cached for the
# whole tick and read by per-completion stamping and Plan 03's create/outcome.
# ---------------------------------------------------------------------------
JOBS_CLI_CAPABLE=false
if revenium jobs --help >/dev/null 2>&1 && \
   revenium meter completion --help 2>&1 | grep -q -- '--agentic-job-id'; then
  JOBS_CLI_CAPABLE=true
else
  warn "revenium jobs/--agentic-job-id not available — job work skipped; metering continues as v1.0."
fi

# TOOLS_CLI_CAPABLE — one-time dual capability probe per cron tick (TOOLEV-04).
# Set true only if BOTH `revenium tools --help` exits 0 AND
# `revenium meter tool-event --help` output contains --tool-id.
# On probe failure, warn once and leave TOOLS_CLI_CAPABLE=false so all tool
# work is skipped; metering continues as v1.1 (job-aware).
TOOLS_CLI_CAPABLE=false
if revenium tools --help >/dev/null 2>&1 && \
   revenium meter tool-event --help 2>&1 | grep -q -- '--tool-id'; then
  TOOLS_CLI_CAPABLE=true
else
  warn "revenium tools/meter tool-event not available — tool work skipped; metering continues as v1.1."
fi

main "$@"
