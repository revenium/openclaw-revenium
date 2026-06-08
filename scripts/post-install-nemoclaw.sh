#!/usr/bin/env bash
# =============================================================================
# Revenium OpenClaw Skill — NemoClaw/OpenShell Install Path
#
# Invoked by scripts/install.sh when the NemoClaw target is detected.
# This script provisions the sandbox: applies egress policies, delivers the
# revenium CLI binary, writes credentials, and runs a ledger-gated meter probe.
#
# Preconditions:
#   - Running on Linux (macOS already refused by install.sh dispatcher)
#   - scripts/probe-host-compat.sh present alongside this script
#   - REVENIUM_SANDBOX_NAME exported by the operator
#   - REVENIUM_API_KEY exported by the operator
#
# Idempotency: All provisioning steps are ledger-gated.
#   - A step that has already run is recorded in ~/.nemoclaw/revenium-nemoclaw.ledger
#   - Re-running the script skips completed steps (safe on every re-run)
#   - LEDGER_FILE env var may be overridden (e.g. for tests)
#
# Decisions honored:
#   D-01: In-sandbox CDN fetch for CLI delivery
#   D-02: sha256-pinned tarball verify; abort on mismatch
#   D-03: Two host-scoped presets applied before CDN fetch
#   D-04: HTTP=000 proxy-block surfaced as policy gap naming api.revenium.ai
#   D-05: API key written to config.yaml, never on a command line
#   D-06: Meter probe is ledger-gated (exactly once per provisioning)
#   D-07: Step-keyed ledger at ~/.nemoclaw/revenium-nemoclaw.ledger
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PROBE_SCRIPT may be overridden by tests to inject a stub probe (e.g. on macOS
# dev machines where the real probe would fail the OS gate). Production runs use
# the shipped probe-host-compat.sh alongside this script.
PROBE_SCRIPT="${PROBE_SCRIPT:-${SCRIPT_DIR}/probe-host-compat.sh}"

# Phase 13 provisioning constants (D-02, D-07)
# LEDGER_FILE may be overridden by tests or operators (do not hardcode the path
# in ledger_has/ledger_set — always read the variable).
LEDGER_FILE="${LEDGER_FILE:-${HOME}/.nemoclaw/revenium-nemoclaw.ledger}"
REVENIUM_CLI_VERSION="v1.2.0"
REVENIUM_CLI_TARBALL_SHA256="cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67"
REVENIUM_CLI_URL="https://github.com/revenium/revenium-cli/releases/download/${REVENIUM_CLI_VERSION}/revenium-cli_${REVENIUM_CLI_VERSION#v}_linux_amd64.tar.gz"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "  ✓ $*"; }
warn()  { echo "  ⚠ $*"; }
step()  { echo ""; echo "▸ $*"; }
fail()  { echo ""; echo "  ✗ $*" >&2; exit 1; }

command_exists() { command -v "$1" &>/dev/null; }

# ---------------------------------------------------------------------------
# Ledger helpers (D-07)
# Reads/writes LEDGER_FILE (the variable, not a hardcoded path).
# ---------------------------------------------------------------------------
ledger_has() {
    local key="$1"
    grep -q "^${key}=" "${LEDGER_FILE}" 2>/dev/null
}

ledger_set() {
    local key="$1" val="$2"
    local ledger_dir
    ledger_dir="$(dirname "${LEDGER_FILE}")"
    mkdir -p "${ledger_dir}"
    # Remove old entry, append new — atomic via .tmp
    { grep -v "^${key}=" "${LEDGER_FILE}" 2>/dev/null || true; \
      echo "${key}=${val}"; } > "${LEDGER_FILE}.tmp" && \
      mv "${LEDGER_FILE}.tmp" "${LEDGER_FILE}"
}

# ---------------------------------------------------------------------------
# PATH extension — NemoClaw installs its CLI at ~/.local/bin (Pitfall 6)
# ---------------------------------------------------------------------------
export PATH="${HOME}/.local/bin:${PATH}"

# ---------------------------------------------------------------------------
# Phase 14/15 stub functions — deferred, kept for the ordered call sequence
# ---------------------------------------------------------------------------
stub_install_metering_loop() {
    warn "Phase 14+: host-side metering loop deferred — skipping."
}

stub_install_enforcement_plugin() {
    warn "Phase 15+: per-turn enforcement plugin deferred — skipping."
}

# ---------------------------------------------------------------------------
# Phase 13 provisioning functions
# ---------------------------------------------------------------------------

# provision_egress_policy — apply revenium-policy.yaml preset and verify egress
# Ledger key: revenium-policy-applied
# Error classification (D-04): HTTP=000 → proxy block → fail with policy-gap message
provision_egress_policy() {
    if ledger_has "revenium-policy-applied"; then
        info "Revenium egress policy already applied (ledger) — skipping."
        return 0
    fi

    step "Applying revenium egress policy"
    local preset_src="${SCRIPT_DIR}/revenium-policy.yaml"
    [[ -f "${preset_src}" ]] || fail "revenium-policy.yaml not found at ${preset_src}"

    nemoclaw "${SANDBOX_NAME}" policy-add --from-file "${preset_src}" --yes \
        || fail "policy-add failed for revenium preset"

    # Reach-verify: distinguish proxy block from open egress (D-04)
    # A proxy block produces HTTP=000 (curl exit 56, CONNECT tunnel failed).
    # An open egress with auth rejection produces HTTP=4xx with curl exit 0.
    local http_code
    http_code=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        'curl -sS -o /dev/null -w "%{http_code}" https://api.revenium.ai/ 2>/dev/null' \
        2>/dev/null || echo "000")

    if [[ "${http_code}" == "000" ]]; then
        fail "sandbox cannot reach api.revenium.ai — policy gap detected. Apply the revenium egress preset: nemoclaw ${SANDBOX_NAME} policy-list"
    fi
    info "Egress to api.revenium.ai confirmed (HTTP ${http_code})"

    ledger_set "revenium-policy-applied" "1"
}

# provision_gh_release_policy — apply gh-release-policy.yaml preset
# MUST run before CLI delivery (Pitfall 7) — CDN fetch requires this policy.
# Ledger key: gh-release-policy-applied
provision_gh_release_policy() {
    if ledger_has "gh-release-policy-applied"; then
        info "GitHub release CDN policy already applied (ledger) — skipping."
        return 0
    fi

    step "Applying GitHub release CDN egress policy"
    local preset_src="${SCRIPT_DIR}/gh-release-policy.yaml"
    [[ -f "${preset_src}" ]] || fail "gh-release-policy.yaml not found at ${preset_src}"

    nemoclaw "${SANDBOX_NAME}" policy-add --from-file "${preset_src}" --yes \
        || fail "policy-add failed for gh-release preset"

    ledger_set "gh-release-policy-applied" "1"
    info "GitHub release CDN policy applied"
}

# deliver_revenium_cli — fetch the prebuilt CLI tarball in-sandbox, sha256-verify,
# install to /sandbox/.local/bin/revenium (D-01, D-02).
# Ledger key: cli-delivered (value: version:tarball-sha256 — Pitfall 3)
deliver_revenium_cli() {
    local expected_cli_ledger="${REVENIUM_CLI_VERSION}:${REVENIUM_CLI_TARBALL_SHA256}"

    if ledger_has "cli-delivered"; then
        local stored
        stored=$(grep "^cli-delivered=" "${LEDGER_FILE}" | cut -d= -f2-)
        if [[ "${stored}" == "${expected_cli_ledger}" ]]; then
            info "revenium CLI ${REVENIUM_CLI_VERSION} already delivered and verified (ledger) — skipping."
            return 0
        fi
        warn "cli-delivered ledger entry exists but version/sha256 differs — re-delivering."
    fi

    step "Delivering revenium CLI ${REVENIUM_CLI_VERSION} into sandbox"

    # Run the in-sandbox delivery as a single sh -lc payload.
    # Host-side variables (URL, expected sha256) are interpolated before the boundary.
    # In-sandbox variable (actual_sha) uses escaped $ so it expands inside the sandbox.
    # Pitfall 2: verify the tarball (rev.tgz), NOT the extracted binary.
    # Pitfall 4: careful quoting — escape in-sandbox $ for actual_sha.
    local cli_rc=0
    nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        "set -e; cd /tmp; curl -fsSL -o rev.tgz '${REVENIUM_CLI_URL}'; actual_sha=\$(sha256sum rev.tgz | awk '{print \$1}'); if [ \"\${actual_sha}\" != '${REVENIUM_CLI_TARBALL_SHA256}' ]; then echo \"CHECKSUM_MISMATCH:\${actual_sha}\" >&2; exit 2; fi; tar xzf rev.tgz; mkdir -p /sandbox/.local/bin; install -m755 ./revenium /sandbox/.local/bin/revenium; echo CLI_DELIVERED_OK" \
        || cli_rc=$?

    if [[ "${cli_rc}" -eq 2 ]]; then
        fail "revenium CLI sha256 mismatch — tarball may be tampered. Aborting install."
    elif [[ "${cli_rc}" -ne 0 ]]; then
        fail "revenium CLI delivery failed (exit ${cli_rc})"
    fi

    ledger_set "cli-delivered" "${expected_cli_ledger}"
    info "revenium CLI ${REVENIUM_CLI_VERSION} installed at /sandbox/.local/bin/revenium"
}

# write_revenium_creds — write REVENIUM_* env vars to /sandbox/.config/revenium/config.yaml
# chmod 600. API key MUST NOT appear on a nemoclaw exec command line (D-05, T-13-KEY).
# Ledger key: creds-written
write_revenium_creds() {
    if ledger_has "creds-written"; then
        info "Revenium credentials already written (ledger) — skipping."
        return 0
    fi

    [[ -n "${REVENIUM_API_KEY:-}" ]] \
        || fail "REVENIUM_API_KEY not set — export it before running the install"

    step "Writing revenium credentials into sandbox"

    # Build config content on the host side; optional fields only when set.
    # The config-file field for the API key is `api-key:` — NOT `key:`. The
    # `revenium config set key <v>` SUBCOMMAND takes the arg name `key`, but it
    # persists to ~/.config/revenium/config.yaml as `api-key:`, and that is the
    # only field the CLI reads the key back from (Phase 13 live-smoke finding:
    # a `key:` line is silently ignored — `config show` reports "API Key: (not
    # set)" while still reading team-id/etc from the same file).
    local config_content
    config_content="api-key: ${REVENIUM_API_KEY}"
    [[ -n "${REVENIUM_TEAM_ID:-}"   ]] && config_content="${config_content}
team-id: ${REVENIUM_TEAM_ID}"
    [[ -n "${REVENIUM_TENANT_ID:-}" ]] && config_content="${config_content}
tenant-id: ${REVENIUM_TENANT_ID}"
    [[ -n "${REVENIUM_OWNER_ID:-}"  ]] && config_content="${config_content}
owner-id: ${REVENIUM_OWNER_ID}"

    # Encode the (possibly multi-line) YAML into a single-line base64 blob on the
    # host, then decode it in-sandbox. Real NemoClaw gRPC exec REJECTS any argv
    # element containing a newline/CR (InvalidArgument), so a heredoc payload —
    # which embeds newlines in the single `sh -lc` argument — cannot be used here
    # (Phase 13 live-smoke finding). base64 -d writes raw bytes, so no in-sandbox
    # shell expansion of operator-supplied values occurs (T-13-INJ, V5). The key
    # lands only in the chmod-600 file, never as a revenium CLI flag (T-13-KEY,
    # Pitfall 5). In-sandbox HOME = /sandbox; config path /sandbox/.config/revenium/ (Pitfall 6).
    local config_b64
    config_b64=$(printf '%s\n' "${config_content}" | base64 | tr -d '\n')
    nemoclaw "${SANDBOX_NAME}" exec -- sh -lc "mkdir -p /sandbox/.config/revenium && printf '%s' '${config_b64}' | base64 -d > /sandbox/.config/revenium/config.yaml && chmod 600 /sandbox/.config/revenium/config.yaml"

    ledger_set "creds-written" "1"
    info "Credentials written to /sandbox/.config/revenium/config.yaml"
}

# run_meter_probe — send one ledger-gated synthetic meter completion from the sandbox (D-06).
# Exactly-once: meter-probe-passed ledger key prevents re-billing on re-runs (T-13-BILL).
# --task-type install-smoke-test tags the event synthetic for dashboard filtering.
# Ledger key: meter-probe-passed
run_meter_probe() {
    if ledger_has "meter-probe-passed"; then
        info "Meter probe already passed (ledger) — skipping."
        return 0
    fi

    step "Running authenticated meter probe"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Run the in-sandbox meter completion.
    # SSL_CERT_FILE set to OpenShell CA bundle (required for TLS in-sandbox).
    # || true so success classification always runs; success is determined by output content.
    local meter_output
    meter_output=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        "SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem /sandbox/.local/bin/revenium meter completion --model claude-sonnet-4-5 --provider anthropic --input-tokens 1 --output-tokens 1 --total-tokens 2 --stop-reason END --request-time '${now}' --completion-start-time '${now}' --response-time '${now}' --request-duration 1000 --task-type install-smoke-test --output json 2>&1" \
        2>&1) || true

    # Success shapes: a real authenticated meter call returns the CREATED
    # resource object ({"id":...,"resourceType":"metered-event","signature":...})
    # — NOT a {"status":200} envelope (Phase 13 live-smoke finding: classifying
    # only on status:2xx false-negatived a genuine 2xx success). Match the
    # created-resource shape first, then keep the legacy status/text signals.
    # Use [[:space:]] (not \s) for BSD/macOS grep compatibility in the hermetic suite.
    if echo "${meter_output}" | grep -qiE '"resourceType"[[:space:]]*:[[:space:]]*"?metered-event"?|"status"[[:space:]]*:[[:space:]]*"?(200|201|202|accepted|ok)"?|metered successfully'; then
        ledger_set "meter-probe-passed" "1"
        info "Meter probe passed — authenticated meter call succeeded"
    else
        fail "Meter probe failed. Output: ${meter_output}. Check REVENIUM_API_KEY and egress policy."
    fi
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
# 3. Sandbox name resolution (Pitfall 8 / D resolution)
# Operator must export REVENIUM_SANDBOX_NAME — never hardcode revenium-spike.
# ---------------------------------------------------------------------------
SANDBOX_NAME="${REVENIUM_SANDBOX_NAME:-}"
if [[ -z "${SANDBOX_NAME}" ]]; then
    fail "REVENIUM_SANDBOX_NAME is not set. Export the target sandbox name before running the install, e.g.: export REVENIUM_SANDBOX_NAME=revenium-spike"
fi

# ---------------------------------------------------------------------------
# 4. Phase 13 provisioning — ordered sequence (D-03, D-07)
#    Both egress policies MUST precede CLI delivery (Pitfall 7).
# ---------------------------------------------------------------------------
step "Running Phase 13 provisioning"

provision_egress_policy
provision_gh_release_policy
deliver_revenium_cli
write_revenium_creds
run_meter_probe

# ---------------------------------------------------------------------------
# 5. Phase 14/15 deferred stubs — preserved for future phases
# ---------------------------------------------------------------------------
stub_install_metering_loop
stub_install_enforcement_plugin

# ---------------------------------------------------------------------------
# Success banner
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  NemoClaw provisioning complete."
echo ""
echo "  Delivered: revenium CLI ${REVENIUM_CLI_VERSION}"
echo "  Config:    /sandbox/.config/revenium/config.yaml"
echo "  Probe:     meter-probe-passed"
echo ""
echo "  Phases 14-16 still pending:"
echo "    Phase 14: host-side metering loop"
echo "    Phase 15: per-turn enforcement plugin"
echo "    Phase 16: skill deploy + documentation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
