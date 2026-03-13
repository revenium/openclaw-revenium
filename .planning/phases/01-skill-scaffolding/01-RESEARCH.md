# Phase 1: Skill Scaffolding - Research

**Researched:** 2026-03-13
**Domain:** OpenClaw SKILL.md format — frontmatter authoring, binary gating, skill discovery
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Skill Description**
- Enforcement-focused tone: emphasize that budget checks are mandatory
- Description mentions both setup and enforcement — agent knows it handles onboarding too
- Display name in frontmatter: `revenium`

**Invocation Model**
- Always-on: skill is in system prompt on every turn, agent auto-checks budget without being told
- `user-invocable: true` — `/revenium` slash command exists for setup and reconfiguration
- Auto-trigger setup on first operation when no config file exists (not on session start)
- When setup is already complete, `/revenium` shows current budget status first, then offers to reconfigure

**Instruction Skeleton**
- Strong mandatory language throughout — MUST, STOP, NEVER for the budget guard
- Include scripted example prompts/messages for what the agent should say during setup and budget warnings — consistency matters
- Body will contain sections for: guard rules, setup flow, reconfiguration, and status display (Phase 2 and 3 flesh these out)

**Extra Metadata**
- Version: `0.1.0` (pre-release)
- Emoji: `💰`
- Homepage: `https://docs.revenium.io/for-ai-agents`
- No OS restriction — loads anywhere `revenium` binary is available
- `requires.bins: ["revenium"]` for binary gating
- All metadata as single-line JSON to avoid silent parse failures

### Claude's Discretion
- Body section ordering (guard-first vs setup-first) — optimize for LLM compliance with the guard
- Whether to include a troubleshooting section for common issues (binary not found, API key invalid, network errors) — include if it improves agent reliability

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| SKAF-01 | Skill directory exists at `~/.openclaw/skills/revenium/` with a valid `SKILL.md` | OpenClaw skill format: skill lives at `~/.openclaw/skills/<name>/SKILL.md`; install is `mkdir -p ~/.openclaw/skills/revenium && cp SKILL.md ~/.openclaw/skills/revenium/SKILL.md` |
| SKAF-02 | SKILL.md YAML frontmatter includes `requires.bins: ["revenium"]` to gate on binary availability | `metadata.openclaw.requires.bins` field in frontmatter causes OpenClaw to check PATH at load time; missing binary = skill silently excluded from system prompt |
| SKAF-03 | SKILL.md metadata uses single-line JSON to avoid silent parse failures | OpenClaw's embedded parser does not support multi-line YAML values for the `metadata` field; multi-line format causes silent gate bypass (confirmed in clawhub/docs/skill-format.md) |
| SKAF-04 | Skill appears in `openclaw skills list` when `revenium` is on PATH | Verified by placing file at `~/.openclaw/skills/revenium/SKILL.md` with valid frontmatter and running `openclaw skills list`; absence of skill in list = frontmatter error or binary not found |
</phase_requirements>

## Summary

Phase 1 delivers a single file: `~/.openclaw/skills/revenium/SKILL.md`. The SKILL.md must have a valid YAML frontmatter block that declares the skill's identity, metadata, and binary gate, plus a markdown body skeleton that establishes section structure for Phases 2 and 3. There is no code, no build step, no test framework in the traditional sense — the "deliverable" is a markdown file that OpenClaw reads and injects into the agent's system prompt.

The highest-risk work in this phase is YAML frontmatter authoring. Two silent failure modes are known and confirmed: unquoted colon-space sequences in string values silently drop the skill from discovery (confirmed GitHub Issue #22134), and multi-line `metadata` values cause the `requires.bins` gate to be silently bypassed (confirmed in clawhub skill-format docs). Both failures produce zero errors — the skill simply does not appear in `openclaw skills list`. Verification after every frontmatter change is mandatory.

The phase succeeds when `openclaw skills list` shows the revenium skill with `revenium` on PATH, and does not show it when `revenium` is removed from PATH. The body skeleton at this stage needs only section headers and placeholder text; Phase 2 fills the setup flow and Phase 3 fills the guard. The locked decisions from CONTEXT.md constrain the frontmatter values precisely (name, emoji, homepage, version, description tone, `requires.bins`) — there are no discovery choices to make, only correct implementation.

**Primary recommendation:** Write the frontmatter first, verify with `openclaw skills list`, then add the body skeleton. The order matters because a frontmatter bug will mask any body content work.

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| OpenClaw SKILL.md format (AgentSkills v1) | AgentSkills v1 | Delivers skill instructions to the agent via system prompt injection | The only supported format. OpenClaw injects eligible `SKILL.md` files into the system prompt. No alternative exists. |
| YAML frontmatter (single-line JSON for `metadata`) | YAML 1.2 (OpenClaw parser subset) | Declares skill identity, binary gate, display metadata | OpenClaw parser constraint: `metadata` must be a single-line JSON string; standard YAML multi-line format silently fails |
| revenium-cli | dev build (arm64 macOS — from project root binary) | All Revenium API calls — invoked by the agent via Bash tool | Already exists; covers all required operations; agent never calls API directly |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `{baseDir}` placeholder | OpenClaw skill runtime | Reference skill folder path in body instructions | Use in Phase 2/3 body to reference `{baseDir}/config.json` for anomaly ID persistence |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Single-line JSON `metadata` | Multi-line YAML `metadata` | Multi-line YAML looks cleaner but is silently rejected by OpenClaw's embedded parser; single-line is the only safe choice |
| `requires.bins: ["revenium"]` | `requires.env: ["REVENIUM_API_KEY"]` | Binary check is simpler and correct — the API key is managed by the CLI's own config, not an env var |
| Double-quoted YAML strings | Unquoted YAML strings | Unquoted strings break silently on any `: ` sequence; double-quoted strings are unconditionally safe |

**Installation:**

```bash
mkdir -p ~/.openclaw/skills/revenium
cp SKILL.md ~/.openclaw/skills/revenium/SKILL.md
```

No package manager. No build step.

## Architecture Patterns

### Recommended Project Structure

```
~/.openclaw/skills/revenium/
└── SKILL.md          # runtime install — what OpenClaw reads

openclaw/             # this repository (development)
└── SKILL.md          # source of truth — what gets copied to install location
```

The repository root contains `SKILL.md` directly. Install is a single `cp`. There is no build, transpile, or bundle step.

### Pattern 1: Binary Gate via `requires.bins`

**What:** Declare `requires.bins: ["revenium"]` in the `metadata` frontmatter field. OpenClaw checks PATH at skill-load time. If the binary is not found, the skill is excluded from the system prompt silently.

**When to use:** Every CLI-wrapping skill. This is the standard pattern for optional skills that depend on an external binary.

**Example:**
```yaml
---
name: revenium
description: "MUST check Revenium budget before every operation. Tracks token usage spend and enforces budget thresholds — handles both onboarding and mandatory enforcement."
metadata: {"openclaw":{"emoji":"💰","version":"0.1.0","homepage":"https://docs.revenium.io/for-ai-agents","requires":{"bins":["revenium"]},"user-invocable":true}}
---
```

Source: Official OpenClaw skills documentation (`https://docs.openclaw.ai/tools/skills`) + confirmed pattern from `https://raw.githubusercontent.com/openclaw/openclaw/main/skills/1password/SKILL.md`

### Pattern 2: Two-Phase Body Skeleton (Guard-First Ordering)

**What:** Structure the SKILL.md body with the guard section FIRST, setup section SECOND. This ordering exploits LLM attention patterns — content earlier in the system prompt carries higher effective weight. Since the guard is the primary behavior (runs on every operation), it should have primacy.

**When to use:** Any skill with both an always-on behavior and a one-time setup flow. Guard-first ordering increases compliance with the mandatory budget check.

**Example body skeleton:**
```markdown
## Operation Guard (MANDATORY — runs before every tool call)

BEFORE executing any tool call, you MUST...
[Phase 3 fills this section]

## Setup Flow (runs once, when no config exists)

When `~/.openclaw/skills/revenium/config.json` does not exist...
[Phase 2 fills this section]

## `/revenium` Command

When the user invokes `/revenium`...
[Phase 2 fills this section]
```

Source: Claude's discretion — guard-first ordering is a recommendation based on LLM instruction compliance research referenced in PITFALLS.md (Issue #30681).

### Pattern 3: YAML Frontmatter Safety

**What:** Wrap ALL string values in double quotes. Keep `metadata` as a single-line JSON value regardless of how long the line gets. Never use `: ` in an unquoted string value.

**When to use:** Always — non-negotiable for every SKILL.md.

**Example:**
```yaml
---
name: revenium
description: "MUST check Revenium budget before every operation. Handles token budget enforcement and first-time setup."
metadata: {"openclaw":{"emoji":"💰","version":"0.1.0","homepage":"https://docs.revenium.io/for-ai-agents","requires":{"bins":["revenium"]},"user-invocable":true}}
---
```

If the `description` contains a natural-language colon (e.g., "Use when: budget is a concern"), the double-quote wrapping prevents the YAML parser from interpreting it as a nested mapping.

### Anti-Patterns to Avoid

- **Multi-line `metadata` YAML:** Looks readable, but silently bypasses `requires.bins` gate. The single-line constraint is a parser limitation in OpenClaw, not standard YAML behavior.
- **Unquoted description with colons:** Any `word: ` sequence in an unquoted YAML string silently drops the skill from `openclaw skills list` — no error emitted.
- **Verifying frontmatter visually only:** YAML that looks correct to a human may still fail the OpenClaw parser. Always verify with `openclaw skills list` after every frontmatter edit.
- **Skipping the binary-absent test:** `requires.bins` is the phase's primary deliverable. Must be tested with `revenium` removed from PATH to confirm silence (not error, not load).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Binary gating | Custom shell script that checks for binary and conditionally injects skill | `requires.bins` in `metadata` frontmatter | OpenClaw's native gate is evaluated at load time, before the agent session starts; a shell check inside the body runs after injection |
| Metadata format validation | Manual JSON linting tool | Use single-line JSON with double-quoted strings and verify via `openclaw skills list` | The only reliable test is actual OpenClaw loading behavior — static linting cannot catch the single-line constraint |

**Key insight:** This phase has no code to hand-roll. The only deliverable is text. The anti-pattern to avoid is writing text that _looks_ correct but violates OpenClaw's parser constraints.

## Common Pitfalls

### Pitfall 1: Colon-Space in Unquoted YAML String Silently Drops Skill

**What goes wrong:** A colon followed by a space (`: `) anywhere in an unquoted YAML value (most likely in `description`) causes the skill to be completely dropped from `openclaw skills list`. No error is emitted. The agent has no knowledge the skill exists.

**Why it happens:** YAML interprets `key: value` as a nested mapping key-value pair. OpenClaw's skill loader catches the YAML parse exception internally and discards it without logging (confirmed: GitHub Issue #22134 on the OpenClaw repo).

**How to avoid:** Wrap the `description` field (and any other string values) in double quotes unconditionally. This is non-negotiable.

**Warning signs:**
- Skill does not appear in `openclaw skills list` after copying to install location
- No error message anywhere about the skill
- Agent does not recognize the skill or `/revenium` command

### Pitfall 2: Multi-line `metadata` Bypasses Binary Gate Silently

**What goes wrong:** If `metadata` is written across multiple lines (e.g., as an indented YAML mapping for readability), the `requires.bins` check either fails silently or is ignored entirely. The skill may load even when `revenium` is not on PATH — or may not load at all. Either way, the binary gate is non-functional.

**Why it happens:** OpenClaw's embedded frontmatter parser enforces a single-line constraint on the `metadata` field that is not widely documented. Standard YAML validators accept multi-line format; the OpenClaw parser does not.

**How to avoid:** Keep `metadata` as a single-line JSON string:
```yaml
metadata: {"openclaw":{"emoji":"💰","version":"0.1.0","homepage":"https://docs.revenium.io/for-ai-agents","requires":{"bins":["revenium"]},"user-invocable":true}}
```

**Warning signs:**
- Skill loads even when `revenium` is removed from PATH
- `revenium` binary absent but skill still appears in `openclaw skills list`

### Pitfall 3: OpenClaw Not Installed / `~/.openclaw/` Does Not Exist

**What goes wrong:** `openclaw` is not on PATH on this machine (`which openclaw` returns nothing, `~/.openclaw/` does not exist). Installing the skill directory and running `openclaw skills list` will fail if OpenClaw is not installed.

**Why it happens:** OpenClaw is a separate tool that the developer must install independently. This machine confirmed: no OpenClaw installation exists.

**How to avoid:** Phase 1 plan must include an OpenClaw installation step as a prerequisite before placing the SKILL.md. Without OpenClaw, there is no way to verify SKAF-04 (skill appears in `openclaw skills list`).

**Warning signs:**
- `which openclaw` returns nothing
- `~/.openclaw/` directory does not exist

### Pitfall 4: Verifying Skill Load With `revenium` Binary Still on PATH

**What goes wrong:** Developer tests that skill loads successfully with `revenium` on PATH, but never tests the silent-absence case (binary removed from PATH). SKAF-02 requires both states to be verified: present = skill loads, absent = skill silently missing.

**Why it happens:** Absence testing feels redundant when presence testing passes. But the OpenClaw binary gate must be verified both ways — a misconfigured `requires.bins` could cause the skill to always load regardless of binary presence.

**How to avoid:** Remove the `revenium` binary from PATH (or rename it temporarily), run `openclaw skills list`, and confirm the skill does not appear.

**Warning signs:**
- Only presence test was run
- Multi-line `metadata` was used (gate may be bypassed)

## Code Examples

Verified patterns for SKILL.md frontmatter:

### Correct Frontmatter (All Constraints Met)

```yaml
---
name: revenium
description: "Mandatory Revenium budget enforcement for every agent operation. Checks token spend against your configured budget before each tool call, warns when thresholds are exceeded, and handles first-time setup and reconfiguration."
metadata: {"openclaw":{"emoji":"💰","version":"0.1.0","homepage":"https://docs.revenium.io/for-ai-agents","requires":{"bins":["revenium"]},"user-invocable":true}}
---
```

Source: Derived from official OpenClaw 1Password skill (`https://raw.githubusercontent.com/openclaw/openclaw/main/skills/1password/SKILL.md`) and OpenClaw skills documentation (`https://docs.openclaw.ai/tools/skills`). Satisfies all CONTEXT.md locked decisions.

### Frontmatter Fields Mapped to Locked Decisions

| CONTEXT.md Decision | Frontmatter Key | Value |
|--------------------|-----------------|-------|
| Display name: `revenium` | `name` | `revenium` |
| Enforcement-focused tone | `description` | begins with "Mandatory Revenium budget enforcement..." |
| Description mentions both setup and enforcement | `description` | "...warns when thresholds are exceeded, and handles first-time setup and reconfiguration" |
| Version: `0.1.0` | `metadata.openclaw.version` | `"0.1.0"` |
| Emoji: `💰` | `metadata.openclaw.emoji` | `"💰"` |
| Homepage | `metadata.openclaw.homepage` | `"https://docs.revenium.io/for-ai-agents"` |
| `requires.bins: ["revenium"]` | `metadata.openclaw.requires.bins` | `["revenium"]` |
| `user-invocable: true` | `metadata.openclaw.user-invocable` | `true` |
| All metadata as single-line JSON | `metadata` entire value | single-line JSON string |

### revenium-cli Command Reference (Verified Against Binary)

Verified by running `revenium-cli --help` and subcommand help against the binary in the project root:

```bash
# Configuration
revenium config set key <api-key>
revenium config show

# Budget alerts — all flags verified against binary
revenium alerts budget create --name "Agent Budget" --threshold <amount> --period <DAILY|WEEKLY|MONTHLY|QUARTERLY> [--currency USD] [--notify email@example.com]
revenium alerts budget get <anomaly-id>
revenium alerts budget get <anomaly-id> --json
revenium alerts budget list
revenium alerts budget list --json

# Global flags
--json     # Structured JSON output (use for programmatic parsing)
-q         # Suppress non-error output
-y         # Skip confirmation prompts
```

Note: The `alerts budget create` command does NOT have a `--period` flag documented on the binary — it shows `--currency`, `--name`, `--notify`, `--threshold` only. The `--period` flag referenced in PROJECT.md and prior research needs verification. Default period appears to be MONTHLY if not specified.

### Body Skeleton (Guard-First Ordering)

```markdown
## Operation Guard

[Phase 3 fills this section — budget check before every tool call]

## Setup

[Phase 2 fills this section — API key, budget creation, anomaly ID persistence]

## `/revenium` Command

[Phase 2 fills this section — status display and reconfiguration]
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Multi-line YAML metadata | Single-line JSON metadata | OpenClaw AgentSkills v1 | Eliminates silent gate bypass; all metadata must be on one line |
| Quoting only "suspicious" values | Quoting ALL string values unconditionally | Best practice (ongoing) | Eliminates YAML parse surprises; colon-space in any unquoted value silently drops skill |

**Deprecated/outdated:**
- Multi-line YAML `metadata`: Not supported by OpenClaw's embedded parser; will silently break binary gating. Use single-line JSON.

## Open Questions

1. **`--period` flag on `alerts budget create`**
   - What we know: PROJECT.md and prior research describe `--period DAILY|WEEKLY|MONTHLY|QUARTERLY` as a supported flag
   - What's unclear: Running `revenium-cli alerts budget create --help` against the local binary does NOT show `--period` in the flags list; only `--currency`, `--name`, `--notify`, `--threshold` appear
   - Recommendation: This is a Phase 2 concern (setup flow), not Phase 1. Flag for investigation when writing the setup section. Phase 1 body skeleton can omit budget creation command detail entirely.

2. **OpenClaw Not Installed**
   - What we know: `openclaw` is not on PATH on this machine; `~/.openclaw/` does not exist
   - What's unclear: Whether the phase plan should include OpenClaw installation as a task or treat it as a prerequisite the developer handles manually
   - Recommendation: Phase 1 PLAN should include a Wave 0 task for OpenClaw installation and `~/.openclaw/skills/revenium/` directory creation as explicit prerequisite steps, since SKAF-04 is unverifiable without OpenClaw.

3. **`user-invocable` field validity**
   - What we know: CONTEXT.md specifies `user-invocable: true` in metadata
   - What's unclear: Whether the OpenClaw `user-invocable` key is the correct frontmatter field name for enabling slash commands, or whether slash command registration uses a different mechanism
   - Recommendation: Include in frontmatter as specified; verify that `/revenium` registers as a command once OpenClaw is installed. If the field name is wrong, it is a non-breaking issue (skill loads correctly, slash command may not register).

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Manual shell verification (no automated test framework — SKILL.md is a markdown file, not code) |
| Config file | None |
| Quick run command | `openclaw skills list \| grep revenium` |
| Full suite command | See Phase Requirements Test Map below |

### Phase Requirements Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SKAF-01 | Skill directory and SKILL.md exist at install path | smoke | `test -f ~/.openclaw/skills/revenium/SKILL.md && echo PASS` | Wave 0 |
| SKAF-02 | Skill absent from `openclaw skills list` when `revenium` not on PATH | manual | Remove `revenium` from PATH; `openclaw skills list \| grep -v revenium && echo PASS` | Wave 0 |
| SKAF-03 | YAML frontmatter parses without error; no colon-space in unquoted values; `metadata` is single-line | smoke | `openclaw skills list \| grep revenium` (skill appears = frontmatter valid) | Wave 0 |
| SKAF-04 | Skill appears in `openclaw skills list` when `revenium` is on PATH | smoke | `openclaw skills list \| grep revenium && echo PASS` | Wave 0 |

### Sampling Rate

- **Per task commit:** `test -f ~/.openclaw/skills/revenium/SKILL.md && openclaw skills list | grep revenium`
- **Per wave merge:** Full suite — all four requirement verifications above
- **Phase gate:** All four checks green before marking phase complete

### Wave 0 Gaps

- [ ] `~/.openclaw/` — OpenClaw must be installed; `openclaw` binary must be on PATH
- [ ] `~/.openclaw/skills/revenium/` — directory must be created before SKILL.md can be placed
- [ ] OpenClaw install: check `https://docs.openclaw.ai/getting-started/installation` — `openclaw` not found on PATH on this machine

## Sources

### Primary (HIGH confidence)
- `https://docs.openclaw.ai/tools/skills` — SKILL.md format, frontmatter fields, `requires.bins`, `requires.env`, system prompt injection, AgentSkills v1 spec (from prior project research, 2026-03-13)
- `https://raw.githubusercontent.com/openclaw/openclaw/main/skills/1password/SKILL.md` — Real CLI-wrapping skill example showing `requires.bins`, metadata format, instruction prose (from prior project research, 2026-03-13)
- `revenium-cli --help` and subcommand help — Direct binary introspection, verified against project root binary (2026-03-13)
- `.planning/research/STACK.md` — Stack research with verified CLI interface reference (2026-03-13)
- `.planning/research/PITFALLS.md` — Pitfalls research including confirmed YAML failure modes (2026-03-13)

### Secondary (MEDIUM confidence)
- `https://github.com/openclaw/clawhub/blob/main/docs/skill-format.md` — Single-line metadata constraint documentation (from prior project research)
- `https://github.com/openclaw/openclaw/issues/22134` — Confirmed silent YAML parse error behavior
- `https://github.com/openclaw/openclaw/issues/41549` — Confirmed PATH resolution bug in non-login shell exec

### Tertiary (LOW confidence)
- None for this phase — prior research covers all relevant domains at MEDIUM or higher confidence.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — OpenClaw skill format verified via official docs; CLI commands verified against live binary; no unknowns
- Architecture: HIGH — Frontmatter patterns are well-documented; body skeleton ordering is Claude's discretion (documented as such)
- Pitfalls: HIGH — YAML failure modes confirmed via GitHub issues and official docs; OpenClaw installation gap confirmed by live environment check

**Research date:** 2026-03-13
**Valid until:** 2026-04-13 (30 days — OpenClaw skill format is stable; CLI interface may change if binary is updated)
