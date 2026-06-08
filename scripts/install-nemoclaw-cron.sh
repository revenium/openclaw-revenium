#!/usr/bin/env bash
# =============================================================================
# Install Revenium NemoClaw Metering Cron Job
#
# Per-sandbox installer for the host-side metering loop. Hard-gates on sshfs
# (D-04). Writes the host-side auth env at mode 600 (D-02). Establishes the
# SSHFS mount. Installs an idempotent, sandbox-scoped crontab entry (D-07).
# Reuses the cronIntervalMinutes precedence logic from install-cron.sh (D-08).
# Never modifies cron.sh/report.sh/guardrail-check.sh (SC4).
# =============================================================================

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRON_SCRIPT="${SKILL_DIR}/scripts/nemoclaw-cron-tick.sh"

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
DEFAULT_INTERVAL=1
INTERVAL_ARG=""
SANDBOX_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)    INTERVAL_ARG="${2:-}"; shift 2 ;;
    --interval=*)  INTERVAL_ARG="${1#*=}"; shift ;;
    --sandbox)     SANDBOX_NAME="${2:-}"; shift 2 ;;
    --sandbox=*)   SANDBOX_NAME="${1#*=}"; shift ;;
    -h|--help)
      echo "Usage: install-nemoclaw-cron.sh --sandbox <name> [--interval <minutes 1-59>]"
      echo "  Default interval: ${DEFAULT_INTERVAL} minute(s) (or config.json cronIntervalMinutes)."
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Resolve sandbox name from env fallback.
# ---------------------------------------------------------------------------
SANDBOX_NAME="${REVENIUM_SANDBOX_NAME:-${SANDBOX_NAME:-}}"
if [[ -z "${SANDBOX_NAME}" ]]; then
  echo "ERROR: sandbox name required. Pass --sandbox <name> or export REVENIUM_SANDBOX_NAME." >&2
  exit 2
fi

# Per-sandbox marker (D-07): distinct from standalone "# revenium-metering"
CRON_COMMENT="# revenium-metering-nemoclaw:${SANDBOX_NAME}"

# ---------------------------------------------------------------------------
# Step 1: sshfs hard-gate (D-04).
#   sshfs must be present before installing a cron that requires it.
#   Attempt auto-install; if that still fails, abort with an actionable message.
# ---------------------------------------------------------------------------
if ! command -v sshfs &>/dev/null; then
  echo "sshfs not found — attempting install..."
  if command -v apt-get &>/dev/null; then
    apt-get install -y sshfs || true
  elif command -v dnf &>/dev/null; then
    dnf install -y fuse-sshfs || true
  fi
  if ! command -v sshfs &>/dev/null; then
    echo "ERROR: sshfs not available and auto-install failed." >&2
    echo "  Install sshfs manually (e.g. apt-get install sshfs) then re-run." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Step 2: Interval precedence (D-08).
#   --interval > config.json cronIntervalMinutes > default 1.
# ---------------------------------------------------------------------------
OPENCLAW_HOME="${OPENCLAW_HOME:-}"
if [[ -z "${OPENCLAW_HOME}" ]]; then
  for candidate in "${HOME}/.openclaw" "/home/ubuntu/.openclaw"; do
    if [[ -d "${candidate}/agents" ]]; then OPENCLAW_HOME="${candidate}"; break; fi
  done
  OPENCLAW_HOME="${OPENCLAW_HOME:-${HOME}/.openclaw}"
fi
CONFIG_FILE="${OPENCLAW_HOME}/skills/revenium/config.json"

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

# ---------------------------------------------------------------------------
# Step 3: Host-env write (D-02, T-14-03).
#   Write REVENIUM_API_KEY (and optional team/tenant/owner IDs) to
#   ~/.nemoclaw/revenium-host.env using printf — key never on a CLI flag.
#   chmod 600 immediately. Key must NOT appear in the crontab line or logs.
# ---------------------------------------------------------------------------
HOST_ENV_DIR="${HOME}/.nemoclaw"
HOST_ENV_FILE="${HOST_ENV_DIR}/revenium-host.env"
mkdir -p "${HOST_ENV_DIR}"
{
  printf 'REVENIUM_API_KEY=%s\n' "${REVENIUM_API_KEY:-}"
  [[ -n "${REVENIUM_TEAM_ID:-}" ]]   && printf 'REVENIUM_TEAM_ID=%s\n'   "${REVENIUM_TEAM_ID}"
  [[ -n "${REVENIUM_TENANT_ID:-}" ]] && printf 'REVENIUM_TENANT_ID=%s\n' "${REVENIUM_TENANT_ID}"
  [[ -n "${REVENIUM_OWNER_ID:-}" ]]  && printf 'REVENIUM_OWNER_ID=%s\n'  "${REVENIUM_OWNER_ID}"
} > "${HOST_ENV_FILE}"
chmod 600 "${HOST_ENV_FILE}"

# ---------------------------------------------------------------------------
# Step 4: Mount establishment.
# ---------------------------------------------------------------------------
MNT="${HOME}/sbx-openclaw-${SANDBOX_NAME}"
mkdir -p "${MNT}"
if ! mountpoint -q "${MNT}" 2>/dev/null; then
  nemoclaw "${SANDBOX_NAME}" share mount /sandbox/.openclaw "${MNT}" \
    || { echo "ERROR: mount failed — is ${SANDBOX_NAME} running?" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# Step 5: CRON_PATH baking (verbatim from install-cron.sh lines 71-83).
# ---------------------------------------------------------------------------
CRON_PATH="/usr/local/bin:/usr/bin:/bin"
for p in \
  /home/linuxbrew/.linuxbrew/bin \
  /opt/homebrew/bin \
  "${HOME}/go/bin" \
  "${HOME}/.local/bin"; do
  [[ -d "${p}" ]] && CRON_PATH="${p}:${CRON_PATH}"
done
if command -v brew &>/dev/null; then
  BREW_BIN="$(brew --prefix 2>/dev/null)/bin"
  [[ -d "${BREW_BIN}" ]] && CRON_PATH="${BREW_BIN}:${CRON_PATH}"
fi

# ---------------------------------------------------------------------------
# Step 6: Build cron line.
#   Exports REVENIUM_SANDBOX_NAME and REVENIUM_TICK_INTERVAL_MINUTES so the
#   tick wrapper knows which sandbox and interval. API key NOT in the line.
# ---------------------------------------------------------------------------
CRON_LINE="${CRON_SCHEDULE} PATH=${CRON_PATH} REVENIUM_SANDBOX_NAME=${SANDBOX_NAME} REVENIUM_TICK_INTERVAL_MINUTES=${INTERVAL} bash ${CRON_SCRIPT} >> ${HOME}/.nemoclaw/revenium-nemoclaw-metering.log 2>&1 ${CRON_COMMENT}"

# ---------------------------------------------------------------------------
# Step 7: Idempotent per-sandbox install (D-07).
#   Drop ONLY lines matching this sandbox's exact marker, then append the
#   new line. Other sandboxes' entries and the standalone # revenium-metering
#   entry are preserved because grep -vF on the sandbox-scoped marker does
#   not match them.
# ---------------------------------------------------------------------------
ACTION="installed"
if crontab -l 2>/dev/null | grep -qF "${CRON_COMMENT}"; then
  ACTION="updated"
fi
EXISTING="$(crontab -l 2>/dev/null | grep -vF "${CRON_COMMENT}" || true)"
{ [[ -n "${EXISTING}" ]] && printf '%s\n' "${EXISTING}"; printf '%s\n' "${CRON_LINE}"; } | crontab -

echo "Revenium NemoClaw metering cron ${ACTION} for sandbox '${SANDBOX_NAME}' (${INTERVAL_LABEL})"
echo "   Log: ${HOME}/.nemoclaw/revenium-nemoclaw-metering.log"
echo ""
echo "To view logs:    tail -f ~/.nemoclaw/revenium-nemoclaw-metering.log"
echo "To run manually: bash ${CRON_SCRIPT}"
echo "To uninstall:    bash ${SKILL_DIR}/scripts/uninstall-nemoclaw-cron.sh ${SANDBOX_NAME}"
