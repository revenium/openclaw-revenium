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
# Guard: require revenium CLI
# ---------------------------------------------------------------------------
if ! command -v revenium &>/dev/null; then
  warn "revenium CLI not found on PATH — skipping metering."
  exit 0
fi

# Guard: require jq for JSONL parsing
if ! command -v jq &>/dev/null; then
  warn "jq not found — skipping metering."
  exit 0
fi

# Guard: require revenium config
if ! revenium config show &>/dev/null; then
  warn "revenium not configured — run /revenium in OpenClaw to set up."
  exit 0
fi

# ---------------------------------------------------------------------------
# Ensure ledger exists
# ---------------------------------------------------------------------------
touch "${LEDGER_FILE}"

# ---------------------------------------------------------------------------
# Map provider name from model string
# ---------------------------------------------------------------------------
get_provider() {
  local model="$1"
  case "${model}" in
    claude-*|anthropic*)  echo "anthropic" ;;
    gpt-*|o1-*|o3-*)     echo "openai" ;;
    gemini-*)             echo "google" ;;
    deepseek-*)           echo "deepseek" ;;
    llama-*|mistral-*)    echo "meta" ;;
    *)                    echo "unknown" ;;
  esac
}

# ---------------------------------------------------------------------------
# Map Anthropic stop_reason to Revenium stopReason enum
# ---------------------------------------------------------------------------
map_stop_reason() {
  case "${1}" in
    end_turn|endTurn)   echo "END" ;;
    stop_sequence)      echo "END_SEQUENCE" ;;
    max_tokens)         echo "TOKEN_LIMIT" ;;
    timeout)            echo "TIMEOUT" ;;
    error)              echo "ERROR" ;;
    toolUse|tool_use)   echo "END" ;;
    cancelled|canceled) echo "CANCELLED" ;;
    *)                  echo "END" ;;
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

  local total_tokens=$((input_tokens + output_tokens + cache_read_tokens + cache_creation_tokens))

  local cmd=(
    revenium meter completion
    --model "${model}"
    --provider "${provider}"
    --input-tokens "${input_tokens}"
    --output-tokens "${output_tokens}"
    --total-tokens "${total_tokens}"
    --stop-reason "${stop_reason}"
    --request-time "${timestamp}"
    --completion-start-time "${timestamp}"
    --response-time "${timestamp}"
    --request-duration 0
    --agent "openclaw"
    --cache-read-tokens "${cache_read_tokens}"
    --cache-creation-tokens "${cache_creation_tokens}"
    --transaction-id "${transaction_id}"
    --quiet
  )

  if "${cmd[@]}" 2>/dev/null; then
    info "Reported: model=${model} in=${input_tokens} out=${output_tokens} cache_read=${cache_read_tokens}"
    return 0
  else
    warn "Failed to report: model=${model} txId=${transaction_id}"
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

  local reported_count=0
  local failed_count=0

  while IFS= read -r line; do
    # Only process assistant message lines with usage data
    if ! echo "${line}" | jq -e 'select(.type=="message") | .message | select(.role=="assistant") | .usage' &>/dev/null 2>&1; then
      continue
    fi

    local model input_tokens output_tokens cache_read cache_create timestamp tx_id stop_reason

    model=$(echo "${line}" | jq -r '.message.model // "unknown"')
    input_tokens=$(echo "${line}" | jq -r '.message.usage.input // .message.usage.input_tokens // 0')
    output_tokens=$(echo "${line}" | jq -r '.message.usage.output // .message.usage.output_tokens // 0')
    cache_read=$(echo "${line}" | jq -r '.message.usage.cacheRead // .message.usage.cache_read_input_tokens // 0')
    cache_create=$(echo "${line}" | jq -r '.message.usage.cacheWrite // .message.usage.cache_creation_input_tokens // 0')
    timestamp=$(echo "${line}" | jq -r '.timestamp // empty' 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    tx_id=$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || echo "${session_id}-$(date +%s%N)")
    stop_reason=$(map_stop_reason "$(echo "${line}" | jq -r '.message.stopReason // .message.stop_reason // "end_turn"')")

    # Skip zero-usage lines
    local total=$((input_tokens + output_tokens))
    if [[ "${total}" -eq 0 ]]; then
      continue
    fi

    # Skip already-reported transactions
    if grep -q "^TX:${tx_id}$" "${LEDGER_FILE}" 2>/dev/null; then
      continue
    fi

    local provider
    provider=$(get_provider "${model}")

    if post_to_revenium \
        "${model}" "${provider}" \
        "${input_tokens}" "${output_tokens}" \
        "${cache_read}" "${cache_create}" \
        "${timestamp:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
        "${stop_reason}" "${tx_id}"; then
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
SKILL_DIR="${HOME}/.openclaw/skills/revenium"
BUDGET_STATUS_FILE="${SKILL_DIR}/budget-status.json"
CONFIG_FILE="${SKILL_DIR}/config.json"

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

  # Write the full budget response plus a timestamp to the status file
  python3 -c "
import json, sys
from datetime import datetime, timezone
data = json.loads('''${budget_json}''')
data['lastChecked'] = datetime.now(timezone.utc).isoformat()
with open('${BUDGET_STATUS_FILE}', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null

  if [[ $? -eq 0 ]]; then
    local exceeded
    exceeded=$(python3 -c "import json; print(json.load(open('${BUDGET_STATUS_FILE}')).get('exceeded', False))" 2>/dev/null || echo "unknown")
    info "Budget status written: exceeded=${exceeded}"
  else
    warn "Failed to write budget status file"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  info "=== Revenium Metering Reporter starting ==="

  if [[ ! -d "${SESSIONS_DIR}" ]]; then
    # Try to find sessions directory
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

  # Check budget and write status for the agent to read
  check_and_write_budget_status

  info "=== Done. Processed ${total_files} session file(s). ==="
}

main "$@"
