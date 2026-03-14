# Phase 2: Setup Flow - Context

**Gathered:** 2026-03-14
**Status:** Ready for planning

<domain>
## Phase Boundary

Agent-guided first-time configuration: collect API key + budget preferences, create budget alert via `revenium alerts budget create`, persist anomaly ID. Includes idempotent re-run and reconfiguration via `/revenium`. Does NOT include the budget check guard (Phase 3) or grace mode (Phase 3).

</domain>

<decisions>
## Implementation Decisions

### Setup Conversation
- Agent collects API key, budget amount, and period — Claude decides whether step-by-step or all-at-once based on what minimizes friction
- No API key validation step — trust the user, errors surface naturally during budget creation
- Budget alert name is auto-generated (e.g., "OpenClaw Daily Budget") based on the selected period — user is not asked to name it
- Post-setup confirmation verbosity at Claude's discretion

### Config Persistence
- Config file location: `~/.openclaw/skills/revenium/config.json` (co-located with SKILL.md)
- Config stores anomaly ID only — API key lives in revenium's own config (`revenium config set key`), budget details queryable via CLI
- Config file should be human-readable (pretty-printed JSON)
- Grace mode setting will be added to config.json in Phase 3 (not this phase)

### Idempotency & Reconfiguration
- When existing config.json with anomaly ID detected: offer to reconfigure ("Budget already configured. Want to update it?")
- On reconfigure: delete the old budget alert from Revenium (`revenium alerts budget delete`), then create new one — clean up, don't leave orphans
- Granularity of reconfiguration at Claude's discretion (full redo vs selective changes)

### Error Handling
- If API key is invalid / budget creation fails: report error, tell user to run `/revenium` when ready, and stop — no retries
- Atomic setup: only write config.json after ALL steps succeed — no partial state
- If setup hasn't completed (no config.json): behavior at Claude's discretion (refuse to work vs warn-and-work — should align with enforcement philosophy from Core Value)

### Claude's Discretion
- Step-by-step vs all-at-once setup conversation flow
- Post-setup confirmation verbosity
- Granular vs full-redo reconfiguration
- Whether to refuse operations or warn when setup incomplete

</decisions>

<specifics>
## Specific Ideas

- Budget alert name format: "OpenClaw {Period} Budget" (e.g., "OpenClaw Daily Budget")
- CLI commands involved: `revenium config set key <key>`, `revenium alerts budget create --name <name> --threshold <amount> --period <period> --json`, `revenium alerts budget delete <anomaly-id>`
- The `--json` flag on `alerts budget create` should be used to reliably parse the anomaly ID from the response
- Setup auto-triggers on first operation when no config.json exists (decided in Phase 1)
- `/revenium` shows status + offers reconfigure when setup is complete (decided in Phase 1)

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- SKILL.md exists with skeleton sections (## Setup, ## `/revenium` Command) ready to be filled
- `revenium-cli` binary verified: `alerts budget create` supports `--name`, `--threshold`, `--period`, `--currency`, `--notify`, `--json` flags
- `revenium alerts budget delete` exists for cleanup during reconfiguration

### Established Patterns
- SKILL.md uses guard-first body ordering — Setup section comes after Operation Guard
- Strong mandatory language (MUST/STOP/NEVER) established in Phase 1
- Scripted example prompts for consistency (Phase 1 decision)

### Integration Points
- SKILL.md `## Setup` section — placeholder to be filled with setup flow instructions
- SKILL.md `## /revenium Command` section — placeholder to be filled with status + reconfigure behavior
- `~/.openclaw/skills/revenium/config.json` — new file created by setup, read by Phase 3 guard
- `revenium config set key` — configures the CLI's own credential store (separate from skill config)

</code_context>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 02-setup-flow*
*Context gathered: 2026-03-14*
