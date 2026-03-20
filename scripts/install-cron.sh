#!/usr/bin/env bash
# =============================================================================
# Install Revenium Metering Cron Job
# =============================================================================

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRON_SCRIPT="${SKILL_DIR}/scripts/cron.sh"
CRON_COMMENT="# revenium-metering"
CRON_SCHEDULE="* * * * *"

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

# Check if already installed
if crontab -l 2>/dev/null | grep -q "revenium-metering"; then
  echo "✓ Revenium cron already installed."
  crontab -l | grep "revenium"
  exit 0
fi

# Add to crontab
( crontab -l 2>/dev/null || true; echo "${CRON_LINE}" ) | crontab -

echo "✅ Revenium metering cron installed (every minute)"
echo "   Log: ${HOME}/.openclaw/revenium-metering.log"
echo ""
echo "To view logs:    tail -f ~/.openclaw/revenium-metering.log"
echo "To run manually: bash ${CRON_SCRIPT}"
echo "To uninstall:    bash ${SKILL_DIR}/scripts/uninstall-cron.sh"
