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
for script in cron.sh report.sh budget-check.sh install-cron.sh uninstall-cron.sh clear-halt.sh post-install.sh; do
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
#   - bin directories containing revenium/jq (ro) — so the agent can invoke CLIs
#   - ~/.config/revenium (ro) — CLI credentials (API key, team/tenant/user IDs)
BIND_ENTRIES=()
BIND_ENTRIES+=("${OPENCLAW_HOME}:${OPENCLAW_HOME}")

# Collect unique directories that need to be mounted.
# We mount bin *directories* (not individual binaries) so PATH resolution works,
# and also mount sibling lib directories so shared libraries are available.
BIN_DIRS_SEEN=()
LIB_DIRS_SEEN=()

add_bin_dir() {
  local exe_path="$1"
  local bin_dir
  bin_dir="$(dirname "${exe_path}")"

  # Skip standard dirs that are already in most container images
  case "${bin_dir}" in
    /usr/bin|/bin) return ;;
  esac

  # Deduplicate
  for seen in "${BIN_DIRS_SEEN[@]+"${BIN_DIRS_SEEN[@]}"}"; do
    [[ "${seen}" == "${bin_dir}" ]] && return
  done

  BIN_DIRS_SEEN+=("${bin_dir}")
  BIND_ENTRIES+=("${bin_dir}:${bin_dir}:ro")
  info "Will bind-mount ${bin_dir} (contains $(basename "${exe_path}"))"

  # Also mount the sibling lib directory if it exists — Homebrew Cellar
  # binaries (e.g. jq) have shared lib deps (libjq.so, libonig.so) in
  # ../lib relative to the bin dir.
  local lib_dir="${bin_dir}/../lib"
  if [[ -d "${lib_dir}" ]]; then
    lib_dir="$(cd "${lib_dir}" && pwd)"
    local already=false
    for seen in "${LIB_DIRS_SEEN[@]+"${LIB_DIRS_SEEN[@]}"}"; do
      [[ "${seen}" == "${lib_dir}" ]] && already=true && break
    done
    if [[ "${already}" == false ]]; then
      LIB_DIRS_SEEN+=("${lib_dir}")
      BIND_ENTRIES+=("${lib_dir}:${lib_dir}:ro")
      info "Will bind-mount ${lib_dir} (shared libs)"
    fi
  fi
}

# Bind-mount the directory containing the revenium binary
REVENIUM_PATH="$(command -v revenium || true)"
if [[ -n "${REVENIUM_PATH}" ]]; then
  add_bin_dir "${REVENIUM_PATH}"
  # Also handle symlink targets (e.g. /usr/local/bin/revenium -> /home/linuxbrew/...)
  REVENIUM_REAL="$(readlink -f "${REVENIUM_PATH}" 2>/dev/null || echo "${REVENIUM_PATH}")"
  if [[ "${REVENIUM_REAL}" != "${REVENIUM_PATH}" ]]; then
    add_bin_dir "${REVENIUM_REAL}"
  fi
fi

# Bind-mount the directory containing jq
JQ_PATH="$(command -v jq || true)"
if [[ -n "${JQ_PATH}" ]]; then
  add_bin_dir "${JQ_PATH}"
  JQ_REAL="$(readlink -f "${JQ_PATH}" 2>/dev/null || echo "${JQ_PATH}")"
  if [[ "${JQ_REAL}" != "${JQ_PATH}" ]]; then
    add_bin_dir "${JQ_REAL}"
  fi
fi

# Bind-mount revenium CLI config (API key, team/tenant/user IDs).
# Create the dir if it doesn't exist yet — the user may configure revenium
# after post-install, and we need the mount point ready.
REVENIUM_CONFIG_DIR="${HOME}/.config/revenium"
mkdir -p "${REVENIUM_CONFIG_DIR}"
BIND_ENTRIES+=("${REVENIUM_CONFIG_DIR}:${REVENIUM_CONFIG_DIR}:ro")
info "Will bind-mount revenium config at ${REVENIUM_CONFIG_DIR}"

# Generate a CA certificate bundle for sandboxed environments.
# Minimal Docker containers often lack /etc/ssl/certs/ca-certificates.crt,
# which causes Go/TLS binaries like revenium to fail HTTPS connections.
# Node.js (an OpenClaw dependency) ships its own CA bundle — extract it
# to a stable path and point SSL_CERT_FILE at it.
SSL_DIR="${OPENCLAW_HOME}/ssl"
SSL_CERT_FILE="${SSL_DIR}/ca-certificates.crt"
REVENIUM_ENV="${OPENCLAW_HOME}/revenium.env"

if [[ ! -f "${SSL_CERT_FILE}" ]]; then
  if command_exists node; then
    mkdir -p "${SSL_DIR}"
    node -e "
      const tls = require('tls');
      const fs = require('fs');
      fs.writeFileSync('${SSL_CERT_FILE}', tls.rootCertificates.join('\n'));
    "
    info "Generated CA bundle at ${SSL_CERT_FILE}"
  else
    warn "node not found — cannot generate CA bundle; revenium may fail HTTPS in sandbox"
  fi
fi

# Persist SSL_CERT_FILE to revenium.env (sourced by cron.sh)
if [[ -f "${SSL_CERT_FILE}" ]]; then
  if ! grep -q "SSL_CERT_FILE" "${REVENIUM_ENV}" 2>/dev/null; then
    echo "SSL_CERT_FILE=${SSL_CERT_FILE}" >> "${REVENIUM_ENV}"
    info "Added SSL_CERT_FILE to ${REVENIUM_ENV}"
  fi
  # Export for the remainder of this script (in case revenium is called later)
  export SSL_CERT_FILE="${SSL_CERT_FILE}"
  # Bind-mount the ssl dir into the container
  BIND_ENTRIES+=("${SSL_DIR}:${SSL_DIR}:ro")
fi

# Build a PATH that includes the mounted bin directories so the container
# can actually resolve the binaries (its default PATH won't include e.g.
# /home/linuxbrew/.linuxbrew/bin).
EXTRA_PATH_DIRS=""
for d in "${BIN_DIRS_SEEN[@]+"${BIN_DIRS_SEEN[@]}"}"; do
  if [[ -z "${EXTRA_PATH_DIRS}" ]]; then
    EXTRA_PATH_DIRS="${d}"
  else
    EXTRA_PATH_DIRS="${d}:${EXTRA_PATH_DIRS}"
  fi
done

# Build LD_LIBRARY_PATH for mounted shared libraries (e.g. libjq, libonig)
EXTRA_LIB_DIRS=""
for d in "${LIB_DIRS_SEEN[@]+"${LIB_DIRS_SEEN[@]}"}"; do
  if [[ -z "${EXTRA_LIB_DIRS}" ]]; then
    EXTRA_LIB_DIRS="${d}"
  else
    EXTRA_LIB_DIRS="${d}:${EXTRA_LIB_DIRS}"
  fi
done

python3 <<PYEOF
import json, os

config_path = "${OPENCLAW_CONFIG}"
bind_entries = $(printf '%s\n' "${BIND_ENTRIES[@]}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
extra_path_dirs = "${EXTRA_PATH_DIRS}"
extra_lib_dirs = "${EXTRA_LIB_DIRS}"
host_home = "${HOME}"

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

# Inject PATH into the container environment so mounted binaries are found
if extra_path_dirs:
    # Ensure env is a dict (may be a leftover array from a previous run)
    if not isinstance(docker.get("env"), dict):
        docker["env"] = {}
    default_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    docker["env"]["PATH"] = f"{extra_path_dirs}:{default_path}"

# Ensure env is a dict
if not isinstance(docker.get("env"), dict):
    docker["env"] = {}

# Set HOME to the host user's home so scripts find ~/.openclaw correctly
# (the sandbox default HOME is /workspace which breaks all path resolution)
docker["env"]["HOME"] = host_home

# Set LD_LIBRARY_PATH so Homebrew binaries (jq) can find their shared libs
# (libjq.so, libonig.so live in Cellar lib dirs, not in standard /usr/lib)
if extra_lib_dirs:
    docker["env"]["LD_LIBRARY_PATH"] = extra_lib_dirs

# Point revenium at our CA bundle inside the container
ssl_cert_file = "${SSL_CERT_FILE}"
if ssl_cert_file:
    docker["env"]["SSL_CERT_FILE"] = ssl_cert_file

# Allow outbound network access so the revenium CLI can reach api.revenium.ai
docker["network"] = "bridge"

with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PYEOF
info "Configured sandbox bind mounts in ${OPENCLAW_CONFIG}"
if [[ -n "${EXTRA_PATH_DIRS}" ]]; then
  info "Sandbox PATH includes: ${EXTRA_PATH_DIRS}"
fi

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
# 5. Seed initial budget-status.json
# ---------------------------------------------------------------------------
step "Seeding initial budget-status.json"

BUDGET_STATUS_FILE="${SKILL_DIR}/budget-status.json"
if [[ ! -f "${BUDGET_STATUS_FILE}" ]]; then
  cat > "${BUDGET_STATUS_FILE}" <<BSJSON
{
  "currentValue": 0,
  "threshold": 0,
  "percentUsed": 0,
  "remaining": 0,
  "exceeded": false,
  "halted": false,
  "lastChecked": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "note": "Seed file — will be replaced by cron on first run"
}
BSJSON
  info "Created seed budget-status.json (cron will overwrite on first run)"
else
  info "budget-status.json already exists"
fi

# ---------------------------------------------------------------------------
# 6. Inject budget check into AGENTS.md
# ---------------------------------------------------------------------------
step "Injecting budget check into AGENTS.md"

AGENTS_MD="${OPENCLAW_HOME}/workspace/AGENTS.md"
BUDGET_MARKER="## Budget Check (Mandatory)"

if [[ ! -f "${AGENTS_MD}" ]]; then
  warn "AGENTS.md not found at ${AGENTS_MD} — skipping budget injection"
elif grep -q "${BUDGET_MARKER}" "${AGENTS_MD}" 2>/dev/null; then
  info "Budget check already present in AGENTS.md"
else
  python3 <<PYEOF
import re

section = """
## Budget Check (Mandatory)

BEFORE EVERY RESPONSE, NO EXCEPTIONS — read \`~/.openclaw/skills/revenium/budget-status.json\`.

- **File missing:** Warn user the metering cron may not be installed, then proceed.
- **\`exceeded\` is \`false\`:** Proceed silently. Do NOT mention the budget.
- **\`exceeded\` is \`true\`:** Follow the halt/warn logic in \`~/.openclaw/skills/revenium/SKILL.md\` (interactive vs autonomous mode).

This applies to ALL operations — chat, tool calls, code, questions, everything. No task is exempt.
"""

path = "${AGENTS_MD}"
with open(path, "r") as f:
    content = f.read()

injected = False

# Try 1: inject after "Don't ask permission. Just do it."
anchor = "Don't ask permission. Just do it."
if anchor in content:
    content = content.replace(anchor, anchor + "\n" + section, 1)
    injected = True

# Try 2: inject before "## Memory"
if not injected and "## Memory" in content:
    content = content.replace("## Memory", section + "\n## Memory", 1)
    injected = True

# Try 3: append
if not injected:
    content += "\n" + section

with open(path, "w") as f:
    f.write(content)
PYEOF
  info "Injected budget check into AGENTS.md"
fi

# ---------------------------------------------------------------------------
# 7. Configure bootstrap-extra-files hook for isolated sessions
# ---------------------------------------------------------------------------
step "Configuring budget guard for isolated sessions"

# Deploy BUDGET-GUARD.md to the workspace so it can be injected into
# all sessions (including isolated cron jobs and subagents) via the
# bootstrap-extra-files hook. This covers sessions where AGENTS.md
# isn't loaded (e.g. lightContext cron jobs).
BUDGET_GUARD_SRC="${SKILL_DIR}/BUDGET-GUARD.md"
BUDGET_GUARD_DST="${OPENCLAW_HOME}/workspace/BUDGET-GUARD.md"

if [[ -f "${BUDGET_GUARD_SRC}" ]]; then
  mkdir -p "$(dirname "${BUDGET_GUARD_DST}")"
  cp "${BUDGET_GUARD_SRC}" "${BUDGET_GUARD_DST}"
  info "Deployed BUDGET-GUARD.md to workspace"
elif [[ -f "${BUDGET_GUARD_DST}" ]]; then
  info "BUDGET-GUARD.md already in workspace"
fi

# Enable the bootstrap-extra-files hook to inject BUDGET-GUARD.md into
# every agent session (including isolated cron jobs).
python3 <<PYEOF
import json, os

config_path = "${OPENCLAW_CONFIG}"
if os.path.exists(config_path):
    with open(config_path, "r") as f:
        config = json.load(f)
else:
    config = {}

hooks = config.setdefault("hooks", {})
internal = hooks.setdefault("internal", {})
internal["enabled"] = True
entries = internal.setdefault("entries", {})

bef = entries.setdefault("bootstrap-extra-files", {})
bef["enabled"] = True

# Add BUDGET-GUARD.md to the files list if not already present
files = bef.setdefault("files", [])
guard_file = "BUDGET-GUARD.md"
if guard_file not in files:
    files.append(guard_file)

with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PYEOF
info "Configured bootstrap-extra-files hook for budget guard"

# ---------------------------------------------------------------------------
# 8. Verify
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
