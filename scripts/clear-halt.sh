#!/usr/bin/env bash
# =============================================================================
# Clear budget enforcement halt
# Allows the autonomous agent to resume operations after a budget exceedance.
# =============================================================================

set -euo pipefail

SKILL_DIR="${HOME}/.openclaw/skills/revenium"
BUDGET_STATUS_FILE="${SKILL_DIR}/budget-status.json"

if [[ ! -f "${BUDGET_STATUS_FILE}" ]]; then
  echo "No budget-status.json found — nothing to clear."
  exit 0
fi

python3 -c "
import json

with open('${BUDGET_STATUS_FILE}', 'r') as f:
    data = json.load(f)

if not data.get('halted', False):
    print('No halt is currently active.')
else:
    data['halted'] = False
    data.pop('haltedAt', None)
    with open('${BUDGET_STATUS_FILE}', 'w') as f:
        json.dump(data, f, indent=2)
    print('Budget halt cleared. The agent may now resume operations.')
    print('Note: The budget is still exceeded. The agent will proceed until the next halt.')
"
