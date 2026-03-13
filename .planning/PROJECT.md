# Revenium OpenClaw Skill

## What This Is

A global OpenClaw skill that uses the `revenium-cli` to track and enforce token usage budgets for OpenClaw agents. It provides setup automation (API key config, budget alert creation) and a hard guardrail: the agent must check its budget status before every operation, warning the user and asking for permission to continue if the budget is exceeded.

## Core Value

Agents never silently blow through token budgets — every operation is budget-checked, and the user always has control over whether to continue past a budget threshold.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Skill asks the developer for their Revenium API key during first-time setup
- [ ] Skill configures `revenium-cli` with the provided API key via `revenium config set key`
- [ ] Skill asks the developer for their token budget amount
- [ ] Skill asks the developer for their budget period (DAILY, WEEKLY, MONTHLY, QUARTERLY)
- [ ] Skill auto-creates the budget alert via `revenium alerts budget create`
- [ ] Agent checks budget status via `revenium alerts budget get` before every operation
- [ ] When budget is exceeded, agent warns the user and asks for permission to continue
- [ ] When budget is not exceeded, agent proceeds silently
- [ ] Skill is installed globally at `~/.openclaw/skills/revenium/`
- [ ] Skill expects `revenium` binary to be available on the system PATH
- [ ] Skill stores the budget alert anomaly ID for subsequent budget checks
- [ ] SKILL.md follows OpenClaw skill format (YAML frontmatter + markdown instructions)

### Out of Scope

- Mobile/desktop companion app integration — this is a CLI/agent-level skill only
- Custom notification webhooks — Revenium's built-in email notifications are sufficient
- Multi-agent budget splitting — single shared budget per machine
- Token counting/estimation — Revenium platform handles the actual metering
- Bundling the revenium-cli binary — user installs it to PATH themselves

## Context

- **revenium-cli** is a Go binary that wraps the Revenium API. Key commands: `config set key`, `alerts budget create`, `alerts budget get`, `alerts budget list`.
- **OpenClaw skills** are directories containing a `SKILL.md` with YAML frontmatter (name, description, metadata with requires/env/bins) and markdown instructions.
- Skills are discovered from `~/.openclaw/skills/` and injected into the agent's system prompt.
- The `metadata.openclaw.requires.bins` field gates skill loading on binary availability.
- The `metadata.openclaw.requires.env` field can gate on environment variables.
- Budget alerts use the `--threshold` flag for the amount and `--period` for the cadence.
- `alerts budget get <anomaly-id>` returns current spend vs threshold — this is the check mechanism.
- The anomaly ID returned from `alerts budget create` must be persisted for subsequent checks.

## Constraints

- **Binary dependency**: `revenium` must be on PATH — skill won't load without it (enforced via `requires.bins`)
- **API key required**: Revenium API key must be configured before any CLI commands work
- **Single SKILL.md**: All skill logic lives in one markdown file — no separate code files
- **OpenClaw skill format**: Must follow YAML frontmatter + markdown body convention
- **Budget check latency**: Each `alerts budget get` call is a network round-trip to Revenium API

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Global install (~/.openclaw/skills/) | Available to all agents on the machine, not project-specific | — Pending |
| Expect `revenium` on PATH | Simpler distribution, user manages their own binary | — Pending |
| Auto-create budget via CLI | Reduces friction — skill handles setup end-to-end | — Pending |
| Warn-and-ask on budget exceeded | User retains control but gets clear visibility | — Pending |
| Configurable budget period | Developers have different billing/tracking cadences | — Pending |
| Store anomaly ID in config | Needed to check budget status on subsequent operations | — Pending |

---
*Last updated: 2026-03-13 after initialization*
