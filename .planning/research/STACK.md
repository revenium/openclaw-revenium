# Stack Research

**Domain:** OpenClaw skill wrapping a CLI binary (revenium-cli)
**Researched:** 2026-03-13
**Confidence:** HIGH (based on official OpenClaw docs + direct binary introspection)

## Overview

This project has an unusual "stack": there are no npm packages, no build steps, and no code files. The entire deliverable is a single `SKILL.md` file. The "stack" is the OpenClaw skill format (AgentSkills spec) plus the revenium-cli interface. Everything the agent does is expressed as prose instructions in markdown.

---

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| OpenClaw SKILL.md format | AgentSkills v1 spec | Delivers skill instructions to the agent | The only supported format. OpenClaw injects eligible `SKILL.md` files into the system prompt. No alternative. |
| revenium-cli | Binary on PATH (arm64 Mach-O, ~12MB) | All Revenium API calls | Already exists and covers all required operations. Never replicate what the CLI already does. |
| YAML frontmatter (single-line JSON metadata) | OpenClaw parser constraint | Declares skill identity, gating, and binary requirements | The embedded agent parser requires single-line frontmatter keys. Multi-line YAML for `metadata` is NOT supported. |
| Bash (via agent's shell tool) | Any POSIX shell | Executing revenium-cli subcommands | Skills instruct the agent to run commands. The agent uses its `bash`/`shell` tool to invoke them. |

### Supporting Libraries

None. This is a pure skill — no code dependencies.

| Concept | Version/Spec | Purpose | When to Use |
|---------|--------------|---------|-------------|
| `{baseDir}` placeholder | OpenClaw skill runtime | Reference skill folder path in instructions | Use if skill ships supporting files alongside SKILL.md |
| `skills.entries.<name>.config` in `openclaw.json` | OpenClaw config spec | Per-skill custom fields for persisted state (anomaly ID) | Use as the recommended pattern for persisting the budget anomaly ID between sessions |
| `~/.openclaw/openclaw.json` | JSON5 | Global OpenClaw config file | The right place to document how the anomaly ID should be stored — instruct user to set it there, or have agent write it via bash |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| revenium-cli (local binary) | Verify command syntax against live API | Binary is at `/path/to/revenium-cli`. Always test `--help` output before writing instructions. |
| OpenClaw (local install) | Test skill loading and gating | Place skill at `~/.openclaw/skills/revenium/SKILL.md` and verify it loads correctly |

---

## revenium-cli Interface Reference

These are the commands the SKILL.md must instruct the agent to use. Verified against the binary directly.

### Setup Commands

```bash
# Configure API key
revenium config set key <api-key>

# Show current config (verify key is set)
revenium config show
```

### Budget Alert Commands

```bash
# Create a budget alert (returns anomaly ID — must be persisted)
revenium alerts budget create \
  --name "Agent Budget" \
  --threshold <amount> \
  --period <DAILY|WEEKLY|MONTHLY|QUARTERLY>

# Check budget status (requires anomaly ID from create)
revenium alerts budget get <anomaly-id>

# Check budget status as JSON (easier to parse)
revenium alerts budget get <anomaly-id> --json

# List existing budget alerts (find existing anomaly ID)
revenium alerts budget list
```

### Global Flags

```bash
--json      # Output as JSON (prefer this for programmatic checks)
-q          # Suppress non-error output
-y          # Skip confirmation prompts (use during setup)
```

---

## Skill Format Specification

### Required Frontmatter

```yaml
---
name: revenium
description: Track and enforce token usage budgets for OpenClaw agents using the Revenium API. Checks budget status before every operation and warns when thresholds are exceeded.
metadata: {"openclaw":{"emoji":"💰","requires":{"bins":["revenium"]}}}
---
```

**Critical constraints (verified from official docs):**
- `metadata` MUST be a single-line JSON object — the embedded agent parser does not support multi-line frontmatter values
- `requires.bins: ["revenium"]` gates skill loading on the binary being present on PATH — if `revenium` is not found, the skill silently does not load
- `name` should be kebab-case slug

### State Persistence (Anomaly ID)

OpenClaw has no built-in per-skill state storage beyond `~/.openclaw/openclaw.json`. The anomaly ID returned by `alerts budget create` must be persisted across sessions.

**Recommended pattern:** Instruct the agent to write the anomaly ID to a config file during setup. Two viable approaches:

1. **Write to a dedicated config file** (simpler, self-contained):
   ```bash
   # Agent writes during setup
   echo "REVENIUM_ANOMALY_ID=anom-123" > ~/.openclaw/skills/revenium/.env
   # Agent reads during checks
   source ~/.openclaw/skills/revenium/.env && revenium alerts budget get "$REVENIUM_ANOMALY_ID" --json
   ```

2. **Write to `~/.openclaw/openclaw.json` via jq** (integrates with OpenClaw config):
   ```bash
   # More complex, requires jq, but uses the canonical config location
   ```

**Recommendation: Use approach 1** (simple dotfile alongside the skill). It's bash-native, requires no dependencies, survives OpenClaw restarts, and is trivial to inspect or reset.

### Skill Install Location

```
~/.openclaw/skills/revenium/SKILL.md
```

This is the `~/.openclaw/skills/` managed/local tier — visible to all agents on the machine (shared skills), not per-workspace. Matches the requirement for a global skill.

---

## Installation

No npm packages. Installation is:

```bash
# 1. Create skill directory
mkdir -p ~/.openclaw/skills/revenium

# 2. Copy SKILL.md
cp SKILL.md ~/.openclaw/skills/revenium/SKILL.md

# 3. Verify revenium binary is on PATH
which revenium
```

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| Single `SKILL.md` file | Multi-file skill with helper scripts | When the skill needs deterministic output parsing that prose instructions can't reliably produce. Not needed here — revenium-cli's `--json` flag makes output structured. |
| `requires.bins: ["revenium"]` gating | `requires.env: ["REVENIUM_API_KEY"]` gating | When you want to gate on the API key being configured as an env var rather than the binary being present. Not ideal here — the binary check is simpler and the API key is stored inside revenium-cli's own config. |
| Store anomaly ID in `~/.openclaw/skills/revenium/.env` | Store in `openclaw.json` config block | If the team wants all state centralized in openclaw.json. More complex (requires jq or a config update script), not worth the added fragility. |
| Instruct agent to use `--json` flag | Parse human-readable output | `--json` produces stable parseable output. Human-readable output is subject to formatting changes. Always use `--json` for programmatic checks. |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Multi-line YAML for `metadata` | The embedded agent parser only supports single-line frontmatter keys. Multi-line metadata silently breaks skill loading or gating. | Single-line JSON: `metadata: {"openclaw":{...}}` |
| Parsing revenium-cli output without `--json` | Human-readable output is not a stable API contract. Format may change across binary versions. | `revenium alerts budget get <id> --json` |
| Bundling the revenium-cli binary in the skill directory | Out of scope per PROJECT.md. Increases skill size (12MB binary), complicates updates, creates version mismatch risk. | Require `revenium` on PATH via `requires.bins` |
| Storing the API key in the skill's `.env` file | The API key is sensitive. revenium-cli stores it in its own config (`revenium config set key`). Duplicating it in a plaintext file adds attack surface. | Use `revenium config set key` during setup — CLI manages its own credential storage. |
| Complex shell scripting within skill instructions | Skills are markdown prose instructions for an LLM, not a shell script. Over-specified bash makes instructions brittle and hard to maintain. | Keep instructions declarative: describe what to do, let the agent handle error cases. |
| `disable-model-invocation: true` | Would prevent the skill from being injected into the model prompt — skill would never fire autonomously. | Leave at default (`false`) so budget check fires before every operation. |

---

## Stack Patterns by Variant

**If the user already has a budget alert configured:**
- Skill setup should run `revenium alerts budget list --json` to find the existing anomaly ID
- Store it rather than creating a duplicate alert
- Because duplicate alerts cause redundant notifications and confusing budget tracking

**If `revenium` is not on PATH at skill load time:**
- Skill silently does not load (enforced by `requires.bins`)
- The agent won't see the skill, so no budget checking happens
- Skill instructions should include a pre-check: `which revenium || echo "revenium not found on PATH"`

**If `--json` output parsing fails:**
- Fall back to checking exit code from `revenium alerts budget get`
- A non-zero exit code signals an error; instruct agent to warn the user
- Don't silently proceed if budget status is unknown

---

## Version Compatibility

| Component | Version | Compatibility Notes |
|-----------|---------|---------------------|
| revenium-cli | Current binary (arm64, ~12MB) | Only darwin/arm64 confirmed locally. `revenium-cli --version` should be checked to record exact version. |
| OpenClaw skill format | AgentSkills v1 | Single-line metadata constraint is a parser limitation; check OpenClaw release notes if format changes. |
| `openclaw.json` `skills.entries.*.config` | Current OpenClaw | Custom config fields land under `config:` key per-skill; use for non-secret persistent values like anomaly ID. |

---

## Sources

- `https://raw.githubusercontent.com/openclaw/openclaw/main/docs/tools/skills.md` — Full skill format spec, gating fields, load order, AgentSkills compatibility (HIGH confidence)
- `https://raw.githubusercontent.com/openclaw/openclaw/main/docs/tools/skills-config.md` — `openclaw.json` schema, per-skill config, env injection (HIGH confidence)
- `https://raw.githubusercontent.com/openclaw/openclaw/main/skills/1password/SKILL.md` — Real-world CLI-wrapping skill example showing `requires.bins`, metadata format, and instruction prose (HIGH confidence)
- `https://raw.githubusercontent.com/openclaw/skills/main/skills/rursache/solo-cli/SKILL.md` — Another CLI wrapper skill, showing file-based config storage pattern (HIGH confidence)
- `revenium-cli --help` + subcommand `--help` (all variants) — Direct binary introspection, authoritative on command syntax (HIGH confidence)
- `https://docs.openclaw.ai/tools/skills` — Official documentation confirming frontmatter fields and AgentSkills spec (HIGH confidence)

---
*Stack research for: OpenClaw skill wrapping revenium-cli for budget enforcement*
*Researched: 2026-03-13*
