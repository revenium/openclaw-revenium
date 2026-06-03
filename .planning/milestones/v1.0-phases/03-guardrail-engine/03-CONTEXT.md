# Phase 3: Guardrail Engine - Context

**Gathered:** 2026-05-31
**Status:** Ready for planning

<domain>
## Phase Boundary

Replace every piece of the legacy budget-alert enforcement stack with guardrails-native equivalents. Deliverables: `common.sh` (shared helpers), `setup-guardrails.sh` (interactive rule creation), `guardrail-check.sh` (cron enforcement stage), updated `cron.sh` (guardrail pipeline, no migration code), rewritten SKILL.md enforcement section (guardrail-status.json, ruleIds, halt logic, setup flow delegation), and updated `BUDGET-GUARD.md` workspace bootstrap content. Phase 4 adds task-type metering and subagent trace correlation — those are out of scope here.

</domain>

<decisions>
## Implementation Decisions

### Pre-execution: OpenClaw Upgrade
- **D-01:** Upgrade OpenClaw to 2026.5.28 (latest) BEFORE authoring any scripts. Current install is 2026.3.13 (2 months stale). Re-verify `openclaw message send`, `openclaw hooks`, and all CLI commands against the new version before scripting them.

### Legacy Migration
- **D-02:** No auto-migration code. Phase 3 does NOT include `--from-alert --auto` migration logic in cron.sh or setup-guardrails.sh.
- **D-03:** When `guardrail-check.sh` runs on an install with `alertId` but no `ruleIds`, it exits 0 silently (fail-open). No warning line, no cron log noise.
- **D-04:** When the user runs `/revenium` on a legacy alertId-only install (ruleIds absent or empty array), SKILL.md applies the same gate as Phase 2: treat as "setup not complete" and run the full Setup Flow. Old `alertId` is left in config.json as an orphan (not cleaned up by the skill).

### Workspace Bootstrap File
- **D-05:** Keep the filename `BUDGET-GUARD.md` — no rename. Update content only. Avoids any openclaw.json config changes.
- **D-06:** `post-install.sh` is responsible for writing/updating `BUDGET-GUARD.md` to the workspace directory and ensuring it is registered in the `bootstrap-extra-files` hook config in `~/.openclaw/openclaw.json`.
- **D-07:** BUDGET-GUARD.md content stays minimal after the Phase 3 update — one directive: "Read `~/.openclaw/skills/revenium/guardrail-status.json`. If `halted` is `true`, output the halt message from SKILL.md and stop." Full halt string template lives in SKILL.md, not duplicated here.

### Shadow Mode
- **D-08:** Shadow mode supported with full interactive prompt parity with Hermes. `setup-guardrails.sh --interactive` asks the user: "Run in shadow mode (observe-only rules)?" before creating rules. `--shadow-mode` flag also accepted for non-interactive invocations.
- **D-09:** `guardrail-check.sh` excludes shadow-mode rules from the halt decision (`halted` stays `false`) but includes them in `rules[]` with their actual `state` for dashboard visibility. Shadow transitions (first time a shadow rule enters `block` state) send a one-shot `[shadow]` notification via the same channel/target as halt notifications.

### Notifications (Halt & Shadow)
- **D-10:** Verified command form: `openclaw message send --channel X --target Y -m "MESSAGE"` (confirmed via `openclaw message send --help`). This replaces `hermes chat --toolsets messaging` from the Hermes version.
- **D-11:** Halt notification fires on transition only — when `halted` flips from `false` to `true`. Not on every cron tick while halted. Prevents notification spam.
- **D-12:** Shadow transition notification fires on first breach only (first time that shadow rule enters `block` state this period). Gated against previous `guardrail-status.json` state.

### guardrail-check.sh Specifics
- **D-13:** `ruleIds` empty or absent → skip guardrail check entirely, exit 0 (handles legacy and pre-setup states cleanly).
- **D-14:** Atomic write: `guardrail-status.json` written via temp-file-then-rename (same pattern as Hermes).
- **D-15:** Integer ruleId / string-hash ruleId mismatch: enforcement-rules API returns integer IDs; `budget-rules list` returns string-hash IDs. Join by rule `name` field to resolve (confirmed pattern from Hermes guardrail-check.sh).

### SKILL.md Rewrite
- **D-16:** HALT CHECK section changes: reads `guardrail-status.json` (not `budget-status.json`); uses `haltedRule` block for rule-specific halt message; defense-in-depth fallback (hooks are not yet confirmed for OpenClaw, so SKILL.md remains the primary enforcement gate).
- **D-17:** Setup gate changes: `ruleIds` absent or empty array → run Setup Flow. Legacy `alertId`-only config → also run Setup Flow (D-04). Note in SKILL.md that legacy `alertId` field is deprecated and ignored for the setup gate.
- **D-18:** Setup Flow delegates to `setup-guardrails.sh --interactive`. SKILL.md does NOT prompt the user for budget details itself. The script owns the entire interaction and config write. Same exit-code contract as Hermes SKILL.md (exit 0 + "Created N rule(s)..." → success; exit 0 + "Cancelled." → user cancelled; non-zero → failure).
- **D-19:** `/revenium` command shows `ruleIds` from config.json and per-rule state from `guardrail-status.json`. Offers: `reconfigure` (runs `setup-guardrails.sh --interactive` again) or `done`.

### cron.sh Update
- **D-20:** cron.sh pipeline after Phase 3: `report.sh` (metering, unchanged) → `guardrail-check.sh` (replaces budget-check.sh). `budget-check.sh` is deleted.
- **D-21:** No migration stage in cron.sh (D-02). If someone has a legacy alertId-only config, guardrail-check.sh exits 0 silently.

### common.sh
- **D-22:** `common.sh` contains: path constants (`STATE_DIR`, `CONFIG_FILE`, `GUARDRAIL_STATUS_FILE`, `LOCK_FILE`, `LOG_FILE`), `ensure_path()`, `log()`/`info()`/`warn()`/`error()`, `has_guardrails_cli()` probe, `REVENIUM_AGENT_NAME` default.
- **D-23:** `REVENIUM_AGENT_NAME` defaults to `"OpenClaw"` (not `"Hermes"`). This is the agent name passed to `--filter AGENT:IS:OpenClaw` in `setup-guardrails.sh` and to `--agent` in `report.sh` (Phase 4 concern, but common.sh establishes the constant).

### Claude's Discretion
- Exact warn threshold computation (Hermes uses 80% of hard limit — same is fine)
- Rule naming convention (Hermes uses "Hermes {Period} Budget" → use "OpenClaw {Period} Budget")
- Log verbosity level for cron operations
- Whether to include `uninstall-hooks.sh` equivalent (hooks not yet confirmed for OpenClaw)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Source of truth — Hermes skill to port from
- `../hermes-revenium/skills/revenium/scripts/setup-guardrails.sh` — canonical setup-guardrails implementation; port with Hermes→OpenClaw substitutions
- `../hermes-revenium/skills/revenium/scripts/guardrail-check.sh` — canonical guardrail-check implementation; port with path and notification command substitutions
- `../hermes-revenium/skills/revenium/scripts/common.sh` — canonical common helpers; adapt HERMES_HOME/~/.hermes paths to OPENCLAW_HOME/~/.openclaw
- `../hermes-revenium/skills/revenium/SKILL.md` — canonical SKILL.md structure for guardrail enforcement sections

### Current OpenClaw skill (being replaced)
- `SKILL.md` — current skill file; the rewrite target
- `scripts/budget-check.sh` — being replaced by guardrail-check.sh; delete after Phase 3
- `scripts/cron.sh` — updated (remove budget-check.sh, add guardrail-check.sh, remove migration stage)
- `scripts/post-install.sh` — updated to write BUDGET-GUARD.md with new guardrail content
- `scripts/report.sh` — unchanged in Phase 3

### OpenClaw extension model
- `~/.openclaw/openclaw.json` — live config; `hooks.internal.entries.bootstrap-extra-files.files` controls workspace injection
- `~/.openclaw/workspace/BUDGET-GUARD.md` — content to be updated by post-install.sh

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/report.sh` — complete metering reporter; unchanged in Phase 3, feeds into Phase 4
- `scripts/install-cron.sh` — cron installer; unchanged (cron entry command stays the same)
- `scripts/uninstall-cron.sh` — cron uninstaller; unchanged
- `scripts/clear-halt.sh` — halt clear script; needs content update (clears guardrail-status.json halt, not budget-status.json)

### Established Patterns
- All scripts use `set -euo pipefail` + explicit PATH extension (brew prefix detection)
- Python3 used for all JSON manipulation (no jq dependency on the enforcement path)
- Atomic writes: temp-file-then-rename (established in budget-check.sh, required in guardrail-check.sh)
- Flock-based concurrency guard (budget-check.sh acquires cron.lock; cron.sh manages the outer lock)
- Fail-open posture: every cron-path failure logs warn and exits 0

### Integration Points
- `~/.openclaw/skills/revenium/config.json` — Phase 2 wrote `alertId`; Phase 3 writes `ruleIds` array
- `~/.openclaw/skills/revenium/guardrail-status.json` — new file written by guardrail-check.sh; read by SKILL.md and BUDGET-GUARD.md
- `openclaw.json` `bootstrap-extra-files` — already configured; `post-install.sh` updates content only

</code_context>

<specifics>
## Specific Ideas

- Rule naming: "OpenClaw {Period} Budget" (e.g., "OpenClaw Daily Budget") — mirrors Phase 2 alert naming convention
- Agent name constant: `REVENIUM_AGENT_NAME="OpenClaw"` in common.sh — used for `--filter AGENT:IS:OpenClaw` in rule creation and for Phase 4 `--agent` flag
- Halt message format (from Hermes, adapted): "Guardrail halt active — rule '{name}' ({metricType}, {windowType}) at {currentValue} of {hardLimit} hard-limit. To resume: `bash ~/.openclaw/skills/revenium/scripts/clear-halt.sh`"
- `clear-halt.sh` update: write `{"halted": false}` merge into `guardrail-status.json` (not `budget-status.json`)
- OpenClaw version: upgrade to 2026.5.28 before any script work; re-verify all CLI commands

</specifics>

<deferred>
## Deferred Ideas

- Structural hook enforcement (`pre_llm_call` / `pre_tool_call` equivalent) — requires research into whether OpenClaw supports agent lifecycle hooks beyond `agent:bootstrap`. If supported, this is Phase 4 or a Phase 3.5 insertion.
- Task-type metering and per-task-type guardrail rules — Phase 4
- Subagent trace correlation (root session ID walk) — Phase 4
- `hooks-status.sh` equivalent for OpenClaw — deferred until hooks research is complete

</deferred>

---

*Phase: 03-guardrail-engine*
*Context gathered: 2026-05-31*
