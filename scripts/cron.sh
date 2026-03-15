#!/usr/bin/env bash
# =============================================================================
# Revenium Cron Runner
# Called by crontab every 15 minutes. Sources revenium config before running.
# =============================================================================

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENCLAW_HOME="${HOME}/.openclaw"

# Source environment from revenium.env if it exists
ENV_FILE="${OPENCLAW_HOME}/revenium.env"
if [[ -f "${ENV_FILE}" ]]; then
  set -o allexport
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +o allexport
fi

# Ensure revenium CLI is on PATH (common install locations)
for p in /usr/local/bin /usr/bin "${HOME}/go/bin" "${HOME}/.local/bin"; do
  [[ -d "${p}" ]] && export PATH="${p}:${PATH}"
done

exec bash "${SKILL_DIR}/scripts/report.sh" "$@"
