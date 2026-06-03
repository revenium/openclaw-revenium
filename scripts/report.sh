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
BUDGET_STATUS_FILE="${SKILL_DIR}/budget-status.json"
OFFSETS_FILE="${OPENCLAW_HOME}/revenium-offsets.json"
JOBS_LEDGER_FILE="${REVENIUM_JOBS_LEDGER_FILE:-${OPENCLAW_HOME}/revenium-jobs.ledger}"

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
    #   GUARDRAIL — completion reads budget-status.json (budget enforcement check)
    #   TOOL_CALL — completion invokes tools (stopReason=toolUse)
    #   CHAT      — regular text response
    local raw_stop_reason operation_type="CHAT"
    raw_stop_reason=$(echo "${line}" | jq -r '.message.stopReason // "stop"')
    if echo "${line}" | jq -e '.message.content[] | select(.type=="toolCall") | .arguments' 2>/dev/null | grep -q "budget-status.json"; then
      operation_type="GUARDRAIL"
    elif [[ "${raw_stop_reason}" == "toolUse" || "${raw_stop_reason}" == "tool_use" ]]; then
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
        "${root_sid}" "${task_type:-unclassified}"; then
      echo "TX:${tx_id}" >> "${LEDGER_FILE}"
      ((reported_count++)) || true
    else
      ((failed_count++)) || true
    fi

  done < <(tail -n +$((offset + 1)) "${session_file}")

  if [[ "${reported_count}" -gt 0 ]]; then
    info "Session ${session_id}: reported ${reported_count} events, ${failed_count} failures"
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

main "$@"
