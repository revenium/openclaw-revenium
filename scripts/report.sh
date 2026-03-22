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
    --agent "OpenClaw"
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

  # Skip if already fully reported
  if grep -q "^DONE:${session_id}$" "${LEDGER_FILE}" 2>/dev/null; then
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
  local msg_meta_file user_msgs_file
  msg_meta_file=$(mktemp "${TMPDIR:-/tmp}/rv-meta.XXXXXX")
  user_msgs_file=$(mktemp "${TMPDIR:-/tmp}/rv-umsg.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -f '${msg_meta_file}' '${user_msgs_file}'" EXIT

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
  meta_lookup() {
    grep "^${1}	" "${msg_meta_file}" 2>/dev/null | head -1 | cut -f"${2}"
  }

  # Helper: look up user message text by ID
  user_msg_lookup() {
    grep "^${1}	" "${user_msgs_file}" 2>/dev/null | head -1 | cut -f2-
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

    input_tokens=$(echo "${line}" | jq -r '.message.usage.input // 0')
    output_tokens=$(echo "${line}" | jq -r '.message.usage.output // 0')
    cache_read=$(echo "${line}" | jq -r '.message.usage.cacheRead // 0')
    cache_create=$(echo "${line}" | jq -r '.message.usage.cacheWrite // 0')
    total_tokens=$(echo "${line}" | jq -r '.message.usage.totalTokens // 0')
    timestamp=$(echo "${line}" | jq -r '.timestamp // empty' 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    tx_id=$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || echo "${session_id}-$(date +%s%N)")
    stop_reason=$(map_stop_reason "$(echo "${line}" | jq -r '.message.stopReason // "stop"')")

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
        duration_ms=$(python3 -c "
from datetime import datetime, timezone
def parse_ts(s):
    try: return datetime.fromisoformat(s.replace('Z', '+00:00'))
    except: pass
    for fmt in ('%Y-%m-%dT%H:%M:%S.%fZ', '%Y-%m-%dT%H:%M:%SZ'):
        try: return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except: pass
    return None
t1 = parse_ts('${request_time}')
t2 = parse_ts('${timestamp}')
if t1 and t2:
    print(max(0, int((t2 - t1).total_seconds() * 1000)))
else:
    print(0)
" 2>/dev/null || echo 0)
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
        "${system_prompt}" "${input_msgs_json}" "${output_resp}"; then
      echo "TX:${tx_id}" >> "${LEDGER_FILE}"
      ((reported_count++)) || true
    else
      ((failed_count++)) || true
    fi

  done < "${session_file}"

  if [[ "${reported_count}" -gt 0 ]]; then
    info "Session ${session_id}: reported ${reported_count} events, ${failed_count} failures"
  fi

  # If session file hasn't been modified in >1 hour, mark as DONE
  local now mod_time age
  now=$(date +%s)
  mod_time=$(stat -c %Y "${session_file}" 2>/dev/null || stat -f %m "${session_file}" 2>/dev/null || echo 0)
  age=$((now - mod_time))
  if [[ "${age}" -gt 3600 ]]; then
    echo "DONE:${session_id}" >> "${LEDGER_FILE}"
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

  info "=== Done. Processed ${total_files} session file(s). ==="
}

main "$@"
