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

  # Recent Homebrew enables its Linux build sandbox by default, which needs a
  # ROOTLESS bwrap (unprivileged user namespaces). Fresh Ubuntu 24.04+ images
  # restrict those via AppArmor, so `brew install` aborts with "Bubblewrap is
  # required to use the Linux sandbox" even while fetching bubblewrap itself
  # as a dependency. Our formulae install from bottles (no source build), so
  # when no usable rootless bwrap exists, disable the build sandbox for THIS
  # install only instead of failing the whole post-install. The probe mirrors
  # what brew needs: bwrap present AND able to open a user namespace.
  local _no_linux_sandbox=""
  if [[ "$(uname -s)" == "Linux" ]] && \
     ! bwrap --unshare-user --bind / / true >/dev/null 2>&1; then
    _no_linux_sandbox=1
    warn "no usable rootless bwrap — installing ${formula} with HOMEBREW_NO_SANDBOX_LINUX=1 (to restore brew's build sandbox later: sudo apt-get install -y bubblewrap)"
  fi

  echo "    → brew install ${formula}"
  if [[ -n "${_no_linux_sandbox}" ]]; then
    HOMEBREW_NO_SANDBOX_LINUX=1 brew install "${formula}"
  else
    brew install "${formula}"
  fi
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
# 1b. Persist Revenium credentials passed via environment (one-step setup)
# ---------------------------------------------------------------------------
# The revenium CLI is installed by §1 above, so `revenium config set` can never
# run BEFORE the first post-install — which used to force a run → config set →
# re-run dance. Exporting REVENIUM_* before a single post-install run now does
# it all: the values are persisted to the host config here, and the §3 sandbox
# block below prefers the same env values over the config-file parse, so creds
# reach the sandbox in this same run. Mirrors the NemoClaw env-driven install.
if [[ -n "${REVENIUM_API_KEY:-}" ]]; then
  step "Persisting Revenium credentials from environment"
  if revenium config set key "${REVENIUM_API_KEY}" >/dev/null 2>&1; then
    info "API key persisted to host config"
  else
    warn "could not persist API key via 'revenium config set' — sandbox injection still uses the env value this run"
  fi
  if [[ -n "${REVENIUM_TEAM_ID:-}" ]]; then
    revenium config set team-id "${REVENIUM_TEAM_ID}" >/dev/null 2>&1 || warn "could not persist team-id"
  fi
  if [[ -n "${REVENIUM_TENANT_ID:-}" ]]; then
    revenium config set tenant-id "${REVENIUM_TENANT_ID}" >/dev/null 2>&1 || warn "could not persist tenant-id"
  fi
  if [[ -n "${REVENIUM_OWNER_ID:-}" ]]; then
    revenium config set owner-id "${REVENIUM_OWNER_ID}" >/dev/null 2>&1 || warn "could not persist owner-id"
  fi
  if [[ -n "${REVENIUM_API_URL:-}" ]]; then
    revenium config set api-url "${REVENIUM_API_URL}" >/dev/null 2>&1 || warn "could not persist api-url"
  fi
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
for script in cron.sh report.sh common.sh setup-guardrails.sh guardrail-check.sh install-cron.sh uninstall-cron.sh clear-halt.sh post-install.sh write-marker.sh write-job-marker.sh get-root-session-id.py; do
  if [[ -f "${SKILL_DIR}/scripts/${script}" ]]; then
    chmod +x "${SKILL_DIR}/scripts/${script}"
  fi
done
info "Scripts marked executable"

# Seed task-taxonomy.json into SKILL_DIR if absent.
# The repo-root copy is the source of truth; post-install deploys it to the
# install location so write-marker.sh and setup-guardrails.sh can read it.
# Single path per Pitfall 6 — SKILL_DIR and STATE_DIR are the same in OpenClaw.
TAXONOMY_SRC="${SKILL_DIR}/task-taxonomy.json"
TAXONOMY_DST="${SKILL_DIR}/task-taxonomy.json"  # same path (self-contained install)
if [[ ! -f "${TAXONOMY_DST}" ]]; then
  if [[ -f "${TAXONOMY_SRC}" ]]; then
    cp "${TAXONOMY_SRC}" "${TAXONOMY_DST}"
    info "Seeded task-taxonomy.json at ${TAXONOMY_DST}"
  else
    warn "task-taxonomy.json not found at ${TAXONOMY_SRC} — write-marker.sh will fail until it is present"
  fi
else
  info "task-taxonomy.json already present at ${TAXONOMY_DST}"
fi

# Seed job-taxonomy.json into SKILL_DIR if absent.
# The repo-root copy is the source of truth; post-install deploys it to the
# install location so write-job-marker.sh can read it (v1.1 / JOBDEC-01).
JOB_TAXONOMY_SRC="${SKILL_DIR}/job-taxonomy.json"
JOB_TAXONOMY_DST="${SKILL_DIR}/job-taxonomy.json"  # same path (self-contained install)
if [[ ! -f "${JOB_TAXONOMY_DST}" ]]; then
  if [[ -f "${JOB_TAXONOMY_SRC}" ]]; then
    cp "${JOB_TAXONOMY_SRC}" "${JOB_TAXONOMY_DST}"
    info "Seeded job-taxonomy.json at ${JOB_TAXONOMY_DST}"
  else
    warn "job-taxonomy.json not found at ${JOB_TAXONOMY_SRC} — write-job-marker.sh will fail until it is present"
  fi
else
  info "job-taxonomy.json already present at ${JOB_TAXONOMY_DST}"
fi

# Create markers/ directory for per-session marker JSONL files.
# Mode 0700: markers contain task-type + timestamp, accessible only to the owner (ASVS V4 / T-04-18).
mkdir -p "${SKILL_DIR}/markers"
chmod 700 "${SKILL_DIR}/markers"
info "markers/ directory created at ${SKILL_DIR}/markers (mode 0700)"

# ---------------------------------------------------------------------------
# 3. Configure sandbox access
# ---------------------------------------------------------------------------
step "Configuring OpenClaw sandbox access"

# Build the list of bind mounts the agent needs inside the Docker sandbox:
#   - ~/.openclaw (rw) — skills, sessions, logs, ledger, budget-status, config
#   - bin directories containing revenium/jq (ro) — so the agent can invoke CLIs
# NOTE: we used to bind-mount ~/.config/revenium for CLI credentials, but the
# OpenClaw sandbox rejects any bind whose destination falls under ~/.config/
# (treated as a credential path). Credentials are now injected as env vars
# (REVENIUM_API_KEY etc.) further down — see the "revenium credentials" block.
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

# Revenium CLI credentials reach the sandbox as REVENIUM_* env vars (injected in
# the Python block below), NOT via a bind mount. OpenClaw's sandbox HARD-blocks
# any bind whose destination falls under ~/.config/ as a credential path — even
# with dangerouslyAllowExternalBindSources — so mounting ~/.config/revenium
# crashes the gateway on startup (observed on OpenClaw 2026.4.14). revenium
# honors REVENIUM_* env vars over the config file, so we read the host config
# here and export the values for the Python block to inject.
REVENIUM_CONFIG_FILE="${HOME}/.config/revenium/config.yaml"
REV_KEY=""; REV_API_URL=""; REV_TEAM=""; REV_TENANT=""; REV_OWNER=""
if [[ -f "${REVENIUM_CONFIG_FILE}" ]]; then
  REV_KEY=$(sed -n 's/^key:[[:space:]]*//p' "${REVENIUM_CONFIG_FILE}" | head -1)
  REV_API_URL=$(sed -n 's/^api-url:[[:space:]]*//p' "${REVENIUM_CONFIG_FILE}" | head -1)
  REV_TEAM=$(sed -n 's/^team-id:[[:space:]]*//p' "${REVENIUM_CONFIG_FILE}" | head -1)
  REV_TENANT=$(sed -n 's/^tenant-id:[[:space:]]*//p' "${REVENIUM_CONFIG_FILE}" | head -1)
  REV_OWNER=$(sed -n 's/^owner-id:[[:space:]]*//p' "${REVENIUM_CONFIG_FILE}" | head -1)
fi
# Env overrides (one-step setup, §1b): REVENIUM_* values exported for THIS run
# win over the config-file snapshot parsed above — so a fresh install with
# exported creds injects them into the sandbox without a second run.
if [[ -n "${REVENIUM_API_KEY:-}" ]];   then REV_KEY="${REVENIUM_API_KEY}"; fi
if [[ -n "${REVENIUM_API_URL:-}" ]];   then REV_API_URL="${REVENIUM_API_URL}"; fi
if [[ -n "${REVENIUM_TEAM_ID:-}" ]];   then REV_TEAM="${REVENIUM_TEAM_ID}"; fi
if [[ -n "${REVENIUM_TENANT_ID:-}" ]]; then REV_TENANT="${REVENIUM_TENANT_ID}"; fi
if [[ -n "${REVENIUM_OWNER_ID:-}" ]];  then REV_OWNER="${REVENIUM_OWNER_ID}"; fi

export REV_KEY REV_API_URL REV_TEAM REV_TENANT REV_OWNER
if [[ -z "${REV_KEY}" ]]; then
  warn "Revenium API key not set yet at ${REVENIUM_CONFIG_FILE}."
  warn "Either export REVENIUM_API_KEY (+ REVENIUM_TEAM_ID etc.) and re-run post-install.sh,"
  warn "or set them on the host and re-run:  revenium config set key <KEY>   (also team-id, tenant-id, owner-id)"
fi

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

# OpenClaw's sandbox applies TWO independent checks to bind sources:
#   1. Credential/system-path block (~/.config, docker socket): HARD-blocked and
#      NOT overridable by any flag. We satisfy this by never mounting
#      ~/.config/revenium (creds go in as REVENIUM_* env vars below).
#   2. Allowed-roots check: bind sources must sit under ~/.openclaw/workspace
#      unless this flag opts in. The skill legitimately mounts ~/.openclaw (rw,
#      for skills/guardrail-status.json/logs) and the Homebrew bin/lib dirs (ro,
#      for the revenium/jq CLIs) — all outside workspace but trusted, not
#      credential paths. So this MUST stay true, or the gateway rejects those
#      binds with "source is outside allowed roots" and the agent fails to start.
docker["dangerouslyAllowExternalBindSources"] = True

# Inject Revenium credentials as env vars (revenium honors REVENIUM_* over the
# config file). Values come from the host config.yaml, read in the bash block
# above and passed through the environment. Empty values are popped so we never
# write blank creds; the user re-runs post-install after setting credentials to
# refresh them. NOTE: unlike the old live bind mount, env injection is a
# snapshot — credential rotation on the host requires re-running post-install.
import os as _os
for _k, _src in (
    ("REVENIUM_API_KEY", "REV_KEY"),
    ("REVENIUM_API_URL", "REV_API_URL"),
    ("REVENIUM_TEAM_ID", "REV_TEAM"),
    ("REVENIUM_TENANT_ID", "REV_TENANT"),
    ("REVENIUM_OWNER_ID", "REV_OWNER"),
):
    _v = _os.environ.get(_src, "")
    if _v:
        docker["env"][_k] = _v
    else:
        docker["env"].pop(_k, None)

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
# 5. Seed initial guardrail-status.json
# ---------------------------------------------------------------------------
step "Seeding initial guardrail-status.json"

GUARDRAIL_STATUS_FILE="${SKILL_DIR}/guardrail-status.json"

if [[ ! -f "${GUARDRAIL_STATUS_FILE}" ]]; then
  python3 -c "
import json, sys
data = {'halted': False, 'lastChecked': None, 'rules': []}
sys.stdout.write(json.dumps(data, indent=2) + '\n')
" > "${GUARDRAIL_STATUS_FILE}"
  info "Seeded guardrail-status.json placeholder"
else
  info "guardrail-status.json already exists — leaving untouched"
fi

# ---------------------------------------------------------------------------
# 6. Seed initial config.json
# ---------------------------------------------------------------------------
step "Seeding initial config.json"

SKILL_CONFIG_FILE="${SKILL_DIR}/config.json"
if [[ -f "${SKILL_CONFIG_FILE}" ]]; then
  info "config.json already exists — leaving autonomousMode untouched"
else
  AUTONOMOUS_MODE="false"
  if [[ "${REVENIUM_BUDGET_AUTONOMOUS:-}" == "true" || "${REVENIUM_BUDGET_AUTONOMOUS:-}" == "false" ]]; then
    # One-step setup: the env answer wins and the prompt is skipped, so a
    # scripted install never blocks on stdin.
    AUTONOMOUS_MODE="${REVENIUM_BUDGET_AUTONOMOUS}"
    info "autonomousMode=${AUTONOMOUS_MODE} (from REVENIUM_BUDGET_AUTONOMOUS)"
  elif [[ -t 0 && -t 1 ]]; then
    printf "  Will this agent run autonomously with heartbeats? [y/N] "
    read -r AUTO_REPLY || AUTO_REPLY=""
    case "${AUTO_REPLY}" in
      [yY]|[yY][eE][sS]) AUTONOMOUS_MODE="true" ;;
    esac
  else
    info "Non-interactive shell — defaulting autonomousMode to false"
  fi

  cat > "${SKILL_CONFIG_FILE}" <<CJSON
{
  "_comment": "autonomousMode: when true, budget exceedance halts ALL agent operations and sends a notification to the configured channel (requires notifyChannel and notifyTarget). When false (default, interactive mode), the agent warns the user on budget exceedance and asks for permission to continue. Flip this by re-running post-install.sh, invoking /revenium, or editing this file directly.",
  "autonomousMode": ${AUTONOMOUS_MODE}
}
CJSON
  info "Seeded config.json with autonomousMode=${AUTONOMOUS_MODE}"
fi

# ---------------------------------------------------------------------------
# 7. Inject budget check into AGENTS.md
# ---------------------------------------------------------------------------
step "Injecting guardrail check into AGENTS.md"

AGENTS_MD="${OPENCLAW_HOME}/workspace/AGENTS.md"
GUARDRAIL_MARKER="## Guardrail Check (Mandatory)"

if [[ ! -f "${AGENTS_MD}" ]]; then
  warn "AGENTS.md not found at ${AGENTS_MD} — skipping guardrail injection"
elif grep -q "${GUARDRAIL_MARKER}" "${AGENTS_MD}" 2>/dev/null; then
  info "Guardrail check already present in AGENTS.md"
else
  python3 <<PYEOF
section = """
## Guardrail Check (Mandatory)

BEFORE EVERY RESPONSE, NO EXCEPTIONS — read \`~/.openclaw/skills/revenium/guardrail-status.json\`.

- **File missing:** Proceed with caution (metering cron may not be installed yet).
- **\`halted\` is \`false\` AND \`warned\` is \`false\`:** Proceed silently. Do NOT mention guardrails.
- **\`halted\` is \`false\` AND \`warned\` is \`true\`:** Execute the warn-and-ask flow from the "Guardrail Check Procedure" section of \`~/.openclaw/skills/revenium/SKILL.md\` — read \`warnedRules\` from guardrail-status.json, surface one "Budget warning — rule '[name]' ([metricType], [windowType]) at [currentValue] of [hardLimit] hard-limit." line per rule, then ask the user "Do you want me to proceed anyway, or stop?" and WAIT for the answer. Do NOT make any tool calls until the user grants permission.
- **\`halted\` is \`true\`:** YOUR ENTIRE RESPONSE MUST BE EXACTLY the HALT CHECK message from \`~/.openclaw/skills/revenium/SKILL.md\` — substitute values from the \`haltedRule\` block in guardrail-status.json. Do NOT continue with any other response.

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
  info "Injected guardrail check into AGENTS.md"
fi

# ---------------------------------------------------------------------------
# 7b. Inject metering directives (task classification + job declaration) into AGENTS.md
# ---------------------------------------------------------------------------
# These are MANDATORY COMPLETION GATES: OpenClaw loads SKILL.md on demand, so a
# "classify/declare every turn" directive only fires reliably when it lives in
# AGENTS.md (read before every response), like the guardrail check above. The
# directive text is shipped in references/ and injected here so it survives
# reinstall and applies on every install. Idempotent + updatable: any prior
# metering block (sentinel-wrapped OR bare-header) is stripped before re-inject.
step "Injecting metering directives into AGENTS.md"

METERING_SRC="${SKILL_DIR}/references/agents-metering-directives.md"

if [[ ! -f "${AGENTS_MD}" ]]; then
  warn "AGENTS.md not found at ${AGENTS_MD} — skipping metering directive injection"
elif [[ ! -f "${METERING_SRC}" ]]; then
  warn "Metering directive source not found at ${METERING_SRC} — skipping"
else
  AGENTS_MD="${AGENTS_MD}" METERING_SRC="${METERING_SRC}" python3 <<'PYEOF'
import os, re

path = os.environ["AGENTS_MD"]
block = open(os.environ["METERING_SRC"]).read().strip() + "\n"

with open(path) as f:
    content = f.read()

# Strip any prior metering block — sentinel-wrapped form...
content = re.sub(
    r'\n*<!-- BEGIN revenium-metering-directives -->.*?<!-- END revenium-metering-directives -->\n*',
    '\n', content, flags=re.S)
# ...and older bare-header form (hand-edited installs without sentinels).
parts = re.split(r'(?m)^(?=## )', content)
parts = [p for p in parts if not p.startswith('## Revenium Metering ')]
content = ''.join(parts)

# Place it right after the guardrail block, else before ## Memory, else append.
anchor = "This applies to ALL operations — chat, tool calls, code, questions, everything. No task is exempt."
if anchor in content:
    content = content.replace(anchor, anchor + "\n\n" + block, 1)
elif "## Memory" in content:
    content = content.replace("## Memory", block + "\n## Memory", 1)
else:
    content = content.rstrip() + "\n\n" + block

with open(path, "w") as f:
    f.write(content)
print("metering directives synced")
PYEOF
  info "Injected/updated metering directives in AGENTS.md"
fi

# ---------------------------------------------------------------------------
# 7c. Install + enable the revenium-marker-gate plugin
# ---------------------------------------------------------------------------
# Installs the before_agent_finalize plugin that structurally enforces per-turn
# task classification. Idempotent (--force overwrites previous version). The
# allowConversationAccess flag is REQUIRED for before_agent_finalize and agent_end
# to register — without it the hooks are silently blocked (OpenClaw registry
# behaviour verified against 2026.6.1 source). Fail-open: every command uses
# warn-and-continue, never fail. A gateway restart is required after this step
# for the plugin to load in the current session.
step "Installing revenium-marker-gate plugin"

if command_exists openclaw; then
  # Install (idempotent via --force; overwrites previous version)
  openclaw plugins install "${SKILL_DIR}/plugin" --force 2>/dev/null \
    || warn "plugin install failed — skipping"

  # Enable with allowConversationAccess (required for before_agent_finalize + agent_end)
  # Uses JSON5 stdin — objects merge recursively, safe to re-run
  echo '{plugins: {entries: {"revenium-marker-gate": {enabled: true, hooks: {allowConversationAccess: true}}}}}' \
    | openclaw config patch --stdin 2>/dev/null \
    || warn "plugin config patch failed — skipping"

  # Verify that before_agent_finalize is in hookNames — catches the silent-block failure mode
  _inspect="$(openclaw plugins inspect revenium-marker-gate 2>/dev/null || true)"
  if echo "${_inspect}" | grep -q "before_agent_finalize"; then
    info "Plugin hook before_agent_finalize confirmed active"
  else
    warn "before_agent_finalize not in plugin hookNames — allowConversationAccess may not be set"
  fi

  info "NOTE: a gateway restart is required for the plugin to load in the current session"
else
  warn "openclaw CLI not found — skipping plugin install (revenium-marker-gate)"
fi

# ---------------------------------------------------------------------------
# 8. Configure bootstrap-extra-files hook for isolated sessions
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
# 8b. Optional: create the budget guardrail rule + metering cron (env-gated)
# ---------------------------------------------------------------------------
# Mirrors the NemoClaw install: export REVENIUM_BUDGET_LIMIT and
# REVENIUM_BUDGET_PERIOD to create the Revenium budget rule non-interactively
# at install time (REVENIUM_BUDGET_AUTONOMOUS=true → hard-halt on breach;
# REVENIUM_BUDGET_SHADOW=1 → observe-only). A budget implies enforcement, so
# the metering cron that keeps guardrail-status.json fresh is installed in the
# same step. Without these vars, budget + cron setup stays agent-guided via
# /revenium on first run — existing behavior unchanged.
if [[ -n "${REVENIUM_BUDGET_LIMIT:-}" && -n "${REVENIUM_BUDGET_PERIOD:-}" ]]; then
  step "Creating Revenium budget guardrail rule (limit=${REVENIUM_BUDGET_LIMIT}, period=${REVENIUM_BUDGET_PERIOD})"

  if [[ -f "${SKILL_CONFIG_FILE}" ]] && jq -e '(.ruleIds // []) | length > 0' "${SKILL_CONFIG_FILE}" >/dev/null 2>&1; then
    info "Budget rule already configured (ruleIds present in config.json) — skipping creation"
  else
    BUDGET_FLAGS=""
    if [[ "${REVENIUM_BUDGET_AUTONOMOUS:-}" == "true" ]]; then
      BUDGET_FLAGS="--autonomous"
    fi
    if [[ -n "${REVENIUM_BUDGET_SHADOW:-}" ]]; then
      BUDGET_FLAGS="${BUDGET_FLAGS} --shadow-mode"
    fi
    # shellcheck disable=SC2086  # BUDGET_FLAGS is intentionally word-split
    if bash "${SKILL_DIR}/scripts/setup-guardrails.sh" --hard-limit "${REVENIUM_BUDGET_LIMIT}" --period "${REVENIUM_BUDGET_PERIOD}" ${BUDGET_FLAGS}; then
      info "Budget guardrail rule created (ruleIds written to config.json)"
    else
      warn "budget rule creation failed — run setup-guardrails.sh manually or use /revenium (metering is unaffected)"
    fi
  fi

  if bash "${SKILL_DIR}/scripts/install-cron.sh"; then
    info "Metering cron installed/updated"
  else
    warn "metering cron install failed — run install-cron.sh manually (guardrail status stays stale without it)"
  fi
fi

# ---------------------------------------------------------------------------
# 9. Verify
# ---------------------------------------------------------------------------
step "Verifying installation"

if [[ -f "${SKILL_DIR}/SKILL.md" ]]; then
  info "SKILL.md present at ${SKILL_DIR}/SKILL.md"
else
  fail "SKILL.md not found after install"
fi

if [[ -f "${SKILL_DIR}/scripts/guardrail-check.sh" ]]; then
  info "Guardrail scripts present"
else
  warn "Guardrail scripts missing — cron enforcement will not work"
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
  # Capture first, then grep: piping `openclaw skills list` straight into
  # `grep -q` is unsafe under `set -o pipefail` — `grep -q` exits on first match
  # and SIGPIPEs the still-writing producer (141), which pipefail then reports as
  # the pipeline status, racing the gate to a spurious "not visible" result.
  _skills_list="$(openclaw skills list 2>/dev/null || true)"
  if grep -q "${SKILL_NAME}" <<<"${_skills_list}"; then
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
