#!/usr/bin/env bash
# =============================================================================
# Revenium Cron Runner
# Called by crontab every 15 minutes. Sources revenium config before running.
# =============================================================================

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Allow OPENCLAW_HOME override via env (e.g. sandbox where $HOME != host home).
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

# Source environment from revenium.env if it exists
ENV_FILE="${OPENCLAW_HOME}/revenium.env"
if [[ -f "${ENV_FILE}" ]]; then
  set -o allexport
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +o allexport
fi

# Ensure revenium CLI is on PATH.
# Cron runs with a minimal PATH, so we add common package manager locations.
# Try dynamic detection first (brew --prefix), fall back to well-known paths.
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

exec bash "${SKILL_DIR}/scripts/report.sh" "$@"
