#!/usr/bin/env bash
# =============================================================================
# Revenium OpenClaw Skill — Post-Install Setup
#
# Run this after installing the skill via ClawHub (or manually).
# Checks and installs missing prerequisites, configures OpenClaw
# sandbox access, and verifies the installation.
#
# Usage:
#   bash ~/.openclaw/skills/revenium/scripts/post-install.sh
#   bash ~/.openclaw/skills/revenium/scripts/post-install.sh --skip-prereqs
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SKILL_NAME="revenium"
OPENCLAW_HOME="${HOME}/.openclaw"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENCLAW_CONFIG="${OPENCLAW_HOME}/openclaw.json"
SKIP_PREREQS=false

for arg in "$@"; do
  case "${arg}" in
    --skip-prereqs) SKIP_PREREQS=true ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "  ✓ $*"; }
warn()  { echo "  ⚠ $*"; }
step()  { echo ""; echo "▸ $*"; }
fail()  { echo ""; echo "  ✗ $*" >&2; exit 1; }

command_exists() { command -v "$1" &>/dev/null; }

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
step "Checking prerequisites"

install_with_brew() {
  local formula="$1"
  local tap="${2:-}"

  if ! command_exists brew; then
    fail "Homebrew is required to auto-install ${formula}. Install it from https://brew.sh or install ${formula} manually, then re-run this script."
  fi

  if [[ -n "${tap}" ]]; then
    echo "    → brew tap ${tap}"
    brew tap "${tap}" 2>/dev/null || true
  fi

  echo "    → brew install ${formula}"
  brew install "${formula}"
}

# --- revenium CLI ---
if command_exists revenium; then
  info "revenium CLI found: $(command -v revenium)"
else
  if [[ "${SKIP_PREREQS}" == true ]]; then
    fail "revenium CLI not found. Install it (brew install revenium/tap/revenium) and re-run."
  fi
  warn "revenium CLI not found — installing via Homebrew"
  install_with_brew "revenium/tap/revenium" "revenium/tap"
  command_exists revenium || fail "revenium CLI installation failed. Install manually from https://docs.revenium.io/for-ai-agents"
  info "revenium CLI installed: $(command -v revenium)"
fi

# --- jq ---
if command_exists jq; then
  info "jq found: $(command -v jq)"
else
  if [[ "${SKIP_PREREQS}" == true ]]; then
    fail "jq not found. Install it (brew install jq) and re-run."
  fi
  warn "jq not found — installing via Homebrew"
  install_with_brew "jq"
  command_exists jq || fail "jq installation failed. Install manually and re-run."
  info "jq installed: $(command -v jq)"
fi

# --- python3 (used by report.sh and SKILL.md setup) ---
if command_exists python3; then
  info "python3 found: $(command -v python3)"
else
  fail "python3 is required but not found. Install Python 3 and re-run."
fi

# --- OpenClaw ---
if [[ -d "${OPENCLAW_HOME}" ]]; then
  info "OpenClaw home found: ${OPENCLAW_HOME}"
else
  fail "OpenClaw home not found at ${OPENCLAW_HOME}. Is OpenClaw installed? See https://docs.openclaw.ai"
fi

# ---------------------------------------------------------------------------
# 2. Verify skill files are in place
# ---------------------------------------------------------------------------
step "Checking skill files in ${SKILL_DIR}"

if [[ ! -f "${SKILL_DIR}/SKILL.md" ]]; then
  fail "SKILL.md not found at ${SKILL_DIR}/SKILL.md. Run 'clawhub install --dir ~/.openclaw/skills revenium' first."
fi
info "SKILL.md present"

# Ensure scripts are executable
for script in cron.sh report.sh install-cron.sh uninstall-cron.sh clear-halt.sh post-install.sh; do
  if [[ -f "${SKILL_DIR}/scripts/${script}" ]]; then
    chmod +x "${SKILL_DIR}/scripts/${script}"
  fi
done
info "Scripts marked executable"

# ---------------------------------------------------------------------------
# 3. Configure sandbox access
# ---------------------------------------------------------------------------
step "Configuring OpenClaw sandbox access"

# Build the list of bind mounts the agent needs inside the Docker sandbox:
#   - ~/.openclaw (rw) — skills, sessions, logs, ledger, budget-status, config
#   - revenium binary (ro) — so the agent can call the CLI
#   - ~/.config/revenium (ro) — CLI credentials (API key, team/tenant/user IDs)
BIND_ENTRIES=()
BIND_ENTRIES+=("${OPENCLAW_HOME}:${OPENCLAW_HOME}")

# Bind-mount the revenium binary so the sandbox can invoke it
REVENIUM_PATH="$(command -v revenium || true)"
if [[ -n "${REVENIUM_PATH}" ]]; then
  REVENIUM_REAL="$(readlink -f "${REVENIUM_PATH}" 2>/dev/null || echo "${REVENIUM_PATH}")"
  BIND_ENTRIES+=("${REVENIUM_REAL}:${REVENIUM_REAL}:ro")
  # Also mount the symlink path if it differs (e.g. /usr/local/bin/revenium -> linuxbrew)
  if [[ "${REVENIUM_REAL}" != "${REVENIUM_PATH}" ]]; then
    BIND_ENTRIES+=("${REVENIUM_PATH}:${REVENIUM_PATH}:ro")
  fi
  info "Will bind-mount revenium at ${REVENIUM_PATH}"
fi

# Bind-mount jq if available
JQ_PATH="$(command -v jq || true)"
if [[ -n "${JQ_PATH}" ]]; then
  JQ_REAL="$(readlink -f "${JQ_PATH}" 2>/dev/null || echo "${JQ_PATH}")"
  BIND_ENTRIES+=("${JQ_REAL}:${JQ_REAL}:ro")
  if [[ "${JQ_REAL}" != "${JQ_PATH}" ]]; then
    BIND_ENTRIES+=("${JQ_PATH}:${JQ_PATH}:ro")
  fi
  info "Will bind-mount jq at ${JQ_PATH}"
fi

# Bind-mount revenium CLI config (API key, team/tenant/user IDs)
REVENIUM_CONFIG_DIR="${HOME}/.config/revenium"
if [[ -d "${REVENIUM_CONFIG_DIR}" ]]; then
  BIND_ENTRIES+=("${REVENIUM_CONFIG_DIR}:${REVENIUM_CONFIG_DIR}:ro")
  info "Will bind-mount revenium config at ${REVENIUM_CONFIG_DIR}"
fi

python3 <<PYEOF
import json, os

config_path = "${OPENCLAW_CONFIG}"
bind_entries = $(printf '%s\n' "${BIND_ENTRIES[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")

if os.path.exists(config_path):
    with open(config_path, "r") as f:
        config = json.load(f)
else:
    config = {}

# Navigate/create the nested path
agents = config.setdefault("agents", {})
defaults = agents.setdefault("defaults", {})
sandbox = defaults.setdefault("sandbox", {})
docker = sandbox.setdefault("docker", {})
binds = docker.setdefault("binds", [])

for entry in bind_entries:
    if entry not in binds:
        binds.append(entry)

with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PYEOF
info "Configured sandbox bind mounts in ${OPENCLAW_CONFIG}"

# ---------------------------------------------------------------------------
# 4. Enable autoAllowSkills in OpenClaw exec approvals
# ---------------------------------------------------------------------------
step "Configuring OpenClaw exec approvals"

EXEC_APPROVALS="${OPENCLAW_HOME}/exec-approvals.json"

if [[ ! -f "${EXEC_APPROVALS}" ]]; then
  cat > "${EXEC_APPROVALS}" <<EJSON
{
  "version": 1,
  "defaults": {
    "autoAllowSkills": true
  }
}
EJSON
  info "Created ${EXEC_APPROVALS} with autoAllowSkills enabled"
else
  if grep -q '"autoAllowSkills"' "${EXEC_APPROVALS}" 2>/dev/null; then
    info "autoAllowSkills already configured in ${EXEC_APPROVALS}"
  else
    python3 <<PYEOF
import json

path = "${EXEC_APPROVALS}"
with open(path, "r") as f:
    config = json.load(f)

defaults = config.setdefault("defaults", {})
defaults["autoAllowSkills"] = True

with open(path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PYEOF
    info "Enabled autoAllowSkills in ${EXEC_APPROVALS}"
  fi
fi

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
step "Verifying installation"

if [[ -f "${SKILL_DIR}/SKILL.md" ]]; then
  info "SKILL.md present at ${SKILL_DIR}/SKILL.md"
else
  fail "SKILL.md not found after install"
fi

if [[ -f "${SKILL_DIR}/scripts/report.sh" ]]; then
  info "Metering scripts present"
else
  warn "Metering scripts missing — cron metering will not work"
fi

if grep -q "${OPENCLAW_HOME}" "${OPENCLAW_CONFIG}" 2>/dev/null; then
  info "Sandbox bind mounts verified in openclaw.json"
else
  warn "Sandbox bind mounts could not be verified"
fi

# Check if openclaw CLI is available to run skills list
if command_exists openclaw; then
  echo ""
  echo "    Checking skill visibility..."
  if openclaw skills list 2>/dev/null | grep -q "${SKILL_NAME}"; then
    info "Skill '${SKILL_NAME}' visible to OpenClaw"
  else
    warn "Skill not yet visible. You may need to restart the OpenClaw gateway."
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Revenium skill installed successfully!"
echo ""
echo "  Next steps:"
echo "    1. Restart the OpenClaw gateway for sandbox changes to take effect"
echo "    2. Start an agent session — the skill will walk you through"
echo "       API key setup, budget configuration, and cron installation"
echo "       on first run"
echo ""
echo "  Useful commands:"
echo "    openclaw skills list          — verify skill is loaded"
echo "    /revenium                     — view budget or reconfigure"
echo "    bash ${SKILL_DIR}/scripts/uninstall-cron.sh  — remove cron"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
