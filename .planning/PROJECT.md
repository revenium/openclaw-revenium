# Revenium OpenClaw Skill

## What This Is

A global OpenClaw skill that uses the `revenium` CLI to **enforce token-budget guardrails** and **meter agent usage** for every OpenClaw agent on the machine. It provides agent-guided setup (API key, guardrail budget rules), a hard enforcement loop (a cron stage polls guardrail state and the agent halts or warn-and-asks when a rule blocks), and per-completion metering that attributes spend by **root session** (`--agent openclaw-<root_session_id>`) and **task type** (an 8-label taxonomy classified before each substantive turn).

## Core Value

Agents never silently blow through token budgets — every turn is guardrail-checked and the user retains control over continuing past a threshold — **and** every completion is metered and attributed (by root session + task type) so spend is observable in Revenium.

## Requirements

### Validated

- ✓ Skill loads in OpenClaw with valid single-line JSON metadata and is gated on the `revenium` binary via `requires.bins` — v1.0 (Phase 1, SKAF-01..04)
- ✓ Agent-guided first-time setup: API key config + budget rule creation + idempotent re-run — v1.0 (Phase 2, SETUP-01..08)
- ✓ Guardrails-native enforcement: `setup-guardrails.sh` creates `budget-rules`, `guardrail-check.sh` polls enforcement state and writes `guardrail-status.json` atomically each cron tick — v1.0 (Phase 3, GUARD-01..06)
- ✓ Halt + warn-and-ask flow: SKILL.md reads `guardrail-status.json`/`haltedRule`; blocking rules in autonomous mode emit the verbatim halt string; warned rules trigger warn-and-ask — v1.0 (Phase 3)
- ✓ Task-type metering: 8-label `task-taxonomy.json`, mandatory TASK CLASSIFICATION directive, `--task-type` on every `meter completion` (default `unclassified`) — v1.0 (Phase 4, METER-01..03)
- ✓ Root-session attribution: `report.sh` resolves the root session and passes `--agent "openclaw-<root_session_id>"`; budget rules scope via `AGENT:STARTS_WITH:openclaw-` (D-07) — v1.0 (Phase 4, TRACE-01..02)
- ✓ Optional per-task-type budget rules offered by `setup-guardrails.sh --interactive` — v1.0 (Phase 4)

### Active

(None — v1.0 shipped. Next milestone requirements defined via `/gsd-new-milestone`.)

### Out of Scope

- **Agentic Job tracking** (`--agentic-job-id`/`-name`/`-type`, `job-taxonomy.json`, `kind:"job"` markers) — richer than per-session `--agent` rollup; deliberately deferred from v1.0, candidate for a future milestone
- Code-side classifier *plugin* + OpenClaw `pre_llm_call`/`pre_tool_call` hooks — agent-driven marker write is used instead (native hook events unconfirmed)
- Tool-event reporting (`meter tool-event`)
- Mobile/desktop companion app — CLI/agent-level skill only
- Multi-agent budget splitting — single shared budget per machine; rollup is per root session
- Token counting/estimation — Revenium platform handles actual metering
- Bundling the `revenium` binary — user installs it to PATH themselves

## Context

- **Shipped v1.0** (2026-06-03): 4 phases, 14 plans, 26 tasks, ~81-day calendar span, 107 feat/fix/docs commits. ~39 automated tests (bash + python) across `tests/`.
- **Tech stack:** bash scripts + a small Python sidecar (`get-root-session-id.py`), JSON config/taxonomy, markdown agent instructions (SKILL.md). No build system; `set -euo pipefail` discipline; atomic writes via `tempfile.mkstemp` + `os.replace`.
- **`revenium` CLI:** config at `~/.config/revenium/config.yaml`; env overrides `REVENIUM_API_KEY`/`REVENIUM_TEAM_ID`/`REVENIUM_API_URL`. Key commands used: `config show`, `guardrails budget-rules {create,list,get,update}`, `guardrails enforcement-rules get`, `meter completion` (with `--task-type`/`--agent`).
- **OpenClaw integration:** skill installed at `~/.openclaw/skills/revenium/`; sessions at `~/.openclaw/agents/main/sessions/*.jsonl`; cron (`cron.sh`) runs `report.sh` + `guardrail-check.sh` every minute; markers at `~/.openclaw/skills/revenium/markers/{sid}.jsonl`.
- **Known caveats at ship (see STATE.md → Deferred Items):** in-skill D-08 legacy-filter notice firing not independently verified (the rule was reconfigured directly); subagent→root spend rollup verified at the resolver/unit level but not end-to-end with live subagents.

## Constraints

- **Binary dependency:** `revenium` must be on PATH — skill won't load without it (`requires.bins`)
- **API key required:** must be configured before any CLI commands work
- **Single-process pipeline:** metering/enforcement run as cron stages; no daemon
- **OpenClaw skill format:** YAML/JSON frontmatter + markdown body
- **Network latency:** guardrail polling and metering are network round-trips to the Revenium API

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Global install (~/.openclaw/skills/) | Available to all agents on the machine, not project-specific | ✓ Good |
| Expect `revenium` on PATH | Simpler distribution; user manages their own binary | ✓ Good |
| Single-line JSON metadata in SKILL.md | OpenClaw silently drops multi-line/colon-space metadata | ✓ Good (Phase 1) |
| Guard-first body ordering in SKILL.md | Maximize LLM instruction compliance | ✓ Good (Phase 1) |
| Guardrails-native enforcement (replace alert model) | First-class `budget-rules` + enforcement state vs legacy `alerts budget` polling | ✓ Good — superseded the original anomaly-ID/alert design (Phase 3) |
| No auto-migration of legacy installs | Legacy alertId-only installs treated as "setup not complete" | ✓ Good (Phase 3, D-02) |
| Atomic status writes (mkstemp + os.replace) | Prevent torn reads of guardrail-status.json | ✓ Good (Phase 3) |
| `AGENT:STARTS_WITH:openclaw-` attribution (D-07) | Per-root-session rollup; supersedes static `AGENT:IS:OpenClaw` | ✓ Good (Phase 4) |
| Agent-driven marker write (not native hooks) | OpenClaw `pre_llm_call` hook events unconfirmed | ⚠️ Revisit — markers land after the turn's completion; correlation reworked to completion_id keying |
| Task-type correlation by `completion_id` + marker-after fallback | Timestamp-precedence (marker before completion) never matched in practice | ✓ Good (post-Phase-4 debug fix) |
| Defer Agentic Job tracking to a future milestone | Per-session `--agent` rollup sufficient for v1.0 | — Pending (future milestone) |

---
*Last updated: 2026-06-03 after v1.0 milestone*
