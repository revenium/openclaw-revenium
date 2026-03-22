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

# Read config for autonomous mode and notification settings
AUTONOMOUS=$(python3 -c "import json; print(json.load(open('${CONFIG_FILE}')).get('autonomousMode', False))" 2>/dev/null || echo "False")
NOTIFY_CHANNEL=$(python3 -c "import json; print(json.load(open('${CONFIG_FILE}')).get('notifyChannel', ''))" 2>/dev/null || true)
NOTIFY_TARGET=$(python3 -c "import json; print(json.load(open('${CONFIG_FILE}')).get('notifyTarget', ''))" 2>/dev/null || true)

HALT_TRANSITION=$(python3 << PYEOF
import json
from datetime import datetime, timezone

data = json.loads('''${BUDGET_JSON}''')
data['lastChecked'] = datetime.now(timezone.utc).isoformat()

current = float(data.get('currentValue', 0))
threshold = float(data.get('threshold', 0))
exceeded = current > threshold if threshold > 0 else False
data['exceeded'] = exceeded

if 'note' in data:
    del data['note']

# Read previous budget-status.json to preserve halt state
prev_halted = False
try:
    with open('${BUDGET_STATUS_FILE}', 'r') as f:
        prev = json.load(f)
        prev_halted = prev.get('halted', False)
except (FileNotFoundError, json.JSONDecodeError):
    prev = {}

autonomous = '${AUTONOMOUS}' == 'True'
halt_transition = False

if autonomous and exceeded and not prev_halted:
    # Transition: not halted -> halted
    data['halted'] = True
    data['haltedAt'] = datetime.now(timezone.utc).isoformat()
    halt_transition = True
elif prev_halted:
    # Preserve existing halt (only clear-halt.sh can clear it)
    data['halted'] = True
    data['haltedAt'] = prev.get('haltedAt', datetime.now(timezone.utc).isoformat())
else:
    # Not autonomous or not exceeded — no halt
    data['halted'] = False

with open('${BUDGET_STATUS_FILE}', 'w') as f:
    json.dump(data, f, indent=2)

print(f"HALT_TRANSITION={'true' if halt_transition else 'false'}")
print(f"Budget: \${current:.2f} / \${threshold:.2f} ({'EXCEEDED' if exceeded else 'OK'}){' [HALTED]' if data.get('halted') else ''}")
PYEOF
)

echo "${HALT_TRANSITION}" | tail -1

# Send notification on halt transition
if echo "${HALT_TRANSITION}" | head -1 | grep -q "HALT_TRANSITION=true"; then
  if [[ -n "${NOTIFY_CHANNEL}" && -n "${NOTIFY_TARGET}" ]]; then
    # Extract values for the notification message
    CURRENT_VALUE=$(python3 -c "import json; print(f\"\${json.load(open('${BUDGET_STATUS_FILE}')).get('currentValue', 0):.2f}\")" 2>/dev/null || echo "?")
    THRESHOLD=$(python3 -c "import json; print(f\"\${json.load(open('${BUDGET_STATUS_FILE}')).get('threshold', 0):.2f}\")" 2>/dev/null || echo "?")
    PERCENT=$(python3 -c "import json; d=json.load(open('${BUDGET_STATUS_FILE}')); print(f\"{float(d.get('currentValue',0))/float(d.get('threshold',1))*100:.0f}\")" 2>/dev/null || echo "?")

    MSG="Budget halt active. Spent \$${CURRENT_VALUE} of \$${THRESHOLD} (${PERCENT}%). All autonomous operations are now stopped. To resume: bash ~/.openclaw/skills/revenium/scripts/clear-halt.sh"

    if command -v openclaw &>/dev/null; then
      openclaw message send --channel "${NOTIFY_CHANNEL}" --to "${NOTIFY_TARGET}" "${MSG}" 2>/dev/null && \
        echo "Halt notification sent via ${NOTIFY_CHANNEL}" || \
        echo "Failed to send halt notification via ${NOTIFY_CHANNEL}"
    else
      echo "openclaw CLI not available — halt notification not sent"
    fi
  else
    echo "Budget halted but no notification channel configured"
  fi
fi
