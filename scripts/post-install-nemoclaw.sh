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
# in ledger_has/ledger_set — always read the variable). If left unset it is
# computed PER-SANDBOX-INSTANCE after sandbox resolution (see section 3b) so a
# second sandbox — or a destroyed+recreated one — gets its own ledger instead of
# being skipped wholesale by a stale host-global ledger.
LEDGER_FILE="${LEDGER_FILE:-}"
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
# nemoclaw — timeout-guarded wrapper over the real nemoclaw binary.
# A wedged in-sandbox OpenClaw gateway makes `nemoclaw exec`/`recover` hang
# indefinitely (observed live 2026-06-12: an `openclaw skills list` exec hung
# the install for 1h+). This function shadows the binary for every call site
# in this script and enforces a hard ceiling, so a wedged gateway fails the
# install with an actionable message instead of hanging it.
#
# Ceilings are sized per call shape (live agent turns legitimately take
# 70-120s+); override any single call with NEMOCLAW_TIMEOUT_SECONDS=<n>.
# `timeout` is coreutils — always present on the Linux hosts this path gates
# on; if absent (macOS hermetic-test runs) the call passes through unguarded.
# `timeout` execs nemoclaw via PATH, so test stubs keep working.
# ---------------------------------------------------------------------------
nemoclaw() {
    local _secs="${NEMOCLAW_TIMEOUT_SECONDS:-}"
    if [[ -z "${_secs}" ]]; then
        case "$*" in
            *"openclaw agent"*)   _secs=300 ;;  # live agent turn (Gate A)
            *" recover"*)         _secs=240 ;;  # sandbox/gateway restart
            *" skill install "*)  _secs=240 ;;  # copies the skill tree
            *)                    _secs=120 ;;  # exec one-shots, inspect, etc.
        esac
    fi
    local _rc=0
    if command_exists timeout; then
        timeout "${_secs}" nemoclaw "$@" || _rc=$?
    else
        command nemoclaw "$@" || _rc=$?
    fi
    if [[ "${_rc}" -eq 124 ]]; then
        warn "nemoclaw call timed out after ${_secs}s (args: ${1:-} ${2:-} ...) — the in-sandbox gateway may be wedged. Try: nemoclaw ${SANDBOX_NAME:-<name>} recover, then re-run the install."
    fi
    return "${_rc}"
}

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

# ensure_mount <mnt> — guarantee a usable SSHFS share mount at <mnt>, robustly.
# Single source of truth for SSHFS mount handling (used by every mount site). It is
# deliberately bulletproof against SSHFS flakiness:
#   - Health is judged by stat-ing the MOUNTPOINT ROOT (not a subdirectory), so a
#     transient subdir cache-lag never makes a healthy mount look broken.
#   - A mount that is in /proc/mounts but whose root won't stat is dead/stale — it is
#     lazily unmounted before remounting.
#   - "already mounted / already exists" from `nemoclaw share mount` is treated as
#     SUCCESS (the mount is present), never a fatal error.
#   - A healthy mount is NEVER torn down.
# Returns 0 iff <mnt> ends up mounted and its root is accessible.
ensure_mount() {
    local mnt="$1" _try _out
    for _try in 1 2 3; do
        # Healthy: a live mount (in the table AND the root stats OK), OR the skill dir
        # is already visible through it. The first clause wins for a real cache-lagged
        # mount (stat the ROOT, not the lagging subdir); the second covers the
        # already-populated case (and the hermetic test harness, which has no /proc/mounts entry).
        if { grep -qsF " ${mnt} " /proc/mounts 2>/dev/null && stat "${mnt}" >/dev/null 2>&1; } || [ -d "${mnt}/skills" ]; then
            return 0
        fi
        # Listed but the root won't stat → dead/stale → clear it.
        if grep -qsF " ${mnt} " /proc/mounts 2>/dev/null; then
            fusermount -u "${mnt}" 2>/dev/null || umount -l "${mnt}" 2>/dev/null || true
            sleep 1
        fi
        mkdir -p "${mnt}" 2>/dev/null || true
        _out=$(nemoclaw "${SANDBOX_NAME}" share mount /sandbox/.openclaw "${mnt}" 2>&1 || true)
        # "already mounted/exists" means it is present — re-evaluate at the top.
        echo "${_out}" | grep -qiE "already exists|already mounted" && continue
        sleep 1
    done
    { grep -qsF " ${mnt} " /proc/mounts 2>/dev/null && stat "${mnt}" >/dev/null 2>&1; } || [ -d "${mnt}/skills" ]
}

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
    # The || true guard is mandatory: under set -euo pipefail a non-zero
    # exit from the in-sandbox command would abort the script before the fail
    # message prints. grep uses the Unicode-safe two-pipe pattern (not literal ✓).
    # The second grep anchors "ready" as a whole word — requires whitespace or
    # line boundary on both sides — so "not-ready" and "already" are rejected.
    local _skill_list
    _skill_list=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        "openclaw skills list 2>/dev/null" 2>/dev/null || true)
    if ! echo "${_skill_list}" | grep "revenium" | grep -Eq '(^|[[:space:]])ready([[:space:]]|$)'; then
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
    ensure_mount "${MNT}" || fail "mount failed — is ${SANDBOX_NAME} running?"
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
    local _default_agent _prompt_json _prompt_chars
    # v2026.5.22: `openclaw agent` requires a routing target — with no existing
    # session and no --agent it errors "No target session selected. Use --agent
    # <id>" and emits no JSON (the probe then false-fails). Derive the default
    # agent from the "(default)" row of `openclaw agents list` and pass it via
    # --agent so the turn runs and returns currentTurn.promptChars. Fall back to
    # "main" (the standard default agent) if the list can't be parsed.
    _default_agent=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        "openclaw agents list 2>/dev/null" 2>/dev/null \
        | awk '/\(default\)/ {print $2; exit}' || true)
    _default_agent="${_default_agent:-main}"
    _prompt_json=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        "openclaw agent --agent ${_default_agent} --json --message 'ping' 2>/dev/null" 2>/dev/null || true)
    _prompt_chars=$(echo "${_prompt_json}" | grep -oE '"promptChars"[[:space:]]*:[[:space:]]*[0-9]+' \
        | grep -oE '[0-9]+$' | head -1 || true)
    if [ -z "${_prompt_chars}" ]; then
        fail "guard directive NOT injected — could not parse currentTurn.promptChars from 'openclaw agent --agent ${_default_agent} --json'. before_prompt_build may be inactive or untrusted. Aborting."
    fi
    if [ "${_prompt_chars}" -lt "${_min_prompt_chars}" ]; then
        fail "guard directive NOT injected — currentTurn.promptChars=${_prompt_chars} below ${_min_prompt_chars}; before_prompt_build inactive or untrusted. Aborting."
    fi
    info "Gate A passed: currentTurn.promptChars=${_prompt_chars} >= ${_min_prompt_chars} (agent '${_default_agent}') — directive injected"

    # Gate B (D-09): confirm the plugin is loaded and conversation access is granted.
    # v2026.5.22's `openclaw plugins inspect` no longer enumerates hook names
    # (before_prompt_build/before_agent_finalize are absent from the output). It
    # reports trust/load state as "Status: loaded" and the applied policy as
    # "allowConversationAccess: true". Gate A already proved before_prompt_build
    # fired (promptChars elevated); this gate confirms the plugin is trusted/loaded
    # and that allowConversationAccess (required for the before_agent_finalize
    # marker gate to register) took effect.
    local _inspect
    _inspect=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        "openclaw plugins inspect revenium-enforcement 2>/dev/null" 2>/dev/null || true)
    if ! echo "${_inspect}" | grep -qE "Status:[[:space:]]*loaded"; then
        fail "revenium-enforcement NOT loaded ('Status: loaded' absent from plugins inspect) — plugin untrusted or install incomplete. Aborting."
    fi
    if ! echo "${_inspect}" | grep -qE "allowConversationAccess:[[:space:]]*true"; then
        fail "allowConversationAccess not applied (plugins inspect) — before_agent_finalize marker gate will not register. Aborting."
    fi
    info "Gate B passed: revenium-enforcement loaded and allowConversationAccess:true confirmed"

    # Gate C (D-07): python3 preflight — write-marker.sh requires it.
    nemoclaw "${SANDBOX_NAME}" exec -- sh -lc "python3 --version" &>/dev/null \
        || fail "python3 not found in sandbox — write-marker.sh will silently fail. Aborting."
    info "Gate C passed: python3 present in sandbox"

    # Gate D (D-07): marker smoke — write a test marker and confirm it appears
    # under the mount (verifies the mount + write path end-to-end). The smoke
    # uses a valid task-taxonomy label ('debugging') — write-marker.sh rejects
    # any label not in task-taxonomy.json. In-sandbox the skill (and its markers/
    # dir) lives at $OPENCLAW_HOME/.openclaw/skills/revenium, and MNT mounts
    # /sandbox/.openclaw, so the marker is visible over the mount at
    # ${MNT}/skills/revenium/markers/ (NOT ${MNT}/markers/).
    # The write itself is the primary proof write-marker.sh works in-sandbox; a
    # failure here IS fatal. The mount-visibility check below is secondary.
    nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        "bash ~/.openclaw/skills/revenium/scripts/write-marker.sh debugging" 2>/dev/null \
        || fail "marker smoke test failed — write-marker.sh not functional in sandbox. Aborting."
    # SSHFS dir/attribute caching can lag a freshly-created file in the host's mount
    # view, so poll briefly before deciding. If it still isn't visible, WARN and
    # continue rather than aborting the whole install — the marker did write
    # in-sandbox, and the metering loop self-heals the mount at runtime.
    local _marker_seen=0 _i
    for _i in 1 2 3 4 5 6; do
        if ls "${MNT}/skills/revenium/markers/"*.jsonl >/dev/null 2>&1; then _marker_seen=1; break; fi
        sleep 2
    done
    if [ "${_marker_seen}" -eq 1 ]; then
        info "Gate D passed: marker smoke test — .jsonl visible over mount at ${MNT}/skills/revenium/markers/"
    else
        warn "Gate D: marker wrote in-sandbox but is not yet visible over the mount at ${MNT}/skills/revenium/markers/ (SSHFS cache lag or mount drift) — continuing; the metering loop self-heals the mount each tick."
    fi

    ledger_set "enforcement-plugin-installed" "1"
    info "Enforcement plugin installed and validated (all gates passed)"
}

# provision_budget_guardrails — create the Revenium budget guardrail rule at install
# time and write its ruleIds into the IN-SANDBOX config.json, so guardrail-check.sh
# (host cron over the mount) has rules to enforce and the agent sees a configured
# budget. The standalone path creates rules via the agent-guided interactive flow,
# which does not run inside a NemoClaw sandbox; this is the non-interactive
# equivalent. Gated on REVENIUM_BUDGET_LIMIT + REVENIUM_BUDGET_PERIOD — without them,
# budget setup is left to the operator (run setup-guardrails.sh afterward). Optional
# REVENIUM_BUDGET_AUTONOMOUS=true sets autonomousMode=true (breach → hard halt instead
# of warn-and-ask). Runs the unmodified setup-guardrails.sh on the host with
# OPENCLAW_HOME=<mount> so config.json lands in the sandbox. Ledger key: budget-rules-created.
provision_budget_guardrails() {
    if ledger_has "budget-rules-created"; then
        info "Budget guardrail rules already created (ledger) — skipping."
        return 0
    fi

    if [[ -z "${REVENIUM_BUDGET_LIMIT:-}" || -z "${REVENIUM_BUDGET_PERIOD:-}" ]]; then
        info "Budget guardrails not auto-created — set REVENIUM_BUDGET_LIMIT and REVENIUM_BUDGET_PERIOD (e.g. 100 MONTHLY) to create a budget at install time, or run setup-guardrails.sh (--hard-limit/--period) afterward. Metering is unaffected."
        return 0
    fi

    local autonomous_label="warn-and-ask"
    [[ "${REVENIUM_BUDGET_AUTONOMOUS:-}" == "true" ]] && autonomous_label="hard-halt (autonomous)"
    step "Creating Revenium budget guardrail rule (limit=${REVENIUM_BUDGET_LIMIT}, period=${REVENIUM_BUDGET_PERIOD}, breach=${autonomous_label})"

    # Establish the SSHFS mount so setup-guardrails.sh writes config.json into the
    # IN-SANDBOX skill dir (OPENCLAW_HOME=mount → STATE_DIR=mount/skills/revenium).
    local MNT
    MNT="${HOME}/sbx-openclaw-${SANDBOX_NAME}"
    ensure_mount "${MNT}" || fail "mount failed — cannot write budget config into sandbox '${SANDBOX_NAME}'."

    local shadow_flag=""
    [[ -n "${REVENIUM_BUDGET_SHADOW:-}" ]] && shadow_flag="--shadow-mode"

    # REVENIUM_BUDGET_AUTONOMOUS=true → --autonomous → config.json autonomousMode=true:
    # on a rule breach guardrail-check.sh sets halted:true and the agent hard-halts.
    # Default (unset/anything else) → autonomousMode=false: breach = warn-and-ask,
    # which relies on per-turn LLM compliance to actually stop.
    local autonomous_flag=""
    [[ "${REVENIUM_BUDGET_AUTONOMOUS:-}" == "true" ]] && autonomous_flag="--autonomous"

    # setup-guardrails.sh creates the rule via the host `revenium` CLI (authenticated
    # by the exported REVENIUM_* env) and writes ruleIds to config.json under
    # OPENCLAW_HOME/skills/revenium. It self-bootstraps config.json and is idempotent
    # (refuses if ruleIds already present), so the ledger gate above is the primary guard.
    OPENCLAW_HOME="${MNT}" \
    REVENIUM_BUDGET_LABEL="${REVENIUM_BUDGET_LABEL:-${SANDBOX_NAME}}" \
    bash "${SCRIPT_DIR}/setup-guardrails.sh" \
        --hard-limit "${REVENIUM_BUDGET_LIMIT}" --period "${REVENIUM_BUDGET_PERIOD}" ${shadow_flag} ${autonomous_flag} \
        || fail "setup-guardrails.sh failed — budget rule not created. Verify REVENIUM_API_KEY and that the host 'revenium' CLI is authenticated."

    # Confirm ruleIds actually landed in the in-sandbox config.json.
    if ! grep -q '"ruleIds"' "${MNT}/skills/revenium/config.json" 2>/dev/null; then
        fail "budget rule creation reported success but ruleIds not found in sandbox config.json (${MNT}/skills/revenium/config.json)."
    fi

    ledger_set "budget-rules-created" "1"
    info "Budget guardrail rule created; ruleIds written to the sandbox config.json"
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

# deliver_revenium_cli_host — install the prebuilt CLI on the HOST PATH.
# The NemoClaw metering loop runs the unmodified report.sh / guardrail-check.sh
# ON THE HOST (over the SSHFS mount) and they call `revenium`. The in-sandbox
# delivery above does NOT put revenium on the host, so without this step the cron
# logs "revenium CLI not found on PATH — skipping metering" every tick and no
# metering data ever reaches Revenium. Mirrors deliver_revenium_cli but host-side:
# fetch the same pinned tarball, sha256-verify, install to ~/.local/bin/revenium.
# Skips (no clobber) if the operator already has revenium on PATH.
# Ledger key: cli-delivered-host (value: version:tarball-sha256).
deliver_revenium_cli_host() {
    local expected_cli_ledger="${REVENIUM_CLI_VERSION}:${REVENIUM_CLI_TARBALL_SHA256}"

    if ledger_has "cli-delivered-host"; then
        local stored
        stored=$(grep "^cli-delivered-host=" "${LEDGER_FILE}" | cut -d= -f2-)
        if [[ "${stored}" == "${expected_cli_ledger}" ]]; then
            info "revenium CLI ${REVENIUM_CLI_VERSION} already installed on host (ledger) — skipping."
            return 0
        fi
        warn "cli-delivered-host ledger entry exists but version/sha256 differs — re-installing."
    fi

    # Honor an operator-provided revenium already on PATH (standalone install or a
    # system package) — do not clobber it; the metering cron will use it as-is.
    if command -v revenium >/dev/null 2>&1; then
        info "revenium already on host PATH ($(command -v revenium)) — skipping host CLI install."
        ledger_set "cli-delivered-host" "${expected_cli_ledger}"
        return 0
    fi

    step "Installing revenium CLI ${REVENIUM_CLI_VERSION} on host (for metering cron)"

    local host_bin_dir="${HOME}/.local/bin"
    local tmpd cli_rc=0
    tmpd=$(mktemp -d "${TMPDIR:-/tmp}/revenium-host-cli.XXXXXX")
    (
        set -e
        cd "${tmpd}"
        # Pitfall 2: verify the tarball (rev.tgz), NOT the extracted binary.
        curl -fsSL -o rev.tgz "${REVENIUM_CLI_URL}"
        actual_sha=$(sha256sum rev.tgz | awk '{print $1}')
        if [ "${actual_sha}" != "${REVENIUM_CLI_TARBALL_SHA256}" ]; then
            echo "CHECKSUM_MISMATCH:${actual_sha}" >&2
            exit 2
        fi
        tar xzf rev.tgz
        mkdir -p "${host_bin_dir}"
        install -m755 ./revenium "${host_bin_dir}/revenium"
    ) || cli_rc=$?
    rm -rf "${tmpd}"

    if [[ "${cli_rc}" -eq 2 ]]; then
        fail "host revenium CLI sha256 mismatch — tarball may be tampered. Aborting install."
    elif [[ "${cli_rc}" -ne 0 ]]; then
        fail "host revenium CLI install failed (exit ${cli_rc}) — the metering cron needs 'revenium' on the host PATH."
    fi

    # The metering crontab line sets PATH=~/.local/bin:... so the cron picks this up.
    ledger_set "cli-delivered-host" "${expected_cli_ledger}"
    info "revenium CLI ${REVENIUM_CLI_VERSION} installed at ${host_bin_dir}/revenium"
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
# 3b. Per-sandbox ledger scoping (multi-sandbox correctness).
# The provisioning ledger records which steps are done. It lives on the HOST and
# survives sandbox destruction, so a single host-global ledger wrongly skips ALL
# provisioning for a second (or recreated) sandbox — leaving it with no skill,
# plugin, creds, or metering. Scope the ledger to the sandbox's stable INSTANCE
# id (the UUID from `nemoclaw <name> status`): a destroyed+recreated sandbox —
# even reusing the same name — gets a new UUID and therefore a fresh ledger, so
# it re-provisions from scratch. Fall back to the sandbox NAME if the id cannot
# be resolved (degraded but still per-sandbox). An explicit LEDGER_FILE
# (tests/operators) always wins and skips this resolution.
# ---------------------------------------------------------------------------
if [[ -z "${LEDGER_FILE}" ]]; then
    SANDBOX_UUID="$(nemoclaw "${SANDBOX_NAME}" status 2>/dev/null \
        | grep -aoiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
        | head -1 || true)"
    if [[ -n "${SANDBOX_UUID}" ]]; then
        LEDGER_FILE="${HOME}/.nemoclaw/revenium-nemoclaw-${SANDBOX_UUID}.ledger"
        info "Provisioning ledger scoped to sandbox instance ${SANDBOX_UUID}"
    else
        warn "Could not resolve sandbox instance id for '${SANDBOX_NAME}' — scoping the ledger by name. A destroy+recreate of the same name may require clearing the ledger."
        LEDGER_FILE="${HOME}/.nemoclaw/revenium-nemoclaw-${SANDBOX_NAME}.ledger"
    fi
fi
mkdir -p "$(dirname "${LEDGER_FILE}")"

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
#    Host CLI MUST precede the metering loop: the cron runs report.sh on the host
#    and needs `revenium` on the host PATH, else every tick skips metering.
# ---------------------------------------------------------------------------
deliver_revenium_cli_host
install_metering_loop
install_skill_nemoclaw         # D-08: deploy skill first (marker chain precondition)
install_enforcement_plugin     # D-05/D-09/D-10/D-11: plugin + validation gate
provision_budget_guardrails    # create budget rule + write in-sandbox config.json (env-gated)

# ---------------------------------------------------------------------------
# Success banner
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "${WORK_DONE}" -eq 1 ]]; then
    echo "  NemoClaw provisioning complete."
    echo ""
    echo "  Delivered: revenium CLI ${REVENIUM_CLI_VERSION} (sandbox + host ~/.local/bin)"
    echo "  Config:    /sandbox/.config/revenium/config.yaml"
    echo "  Probe:     meter-probe-passed"
    echo "  Plugin:    revenium-enforcement (validated)"
    echo "  Skill:     revenium (✓ ready)"
else
    echo "  NemoClaw already provisioned — no changes (idempotent re-run)."
    echo ""
    echo "  Every step was skipped via the ledger; existing state is intact."
    echo "  To re-provision (e.g. after an API-key rotation), clear the relevant"
    echo "  keys from ${LEDGER_FILE} (e.g. creds-written, meter-probe-passed)"
    echo "  before re-running — note clearing meter-probe-passed emits a new event."
    echo "  To re-install the enforcement plugin, clear: enforcement-plugin-installed"
    echo "  Skill:     revenium (deployed; ledger-gated, not re-verified this run)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
