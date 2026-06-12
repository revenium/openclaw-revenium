#!/usr/bin/env bash
# =============================================================================
# Clear guardrail enforcement halt
# Allows the autonomous agent to resume operations after a guardrail breach.
# Targets guardrail-status.json atomically.
# Preserves haltedRule and haltedAt fields as an audit trail — does NOT pop them.
# =============================================================================

set -euo pipefail

# Resolve the skill state dir via common.sh so this works everywhere the other
# scripts do: standalone installs, host-side against a sandbox mount
# (OPENCLAW_HOME=<mount>), and in-sandbox (OPENCLAW_HOME=/sandbox with the
# .openclaw normalization). Previously hardcoded ${HOME}/.openclaw, which could
# not target a sandbox over the mount.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/common.sh"

GUARDRAIL_STATUS_FILE="${STATE_DIR}/guardrail-status.json"

if [[ ! -f "${GUARDRAIL_STATUS_FILE}" ]]; then
  echo "No guardrail-status.json found — nothing to clear."
  exit 0
fi

GUARDRAIL_STATUS_FILE="${GUARDRAIL_STATUS_FILE}" python3 - <<'PY'
import json, os, tempfile

status_file = os.environ['GUARDRAIL_STATUS_FILE']

with open(status_file, 'r', encoding='utf-8') as f:
    data = json.load(f)

if not data.get('halted', False):
    print('No halt is currently active.')
else:
    data['halted'] = False
    # Preserve haltedRule and haltedAt — they are audit trail fields.
    # Do NOT pop them (unlike the legacy clear-halt.sh which removed haltedAt).

    # Atomic write via tempfile.mkstemp + os.replace (T-03-14 mitigation).
    status_dir = os.path.dirname(status_file)
    tmp_fd, tmp_path = tempfile.mkstemp(
        dir=status_dir,
        prefix='.guardrail-status-',
        suffix='.tmp'
    )
    try:
        with os.fdopen(tmp_fd, 'w', encoding='utf-8') as f:
            f.write(json.dumps(data, indent=2) + '\n')
        os.replace(tmp_path, status_file)
    finally:
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass

    print('Guardrail halt cleared. The agent may now resume operations.')
PY
