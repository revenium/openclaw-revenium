#!/usr/bin/env bash
# =============================================================================
# Revenium OpenClaw Skill — Install Dispatcher
#
# Thin dispatcher that detects the install target (standalone OpenClaw vs
# NemoClaw/OpenShell) and routes to the appropriate install script.
#
# Usage:
#   bash scripts/install.sh                 # auto-detect target
#   bash scripts/install.sh --nemoclaw      # force NemoClaw path
#   NEMOCLAW=1 bash scripts/install.sh      # env-var equivalent
#
# Routing (D-03 precedence):
#   1. --nemoclaw flag or NEMOCLAW=1  → NemoClaw path
#   2. ~/.nemoclaw/ exists, ~/.openclaw/ absent → NemoClaw path (auto-detect)
#   3. both dirs present, no flag → standalone path (dual-home rule)
#   4. no NemoClaw signal → standalone path
#
# macOS + NemoClaw signal → explicit refusal (non-zero exit).
# macOS without NemoClaw signal → standalone path (unchanged).
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "  ✓ $*"; }
warn()  { echo "  ⚠ $*"; }
step()  { echo ""; echo "▸ $*"; }
fail()  { echo ""; echo "  ✗ $*" >&2; exit 1; }

command_exists() { command -v "$1" &>/dev/null; }

# ---------------------------------------------------------------------------
# Flag parse
# ---------------------------------------------------------------------------
NEMOCLAW_FLAG=false
PASSTHROUGH_ARGS=()

for arg in "$@"; do
  case "${arg}" in
    --nemoclaw) NEMOCLAW_FLAG=true ;;
    *)          PASSTHROUGH_ARGS+=("${arg}") ;;
  esac
done

# ---------------------------------------------------------------------------
# OS detection — testable via STUB_UNAME_S override (D-06 / Pitfall 3)
# ---------------------------------------------------------------------------
_os="${STUB_UNAME_S:-$(uname -s)}"

# ---------------------------------------------------------------------------
# D-03 routing precedence
# ---------------------------------------------------------------------------
_nemoclaw_dir="${HOME}/.nemoclaw"
_openclaw_dir="${HOME}/.openclaw"
TARGET="standalone"

if [[ "${NEMOCLAW_FLAG}" == true ]] || [[ "${NEMOCLAW:-}" == "1" ]]; then
    TARGET="nemoclaw"
elif [[ -d "${_nemoclaw_dir}" ]] && [[ ! -d "${_openclaw_dir}" ]]; then
    TARGET="nemoclaw"
fi
# Both dirs present + no flag → TARGET stays "standalone" (D-03 dual-home rule)

# ---------------------------------------------------------------------------
# macOS refusal (D-05/D-06) — fires only when TARGET resolved to nemoclaw
# ---------------------------------------------------------------------------
if [[ "${TARGET}" == "nemoclaw" ]] && [[ "${_os}" == "Darwin" ]]; then
    fail "NemoClaw is unsupported on macOS.

  NemoClaw/OpenShell is a Linux-only stack. IMPORTANT: NemoClaw's own
  installer graceful-skips on Darwin (exits 0 without provisioning the
  sandbox) — this looks like success but never installs anything.

  To use the NemoClaw path, provision a Linux host (bare-metal, VM, or
  cloud) with Docker. The standalone OpenClaw path (default, no --nemoclaw
  flag) continues to work on macOS."
fi

# ---------------------------------------------------------------------------
# Script-existence guards
# ---------------------------------------------------------------------------
[[ -f "${SCRIPT_DIR}/post-install-nemoclaw.sh" ]] \
    || fail "post-install-nemoclaw.sh not found in ${SCRIPT_DIR}"
[[ -f "${SCRIPT_DIR}/post-install.sh" ]] \
    || fail "post-install.sh not found in ${SCRIPT_DIR}"

# ---------------------------------------------------------------------------
# Routing dispatch
# ---------------------------------------------------------------------------
if [[ "${TARGET}" == "nemoclaw" ]]; then
    step "Routing to NemoClaw install path"
    bash "${SCRIPT_DIR}/post-install-nemoclaw.sh" \
        "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"
else
    step "Routing to standalone install path"
    bash "${SCRIPT_DIR}/post-install.sh" \
        "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"
fi
