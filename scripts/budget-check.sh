#!/usr/bin/env bash
# Standalone budget status checker - bash 3.x compatible
set -euo pipefail

# Allow OPENCLAW_HOME override (sandbox where $HOME != host home)
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

SKILL_DIR="${OPENCLAW_HOME}/skills/revenium"
CONFIG_FILE="${SKILL_DIR}/config.json"
BUDGET_STATUS_FILE="${SKILL_DIR}/budget-status.json"

# Ensure revenium is on PATH (cron/sandbox have minimal PATH)
for p in \
  /home/linuxbrew/.linuxbrew/bin \
  /opt/homebrew/bin \
  /usr/local/bin \
  /usr/bin \
  "${HOME}/go/bin" \
  "${HOME}/.local/bin"; do
  [[ -n "${p}" && -d "${p}" ]] && export PATH="${p}:${PATH}"
done

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "No config.json found"
  exit 1
fi

ALERT_ID=$(python3 -c "import json; print(json.load(open('${CONFIG_FILE}'))['alertId'])" 2>/dev/null)

if [[ -z "${ALERT_ID}" ]]; then
  echo "No alertId in config"
  exit 1
fi

BUDGET_JSON=$(revenium alerts budget get "${ALERT_ID}" --json 2>/dev/null)

if [[ -z "${BUDGET_JSON}" ]]; then
  echo "Failed to fetch budget"
  exit 1
fi

python3 << PYEOF
import json
from datetime import datetime, timezone

data = json.loads('''${BUDGET_JSON}''')
data['lastChecked'] = datetime.now(timezone.utc).isoformat()

current = float(data.get('currentValue', 0))
threshold = float(data.get('threshold', 0))
exceeded = current > threshold if threshold > 0 else False
data['exceeded'] = exceeded
data['halted'] = False

if 'note' in data:
    del data['note']

with open('${BUDGET_STATUS_FILE}', 'w') as f:
    json.dump(data, f, indent=2)

print(f"Budget: \${current:.2f} / \${threshold:.2f} ({'EXCEEDED' if exceeded else 'OK'})")
PYEOF
