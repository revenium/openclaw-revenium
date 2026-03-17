#!/usr/bin/env bash
# =============================================================================
# Revenium Metering Reporter for OpenClaw
# Reads session JSONL files, extracts token usage, ships to Revenium
# via `revenium meter completion`.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
OPENCLAW_HOME="${HOME}/.openclaw"
SESSIONS_DIR="${OPENCLAW_HOME}/agents/main/sessions"
LEDGER_FILE="${OPENCLAW_HOME}/revenium-reported.ledger"
LOG_FILE="${OPENCLAW_HOME}/revenium-metering.log"
SKILL_DIR="${HOME}/.openclaw/skills/revenium"
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
  local timestamp="$7"
  local stop_reason="$8"
  local transaction_id="$9"
  local model_source="${10}"
  local is_streamed="${11}"
  local system_prompt="${12:-}"
  local input_messages="${13:-}"
  local output_response="${14:-}"

  local total_tokens=$((input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens))

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
    --request-time "${timestamp}"
    --completion-start-time "${timestamp}"
    --response-time "${timestamp}"
    --request-duration 0
    --agent "OpenClaw"
    --transaction-id "${transaction_id}"
    --operation-type "CHAT"
    --quiet
  )

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

  # Build a lookup of message ID -> user text content for input-messages
  # Each assistant message has a parentId pointing to the user message that triggered it
  declare -A user_messages
  while IFS= read -r uline; do
    local uid ucontent
    uid=$(echo "${uline}" | jq -r '.id // empty' 2>/dev/null || true)
    ucontent=$(echo "${uline}" | jq -r '[.message.content[] | select(.type=="text") | .text] | join("\n")' 2>/dev/null || true)
    if [[ -n "${uid}" && -n "${ucontent}" ]]; then
      user_messages["${uid}"]="${ucontent}"
    fi
  done < <(jq -c 'select(.type=="message") | select(.message.role=="user")' "${session_file}" 2>/dev/null)

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
    timestamp=$(echo "${line}" | jq -r '.timestamp // empty' 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    tx_id=$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || echo "${session_id}-$(date +%s%N)")
    stop_reason=$(map_stop_reason "$(echo "${line}" | jq -r '.message.stopReason // "stop"')")

    # Look up the user message that triggered this completion via parentId
    local parent_id input_msgs_json=""
    parent_id=$(echo "${line}" | jq -r '.parentId // empty' 2>/dev/null || true)
    if [[ -n "${parent_id}" && -n "${user_messages[${parent_id}]+x}" ]]; then
      # Format as JSON array with single message object
      input_msgs_json=$(python3 -c "
import json, sys
text = sys.stdin.read()
# Truncate to 1000 chars
if len(text) > 1000:
    text = text[:1000] + '...'
print(json.dumps([{'role': 'user', 'content': text}]))
" <<< "${user_messages[${parent_id}]}" 2>/dev/null || true)
    fi

    # Extract the assistant's response text content
    local output_resp=""
    output_resp=$(echo "${line}" | jq -r '[.message.content[] | select(.type=="text") | .text] | join("\n")' 2>/dev/null || true)
    # Truncate to 1000 chars
    if [[ ${#output_resp} -gt 1000 ]]; then
      output_resp="${output_resp:0:1000}..."
    fi

    # Skip zero-usage lines
    local total=$((input_tokens + output_tokens))
    if [[ "${total}" -eq 0 ]]; then
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
        "${timestamp:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
        "${stop_reason}" "${tx_id}" \
        "${model_source}" "${is_streamed}" \
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
# Check budget and write status to local file
# ---------------------------------------------------------------------------
check_and_write_budget_status() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    info "No config.json — skipping budget check"
    return 0
  fi

  local alert_id
  alert_id=$(python3 -c "import json; print(json.load(open('${CONFIG_FILE}'))['alertId'])" 2>/dev/null || true)

  if [[ -z "${alert_id}" ]]; then
    warn "No alertId in config.json — skipping budget check"
    return 0
  fi

  local budget_json
  budget_json=$(revenium alerts budget get "${alert_id}" --json 2>/dev/null || true)

  if [[ -z "${budget_json}" ]]; then
    warn "Failed to fetch budget status from Revenium"
    return 0
  fi

  local halt_transition="false"
  python3 -c "
import json, sys
from datetime import datetime, timezone

data = json.loads('''${budget_json}''')
data['lastChecked'] = datetime.now(timezone.utc).isoformat()

# Read existing budget-status.json to check previous halted state
prev_halted = False
try:
    with open('${BUDGET_STATUS_FILE}', 'r') as f:
        prev = json.load(f)
        prev_halted = prev.get('halted', False)
except (FileNotFoundError, json.JSONDecodeError):
    pass

exceeded = data.get('exceeded', False)

if exceeded and not prev_halted:
    # Transition: not halted -> halted
    data['halted'] = True
    data['haltedAt'] = datetime.now(timezone.utc).isoformat()
    print('HALT_TRANSITION', file=sys.stderr)
elif exceeded and prev_halted:
    # Already halted — preserve
    data['halted'] = True
    data['haltedAt'] = prev.get('haltedAt', datetime.now(timezone.utc).isoformat())
elif not exceeded:
    # Budget OK — auto-clear halt
    data['halted'] = False
    if 'haltedAt' in data:
        del data['haltedAt']

with open('${BUDGET_STATUS_FILE}', 'w') as f:
    json.dump(data, f, indent=2)
" 2>"${BUDGET_STATUS_FILE}.stderr" || true

  if [[ -f "${BUDGET_STATUS_FILE}" ]] && python3 -c "import json; json.load(open('${BUDGET_STATUS_FILE}'))" 2>/dev/null; then
    local exceeded
    exceeded=$(python3 -c "import json; print(json.load(open('${BUDGET_STATUS_FILE}')).get('exceeded', False))" 2>/dev/null || echo "unknown")
    info "Budget status written: exceeded=${exceeded}"

    # Check if we just transitioned to halted
    if grep -q "HALT_TRANSITION" "${BUDGET_STATUS_FILE}.stderr" 2>/dev/null; then
      halt_transition="true"
      info "Budget halt activated — exceeded threshold"
    fi
    rm -f "${BUDGET_STATUS_FILE}.stderr"
  else
    warn "Failed to write budget status file"
    rm -f "${BUDGET_STATUS_FILE}.stderr"
  fi

  # Send notification on halt transition
  if [[ "${halt_transition}" == "true" ]]; then
    local notify_channel notify_target
    notify_channel=$(python3 -c "import json; print(json.load(open('${CONFIG_FILE}')).get('notifyChannel', ''))" 2>/dev/null || true)
    notify_target=$(python3 -c "import json; print(json.load(open('${CONFIG_FILE}')).get('notifyTarget', ''))" 2>/dev/null || true)

    if [[ -n "${notify_channel}" && -n "${notify_target}" ]]; then
      local current_value threshold percent_used
      current_value=$(python3 -c "import json; print(json.load(open('${BUDGET_STATUS_FILE}')).get('currentValue', '?'))" 2>/dev/null || echo "?")
      threshold=$(python3 -c "import json; print(json.load(open('${BUDGET_STATUS_FILE}')).get('threshold', '?'))" 2>/dev/null || echo "?")
      percent_used=$(python3 -c "import json; print(json.load(open('${BUDGET_STATUS_FILE}')).get('percentUsed', '?'))" 2>/dev/null || echo "?")

      local msg="OpenClaw Budget Alert: Your Revenium budget has been exceeded. Current spend: \$${current_value} of \$${threshold} (${percent_used}%). All autonomous operations have been halted. To resume, run: bash ~/.openclaw/skills/revenium/scripts/clear-halt.sh"

      if openclaw message send --channel "${notify_channel}" --target "${notify_target}" --message "${msg}" 2>/dev/null; then
        info "Budget halt notification sent via ${notify_channel}"
      else
        warn "Failed to send budget halt notification via ${notify_channel} — halt is still active, notification is best-effort"
      fi
    else
      if python3 -c "import json; exit(0 if json.load(open('${CONFIG_FILE}')).get('autonomousMode', False) else 1)" 2>/dev/null; then
        warn "Autonomous mode is enabled but no notification channel configured. Consider configuring one via /revenium."
      fi
    fi
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

  check_and_write_budget_status

  info "=== Done. Processed ${total_files} session file(s). ==="
}

main "$@"
