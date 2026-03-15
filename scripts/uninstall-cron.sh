#!/usr/bin/env bash
# =============================================================================
# Uninstall Revenium Metering Cron Job
# =============================================================================

set -euo pipefail

if ! crontab -l 2>/dev/null | grep -q "revenium-metering"; then
  echo "No Revenium cron job found."
  exit 0
fi

crontab -l 2>/dev/null | grep -v "revenium-metering" | crontab -
echo "✅ Revenium metering cron removed."
