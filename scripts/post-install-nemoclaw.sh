#!/usr/bin/env bash
# =============================================================================
# Revenium OpenClaw Skill — NemoClaw/OpenShell Install Path
#
# Invoked by scripts/install.sh when the NemoClaw target is detected.
# This script is the Phase 12 skeleton: it gates the install behind a host
# preflight probe, checks for the NemoClaw CLI, and runs Phase 13+ stub
# functions. Sandbox provisioning is deferred to Phases 13-16.
#
# Preconditions:
#   - Running on Linux (macOS already refused by install.sh dispatcher)
#   - scripts/probe-host-compat.sh present alongside this script
#
# Idempotency: All Phase 12 operations are naturally idempotent.
#   - Preflight is read-only (checks, no writes)
#   - CLI check is read-only (command_exists, no writes)
#   - Stub functions are no-ops (warn and return)
#   No ledger needed at skeleton stage (D-11); a revenium-nemoclaw.ledger
#   will be introduced in Phase 13+ when real provisioning steps exist.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE_SCRIPT="${SCRIPT_DIR}/probe-host-compat.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "  ✓ $*"; }
warn()  { echo "  ⚠ $*"; }
step()  { echo ""; echo "▸ $*"; }
fail()  { echo ""; echo "  ✗ $*" >&2; exit 1; }

command_exists() { command -v "$1" &>/dev/null; }

# ---------------------------------------------------------------------------
# PATH extension — NemoClaw installs its CLI at ~/.local/bin (Pitfall 6)
# ---------------------------------------------------------------------------
export PATH="${HOME}/.local/bin:${PATH}"

# ---------------------------------------------------------------------------
# Phase 13+ stub functions (D-07)
# Named no-op stubs so Phase 13+ can replace them at well-defined insertion
# points. Each warns with the deferral phase and returns cleanly.
# ---------------------------------------------------------------------------
stub_provision_egress_policy() {
    warn "Phase 13+: egress policy provisioning deferred — skipping."
}

stub_deliver_revenium_cli() {
    warn "Phase 13+: in-sandbox revenium CLI delivery deferred — skipping."
}

stub_install_metering_loop() {
    warn "Phase 14+: host-side metering loop deferred — skipping."
}

stub_install_enforcement_plugin() {
    warn "Phase 15+: per-turn enforcement plugin deferred — skipping."
}

# ---------------------------------------------------------------------------
# 1. Preflight hard gate (D-08/D-09)
# Run probe-host-compat.sh as a subprocess — NEVER sourced (Pitfall 2).
# Probe exit 1 (OS/Docker FAIL) → fail() here stops the install.
# Probe exit 0 (RAM/disk/GPU/Node WARN or clean) → continue install.
# ---------------------------------------------------------------------------
step "Running host compatibility preflight"

[[ -f "${PROBE_SCRIPT}" ]] \
    || fail "probe-host-compat.sh not found at ${PROBE_SCRIPT}"

if ! bash "${PROBE_SCRIPT}"; then
    fail "Host compatibility check failed — NemoClaw requires a Linux host with Docker."
fi
info "Preflight complete (warnings above are non-blocking)"

# ---------------------------------------------------------------------------
# 2. NemoClaw CLI check (D-10 identity-vs-capability)
# Identity signal (~/.nemoclaw/ presence) already triggered routing.
# Capability check: is the nemoclaw CLI available?
# Warn-and-continue if absent (not fail) — it may be installed later.
# ---------------------------------------------------------------------------
step "Checking NemoClaw CLI"
if command_exists nemoclaw; then
    info "nemoclaw CLI found: $(command -v nemoclaw)"
else
    warn "nemoclaw CLI not found on PATH — ensure ~/.local/bin is in PATH"
    warn "NemoClaw installs its CLI at ~/.local/bin. Add: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ---------------------------------------------------------------------------
# 3. Phase 13+ stub functions (D-07)
# Run all four no-op stubs in sequence. Each prints a Phase NN+ deferral
# notice and returns cleanly. No filesystem writes; no ledger needed.
# ---------------------------------------------------------------------------
step "Running Phase 13+ provisioning stubs"
stub_provision_egress_policy
stub_deliver_revenium_cli
stub_install_metering_loop
stub_install_enforcement_plugin

# ---------------------------------------------------------------------------
# Success banner
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  NemoClaw path skeleton complete."
echo ""
echo "  Phases 13-16 will implement sandbox provisioning:"
echo "    Phase 13: egress policy + in-sandbox revenium CLI"
echo "    Phase 14: host-side metering loop"
echo "    Phase 15: per-turn enforcement plugin"
echo "    Phase 16: skill deploy + documentation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
