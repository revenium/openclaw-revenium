#!/usr/bin/env bash
# =============================================================================
# Uninstall Revenium Enforcement Plugin (NemoClaw path)
#
# Removes the revenium-enforcement plugin from the named sandbox:
#   1. Runs openclaw plugins uninstall revenium-enforcement in-sandbox (warn on absent)
#   2. Disables the plugin via config patch (single-line sh -lc, nemoclaw exec constraint)
#   3. Removes the plugin dir from the share mount if mounted
#   4. Clears the enforcement-plugin-installed ledger key
#
# Usage:
#   uninstall-enforcement-nemoclaw.sh [--sandbox <name>]
#   export REVENIUM_SANDBOX_NAME=<name> && uninstall-enforcement-nemoclaw.sh
#
# Idempotent: safe to run when nothing is installed (no hard failure on missing plugin).
# Does NOT touch the metering loop, skill install, or any standalone-path file.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Sandbox name resolution (same convention as post-install-nemoclaw.sh)
# ---------------------------------------------------------------------------
SANDBOX_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sandbox)    SANDBOX_NAME="${2:-}"; shift 2 ;;
    --sandbox=*)  SANDBOX_NAME="${1#*=}"; shift ;;
    -h|--help)
      echo "Usage: uninstall-enforcement-nemoclaw.sh [--sandbox <name>]"
      echo "  or: export REVENIUM_SANDBOX_NAME=<name>"
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

SANDBOX_NAME="${REVENIUM_SANDBOX_NAME:-${SANDBOX_NAME:-}}"
if [[ -z "${SANDBOX_NAME}" ]]; then
  echo "ERROR: sandbox name required. Pass --sandbox <name> or export REVENIUM_SANDBOX_NAME." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Ledger helpers (shared pattern from post-install-nemoclaw.sh)
# ---------------------------------------------------------------------------
LEDGER_FILE="${LEDGER_FILE:-${HOME}/.nemoclaw/revenium-nemoclaw.ledger}"

ledger_has() {
    local key="$1"
    grep -q "^${key}=" "${LEDGER_FILE}" 2>/dev/null
}

ledger_clear() {
    local key="$1"
    if [[ -f "${LEDGER_FILE}" ]]; then
        { grep -v "^${key}=" "${LEDGER_FILE}" 2>/dev/null || true; } > "${LEDGER_FILE}.tmp" && \
            mv "${LEDGER_FILE}.tmp" "${LEDGER_FILE}"
    fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "  ✓ $*"; }
warn()  { echo "  ⚠ $*"; }
step()  { echo ""; echo "▸ $*"; }

# ---------------------------------------------------------------------------
# Step 1: Uninstall the plugin in-sandbox (warn-and-continue — teardown is
# best-effort; the plugin may already be absent).
# Single-line sh -lc string (nemoclaw exec rejects newline argv).
# ---------------------------------------------------------------------------
step "Uninstalling revenium-enforcement plugin from sandbox '${SANDBOX_NAME}'"

if command -v nemoclaw &>/dev/null; then
    local_uninstall_rc=0
    nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        "openclaw plugins uninstall revenium-enforcement 2>/dev/null || true" \
        2>/dev/null || local_uninstall_rc=$?
    if [[ "${local_uninstall_rc}" -ne 0 ]]; then
        warn "plugins uninstall returned non-zero (plugin may already be absent) — continuing"
    else
        info "openclaw plugins uninstall revenium-enforcement completed"
    fi
else
    warn "nemoclaw CLI not found — skipping in-sandbox plugin uninstall"
fi

# ---------------------------------------------------------------------------
# Step 2: Disable the plugin via config patch (best-effort, single-line).
# Sets enabled:false so a future install starts clean.
# ---------------------------------------------------------------------------
if command -v nemoclaw &>/dev/null; then
    disable_rc=0
    nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        "echo '{plugins: {entries: {\"revenium-enforcement\": {enabled: false}}}}' | openclaw config patch --stdin 2>/dev/null || true" \
        2>/dev/null || disable_rc=$?
    if [[ "${disable_rc}" -ne 0 ]]; then
        warn "config patch (disable) returned non-zero — continuing"
    else
        info "Plugin config entry set to enabled:false"
    fi
fi

# ---------------------------------------------------------------------------
# Step 3: Remove plugin dir from share mount if mounted.
# Mount path is ${HOME}/sbx-openclaw-${SANDBOX_NAME} — same as install path.
# Does not unmount the share (metering loop may still need it).
# ---------------------------------------------------------------------------
MNT="${HOME}/sbx-openclaw-${SANDBOX_NAME}"
PLUGIN_DST="${MNT}/extensions/revenium-enforcement"

if mountpoint -q "${MNT}" 2>/dev/null; then
    if [[ -d "${PLUGIN_DST}" ]]; then
        rm -rf "${PLUGIN_DST}" && info "Removed ${PLUGIN_DST}" || warn "Could not remove ${PLUGIN_DST} — continuing"
    else
        info "Plugin dir ${PLUGIN_DST} not found on mount (already removed or never copied)"
    fi
else
    warn "Mount ${MNT} not active — skipping plugin dir removal (will be absent on next mount)"
fi

# ---------------------------------------------------------------------------
# Step 4: Clear the ledger key so a later install re-provisions from scratch.
# ---------------------------------------------------------------------------
if ledger_has "enforcement-plugin-installed"; then
    ledger_clear "enforcement-plugin-installed"
    info "Cleared ledger key: enforcement-plugin-installed"
else
    info "Ledger key enforcement-plugin-installed was not set (nothing to clear)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  revenium-enforcement plugin uninstalled for sandbox '${SANDBOX_NAME}'."
echo ""
echo "  To reinstall, re-run: bash scripts/post-install-nemoclaw.sh"
echo "  (the enforcement-plugin-installed ledger key is now clear)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
