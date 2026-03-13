# Phase 1: Skill Scaffolding - Context

**Gathered:** 2026-03-13
**Status:** Ready for planning

<domain>
## Phase Boundary

Create a valid SKILL.md at `~/.openclaw/skills/revenium/` that loads in OpenClaw when `revenium` is on PATH and is silently absent when it is not. Phase 2 adds setup flow content, Phase 3 adds guard content — this phase establishes the skeleton and metadata.

</domain>

<decisions>
## Implementation Decisions

### Skill Description
- Enforcement-focused tone: emphasize that budget checks are mandatory
- Description mentions both setup and enforcement — agent knows it handles onboarding too
- Display name in frontmatter: `revenium`

### Invocation Model
- Always-on: skill is in system prompt on every turn, agent auto-checks budget without being told
- `user-invocable: true` — `/revenium` slash command exists for setup and reconfiguration
- Auto-trigger setup on first operation when no config file exists (not on session start)
- When setup is already complete, `/revenium` shows current budget status first, then offers to reconfigure

### Instruction Skeleton
- Strong mandatory language throughout — MUST, STOP, NEVER for the budget guard
- Include scripted example prompts/messages for what the agent should say during setup and budget warnings — consistency matters
- Body will contain sections for: guard rules, setup flow, reconfiguration, and status display (Phase 2 and 3 flesh these out)

### Extra Metadata
- Version: `0.1.0` (pre-release)
- Emoji: `💰`
- Homepage: `https://docs.revenium.io/for-ai-agents`
- No OS restriction — loads anywhere `revenium` binary is available
- `requires.bins: ["revenium"]` for binary gating
- All metadata as single-line JSON to avoid silent parse failures

### Claude's Discretion
- Body section ordering (guard-first vs setup-first) — optimize for LLM compliance with the guard
- Whether to include a troubleshooting section for common issues (binary not found, API key invalid, network errors) — include if it improves agent reliability

</decisions>

<specifics>
## Specific Ideas

- Description should convey enforcement: "MUST check budget before every operation"
- The `/revenium` command should feel like a status dashboard + reconfiguration entry point
- Setup auto-triggers only when the agent is about to perform its first operation and detects no config — not proactively at session start

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- `revenium-cli` binary at project root — used for verifying CLI help output and command structure during development

### Established Patterns
- No existing OpenClaw skills on this machine (`~/.openclaw/skills/` doesn't exist yet)
- No codebase patterns to follow — greenfield skill

### Integration Points
- Skill installs to `~/.openclaw/skills/revenium/SKILL.md`
- Binary dependency: `revenium` must be on system PATH
- Config file will live at `~/.openclaw/skills/revenium/config.json` (Phase 2 concern)

</code_context>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 01-skill-scaffolding*
*Context gathered: 2026-03-13*
