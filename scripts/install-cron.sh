#!/usr/bin/env bash
# =============================================================================
# Install Revenium Metering Cron Job
# =============================================================================

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRON_SCRIPT="${SKILL_DIR}/scripts/cron.sh"
CRON_COMMENT="# revenium-metering"

# ---------------------------------------------------------------------------
# Metering interval (how often the cron runs, in minutes).
# Precedence: --interval N flag > config.json "cronIntervalMinutes" > default 1.
# Default is every minute so guardrail enforcement stays near real-time; raise
# it to reduce how often the cron polls the Revenium API. Valid range 1-59 (the
# cron */N minute field). Re-running with a new value updates the existing entry.
# ---------------------------------------------------------------------------
DEFAULT_INTERVAL=1
INTERVAL_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)    INTERVAL_ARG="${2:-}"; shift 2 ;;
    --interval=*)  INTERVAL_ARG="${1#*=}"; shift ;;
    -h|--help)
      echo "Usage: install-cron.sh [--interval <minutes 1-59>]"
      echo "  Default interval: ${DEFAULT_INTERVAL} minute(s) (or config.json cronIntervalMinutes)."
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Resolve OPENCLAW_HOME (env override, else probe, else ~/.openclaw) to find config.json.
OPENCLAW_HOME="${OPENCLAW_HOME:-}"
if [[ -z "${OPENCLAW_HOME}" ]]; then
  for candidate in "${HOME}/.openclaw" "/home/ubuntu/.openclaw"; do
    if [[ -d "${candidate}/agents" ]]; then OPENCLAW_HOME="${candidate}"; break; fi
  done
  OPENCLAW_HOME="${OPENCLAW_HOME:-${HOME}/.openclaw}"
fi
CONFIG_FILE="${OPENCLAW_HOME}/skills/revenium/config.json"

# Fall back to config.json cronIntervalMinutes when no --interval flag was given.
CONFIG_INTERVAL=""
if [[ -z "${INTERVAL_ARG}" && -f "${CONFIG_FILE}" ]]; then
  CONFIG_INTERVAL=$(CONFIG_FILE="${CONFIG_FILE}" python3 - <<'PY'
import json, os
try:
    v = json.load(open(os.environ['CONFIG_FILE'])).get('cronIntervalMinutes')
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        print(int(v))
except Exception:
    pass
PY
  )
fi

INTERVAL="${INTERVAL_ARG:-${CONFIG_INTERVAL:-${DEFAULT_INTERVAL}}}"

if ! [[ "${INTERVAL}" =~ ^[0-9]+$ ]] || [[ "${INTERVAL}" -lt 1 || "${INTERVAL}" -gt 59 ]]; then
  echo "ERROR: interval must be an integer between 1 and 59 minutes (got '${INTERVAL}')." >&2
  exit 2
fi

CRON_SCHEDULE="*/${INTERVAL} * * * *"
if [[ "${INTERVAL}" -eq 1 ]]; then INTERVAL_LABEL="every minute"; else INTERVAL_LABEL="every ${INTERVAL} minutes"; fi

# Build a PATH for the cron entry that includes Homebrew/Linuxbrew locations.
# Cron runs with a minimal PATH, so we bake in the paths where revenium lives.
CRON_PATH="/usr/local/bin:/usr/bin:/bin"
for p in \
  /home/linuxbrew/.linuxbrew/bin \
  /opt/homebrew/bin \
  "${HOME}/go/bin" \
  "${HOME}/.local/bin"; do
  [[ -d "${p}" ]] && CRON_PATH="${p}:${CRON_PATH}"
done
# Dynamic detection if brew is available
if command -v brew &>/dev/null; then
  BREW_BIN="$(brew --prefix 2>/dev/null)/bin"
  [[ -d "${BREW_BIN}" ]] && CRON_PATH="${BREW_BIN}:${CRON_PATH}"
fi

CRON_LINE="${CRON_SCHEDULE} PATH=${CRON_PATH} bash ${CRON_SCRIPT} >> ${HOME}/.openclaw/revenium-metering.log 2>&1 ${CRON_COMMENT}"

chmod +x "${SKILL_DIR}/scripts/report.sh"
chmod +x "${SKILL_DIR}/scripts/cron.sh"

# Install or update: drop any existing revenium-metering line, then append the
# new one. Re-running with a different --interval therefore updates the cadence
# in place instead of refusing or duplicating the entry.
ACTION="installed"
if crontab -l 2>/dev/null | grep -q "revenium-metering"; then
  ACTION="updated"
fi
EXISTING="$(crontab -l 2>/dev/null | grep -v "revenium-metering" || true)"
{ [[ -n "${EXISTING}" ]] && printf '%s\n' "${EXISTING}"; printf '%s\n' "${CRON_LINE}"; } | crontab -

echo "✅ Revenium metering cron ${ACTION} (${INTERVAL_LABEL})"
echo "   Log: ${HOME}/.openclaw/revenium-metering.log"
echo ""
echo "To view logs:    tail -f ~/.openclaw/revenium-metering.log"
echo "To run manually: bash ${CRON_SCRIPT}"
echo "To uninstall:    bash ${SKILL_DIR}/scripts/uninstall-cron.sh"
