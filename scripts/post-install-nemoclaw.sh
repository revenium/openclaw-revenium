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

# Set to 1 by ledger_set the first time a provisioning step actually does work,
# so the success banner can distinguish a fresh provision from an idempotent
# re-run where every step was skipped via the ledger (WR-03).
WORK_DONE=0

ledger_set() {
    local key="$1" val="$2"
    WORK_DONE=1
    local ledger_dir
    ledger_dir="$(dirname "${LEDGER_FILE}")"
    mkdir -p "${ledger_dir}"
    # Remove old entry, append new — atomic via .tmp
    { grep -v "^${key}=" "${LEDGER_FILE}" 2>/dev/null || true; \
      echo "${key}=${val}"; } > "${LEDGER_FILE}.tmp" && \
      mv "${LEDGER_FILE}.tmp" "${LEDGER_FILE}"
}

# yaml_dquote — emit a value as a double-quoted YAML scalar with backslash and
# double-quote escaped, so arbitrary credential values (containing ': ', ' #',
# leading indicators, etc.) cannot corrupt the config.yaml structure (WR-02).
yaml_dquote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

# ---------------------------------------------------------------------------
# PATH extension — NemoClaw installs its CLI at ~/.local/bin (Pitfall 6)
# ---------------------------------------------------------------------------
export PATH="${HOME}/.local/bin:${PATH}"

# ---------------------------------------------------------------------------
# Phase 14/15 functions — metering loop + enforcement plugin
# ---------------------------------------------------------------------------
install_metering_loop() {
    if ledger_has "metering-loop-installed"; then
        info "NemoClaw metering loop already installed (ledger) — skipping."
        return 0
    fi

    step "Installing host-side metering loop"
    bash "${SCRIPT_DIR}/install-nemoclaw-cron.sh" --sandbox "${SANDBOX_NAME}" \
        || fail "install-nemoclaw-cron.sh failed"

    ledger_set "metering-loop-installed" "1"
    info "Metering loop installed (cron active for sandbox '${SANDBOX_NAME}')"
}

# install_skill_nemoclaw — deploy the revenium skill into the sandbox via
# nemoclaw skill install (D-08). Pulled into Phase 15 so the marker chain is
# end-to-end verifiable before the plugin smoke gate runs.
# Ledger key: skill-installed-nemoclaw
install_skill_nemoclaw() {
    if ledger_has "skill-installed-nemoclaw"; then
        info "Revenium skill already deployed to sandbox (ledger) — skipping."
        return 0
    fi

    step "Deploying revenium skill into sandbox"
    # SCRIPT_DIR is scripts/; repo root (which IS the skill dir containing SKILL.md)
    # is one level up. REVENIUM_SKILL_DIR may be overridden by tests to point at
    # an alternate dir (e.g. to test the SKILL.md-absent guard on macOS without
    # affecting the real repo root).
    local skill_dir
    skill_dir="${REVENIUM_SKILL_DIR:-${SCRIPT_DIR}/..}"

    # Guard: SKILL.md must be present at the resolved path; if it is absent, the
    # path resolved to ~/ or another wrong location (e.g., due to SSHFS mounts).
    # This prevents the SSHFS unsafe-filename abort that hit every Phase 15 live
    # run (T-16-01).
    if [[ ! -f "${skill_dir}/SKILL.md" ]]; then
        fail "SKILL.md not found at ${skill_dir} — cannot determine skill root. Run the install from the skill directory: bash ~/.openclaw/skills/revenium/scripts/post-install-nemoclaw.sh"
    fi

    nemoclaw "${SANDBOX_NAME}" skill install "${skill_dir}" \
        || fail "nemoclaw skill install failed"

    # Assert ✓ ready in-sandbox (D-02 discovery assertion, T-16-02).
    # The || true guard is mandatory (CR-01): under set -euo pipefail a non-zero
    # exit from the in-sandbox command would abort the script before the fail
    # message prints. grep uses the Unicode-safe two-pipe pattern (not literal ✓).
    local _skill_list
    _skill_list=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        "openclaw skills list 2>/dev/null" 2>/dev/null || true)
    if ! echo "${_skill_list}" | grep "revenium" | grep -q "ready"; then
        fail "revenium skill NOT ready after install — 'openclaw skills list' did not show ready state for revenium. Inspect the sandbox: nemoclaw ${SANDBOX_NAME} status"
    fi
    info "revenium skill confirmed ready in sandbox"

    ledger_set "skill-installed-nemoclaw" "1"
    info "Revenium skill deployed to sandbox '${SANDBOX_NAME}'"
}

# install_enforcement_plugin — deliver, trust-install, configure, recover, and
# fail-HARD validate the combined revenium-enforcement plugin (D-05/D-09/D-10/D-11).
# Includes python3 preflight + marker smoke gate (D-07).
# Ledger key: enforcement-plugin-installed
install_enforcement_plugin() {
    if ledger_has "enforcement-plugin-installed"; then
        info "Enforcement plugin already installed (ledger) — skipping."
        return 0
    fi

    step "Installing revenium-enforcement plugin (NemoClaw)"

    # -------------------------------------------------------------------------
    # Step 1: Establish share mount (Phase 14 pattern — reuse D-11)
    # MNT = SSHFS-mounted /sandbox/.openclaw visible on the host
    # -------------------------------------------------------------------------
    local MNT
    MNT="${HOME}/sbx-openclaw-${SANDBOX_NAME}"
    mkdir -p "${MNT}"
    if ! mountpoint -q "${MNT}" 2>/dev/null; then
        nemoclaw "${SANDBOX_NAME}" share mount /sandbox/.openclaw "${MNT}" \
            || fail "mount failed — is ${SANDBOX_NAME} running?"
    fi
    info "Share mount confirmed at ${MNT}"

    # -------------------------------------------------------------------------
    # Step 2: Copy committed plugin dir to mount (= in-sandbox extensions/)
    # rm -rf dest first for idempotent re-copy (avoids stale-file blends, T-15-09)
    # -------------------------------------------------------------------------
    local plugin_src plugin_dst
    plugin_src="${SCRIPT_DIR}/../plugin-nemoclaw"
    plugin_dst="${MNT}/extensions/revenium-enforcement"
    [[ -d "${plugin_src}" ]] \
        || fail "plugin-nemoclaw/ not found at ${plugin_src} — was Plan 01 committed?"
    rm -rf "${plugin_dst}"
    cp -r "${plugin_src}" "${plugin_dst}"
    info "Plugin dir copied to ${plugin_dst}"

    # -------------------------------------------------------------------------
    # Step 3: Trust-install via openclaw plugins install (T-15-05 provenance gate)
    # A hand-placed copy loads but its hooks are inert — the install records trust.
    # In-sandbox path: /sandbox/.openclaw/extensions/revenium-enforcement
    # --force makes this idempotent: step 2 (cp -r) always places the plugin dir
    # before this call runs, so openclaw plugins install without --force fails on
    # re-runs with "plugin already exists" (CR-01 || true guard cannot fix this —
    # a non-forced re-install leaves the plugin untrusted/inert, not just skipped).
    # --force replaces the existing entry; the fail() guard on the right still fires
    # on genuine errors (bad path, permission denied, etc.).
    # -------------------------------------------------------------------------
    nemoclaw "${SANDBOX_NAME}" exec -- openclaw plugins install --force \
        /sandbox/.openclaw/extensions/revenium-enforcement \
        || fail "openclaw plugins install failed — plugin will be untrusted/inert. Aborting."
    info "Plugin trust-installed via openclaw plugins install"

    # -------------------------------------------------------------------------
    # Step 4: Config patch — enabled:true + allowConversationAccess:true
    # Single-line sh -lc string (nemoclaw exec rejects newline argv, T-15-06).
    # JSON5 merge — re-run-safe. allowConversationAccess required for
    # before_agent_finalize + agent_end hooks to register (Phase 11 D-05 revised).
    # -------------------------------------------------------------------------
    nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        "echo '{plugins: {entries: {\"revenium-enforcement\": {enabled: true, hooks: {allowConversationAccess: true}}}}}' | openclaw config patch --stdin" \
        || fail "plugin config patch failed — cannot enable enforcement plugin. Aborting."
    info "Plugin config patched (enabled:true, allowConversationAccess:true)"

    # -------------------------------------------------------------------------
    # Step 5: Recover to load the plugin
    # -------------------------------------------------------------------------
    nemoclaw "${SANDBOX_NAME}" recover \
        || fail "nemoclaw recover failed after plugin install. Aborting."
    info "Sandbox recovered (plugin loaded)"

    # -------------------------------------------------------------------------
    # Step 6: Fail-HARD validation gate (D-09, D-10)
    # Each gate is stricter than standalone post-install.sh (warn-and-continue)
    # because NCENF-01 is highest-risk: a silently-broken plugin is worse than
    # a failed install.
    # -------------------------------------------------------------------------

    # Gate A (B-01 / NCENF-01): confirm the guard directive was injected by asserting
    # currentTurn.promptChars exceeds a threshold consistent with the +988-char directive
    # delta observed live (no-plugin baseline: 649; with-plugin: 1637; see 15-VALIDATION.md
    # §SC1 "Alternative injection proof — promptChars comparison").
    #
    # Background: the prompt-text field used in earlier versions was removed in OpenClaw
    # 2026.5.22 and is absent from `openclaw agent --json` output on the live host (B-01).
    # Asserting promptChars >= 1500
    # is a robust alternative: well above the 649 no-plugin floor, comfortably below
    # the 1637 observed-with-plugin value, and leaves margin for prompt drift.
    #
    # Parsing: uses grep -oE (POSIX-guaranteed; no jq required) to extract the numeric
    # value from the JSON field "promptChars": <N>. Gate B (openclaw plugins inspect)
    # remains the independent trust/active corroboration (T-15-RS-06).
    local _min_prompt_chars=1500  # conservative threshold; live evidence: 649 → 1637 (+988)
    local _prompt_json _prompt_chars
    _prompt_json=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        "openclaw agent --json --message 'ping' 2>/dev/null" 2>/dev/null || true)
    _prompt_chars=$(echo "${_prompt_json}" | grep -oE '"promptChars"[[:space:]]*:[[:space:]]*[0-9]+' \
        | grep -oE '[0-9]+$' | head -1 || true)
    if [ -z "${_prompt_chars}" ]; then
        fail "guard directive NOT injected — could not parse currentTurn.promptChars from openclaw agent --json. before_prompt_build may be inactive or untrusted. Aborting."
    fi
    if [ "${_prompt_chars}" -lt "${_min_prompt_chars}" ]; then
        fail "guard directive NOT injected — currentTurn.promptChars=${_prompt_chars} below ${_min_prompt_chars}; before_prompt_build inactive or untrusted. Aborting."
    fi
    info "Gate A passed: currentTurn.promptChars=${_prompt_chars} >= ${_min_prompt_chars} — directive injected"

    # Gate B (D-09): confirm before_prompt_build AND before_agent_finalize are active.
    # Missing before_prompt_build → plugin untrusted/inert.
    # Missing before_agent_finalize → allowConversationAccess not applied.
    local _inspect
    _inspect=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        "openclaw plugins inspect revenium-enforcement 2>/dev/null" 2>/dev/null || true)
    if ! echo "${_inspect}" | grep -q "before_prompt_build"; then
        fail "before_prompt_build NOT active in plugins inspect — plugin untrusted or install incomplete. Aborting."
    fi
    if ! echo "${_inspect}" | grep -q "before_agent_finalize"; then
        fail "before_agent_finalize NOT active in plugins inspect — allowConversationAccess may not have taken effect. Aborting."
    fi
    info "Gate B passed: before_prompt_build and before_agent_finalize confirmed active"

    # Gate C (D-07): python3 preflight — write-marker.sh requires it.
    nemoclaw "${SANDBOX_NAME}" exec -- sh -lc "python3 --version" &>/dev/null \
        || fail "python3 not found in sandbox — write-marker.sh will silently fail. Aborting."
    info "Gate C passed: python3 present in sandbox"

    # Gate D (D-07): marker smoke — write a test marker and confirm it appears
    # under the mount (verifies the mount + write path end-to-end).
    nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        "bash ~/.openclaw/skills/revenium/scripts/write-marker.sh testing" 2>/dev/null \
        || fail "marker smoke test failed — write-marker.sh not functional in sandbox. Aborting."
    if ! ls "${MNT}/markers/"*.jsonl &>/dev/null; then
        fail "marker smoke test: no .jsonl file appeared in ${MNT}/markers/ — mount or write path broken. Aborting."
    fi
    info "Gate D passed: marker smoke test — .jsonl visible over mount at ${MNT}/markers/"

    ledger_set "enforcement-plugin-installed" "1"
    info "Enforcement plugin installed and validated (all gates passed)"
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
    # A proxy block produces HTTP=000 (curl exit 56, CONNECT tunnel failed) AND a
    # non-zero curl exit, which propagates out through `sh -lc` and `nemoclaw exec`.
    # Capture the exit code SEPARATELY from stdout — do NOT use `|| echo "000"`:
    # on a block curl already prints "000", so appending another yields "000\n000"
    # (!= "000") and the gap escapes detection, then revenium-policy-applied gets
    # written permanently (CR-01). Treat any non-zero exec, literal 000, or empty
    # output as a proxy block.
    local http_code exec_rc=0
    http_code=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        'curl -sS -o /dev/null -w "%{http_code}" https://api.revenium.ai/ 2>/dev/null' \
        2>/dev/null) || exec_rc=$?

    if [[ "${exec_rc}" -ne 0 || "${http_code}" == "000" || -z "${http_code}" ]]; then
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
    #
    # Each value is emitted as a double-quoted YAML scalar (backslash + quote
    # escaped) so a value containing `: ` (mapping ambiguity) or ` #` (comment
    # truncation) cannot corrupt the field — base64 transport guards shell
    # injection but not YAML structure (WR-02).
    local config_content
    config_content="api-key: $(yaml_dquote "${REVENIUM_API_KEY}")"
    [[ -n "${REVENIUM_TEAM_ID:-}"   ]] && config_content="${config_content}
team-id: $(yaml_dquote "${REVENIUM_TEAM_ID}")"
    [[ -n "${REVENIUM_TENANT_ID:-}" ]] && config_content="${config_content}
tenant-id: $(yaml_dquote "${REVENIUM_TENANT_ID}")"
    [[ -n "${REVENIUM_OWNER_ID:-}"  ]] && config_content="${config_content}
owner-id: $(yaml_dquote "${REVENIUM_OWNER_ID}")"

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
# 5. Phase 14/15 — metering loop + enforcement plugin (real install paths)
#    Order: skill deploy (D-08, marker chain precondition) THEN plugin.
# ---------------------------------------------------------------------------
install_metering_loop
install_skill_nemoclaw         # D-08: deploy skill first (marker chain precondition)
install_enforcement_plugin     # D-05/D-09/D-10/D-11: plugin + validation gate

# ---------------------------------------------------------------------------
# Success banner
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "${WORK_DONE}" -eq 1 ]]; then
    echo "  NemoClaw provisioning complete."
    echo ""
    echo "  Delivered: revenium CLI ${REVENIUM_CLI_VERSION}"
    echo "  Config:    /sandbox/.config/revenium/config.yaml"
    echo "  Probe:     meter-probe-passed"
    echo "  Plugin:    revenium-enforcement (validated)"
else
    echo "  NemoClaw already provisioned — no changes (idempotent re-run)."
    echo ""
    echo "  Every step was skipped via the ledger; existing state is intact."
    echo "  To re-provision (e.g. after an API-key rotation), clear the relevant"
    echo "  keys from ${LEDGER_FILE} (e.g. creds-written, meter-probe-passed)"
    echo "  before re-running — note clearing meter-probe-passed emits a new event."
    echo "  To re-install the enforcement plugin, clear: enforcement-plugin-installed"
fi
echo "  Skill:     revenium (✓ ready)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
