# Architecture Research

**Domain:** OpenClaw skill wrapping a CLI tool (revenium-cli budget enforcement)
**Researched:** 2026-03-13
**Confidence:** MEDIUM — OpenClaw skill format well-documented; state persistence patterns inferred from community patterns, not official spec.

## Standard Architecture

### System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     OpenClaw Agent Runtime                       │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              System Prompt (injected at start)            │   │
│  │   <skills>                                                │   │
│  │     <skill name="revenium" location="~/.openclaw/..."/>   │   │
│  │   </skills>                                               │   │
│  └──────────────────────┬───────────────────────────────────┘   │
│                         │ agent reads SKILL.md on demand        │
│  ┌──────────────────────▼───────────────────────────────────┐   │
│  │                     SKILL.md                              │   │
│  │  [YAML frontmatter: name, description, metadata gates]    │   │
│  │  [Markdown body: setup instructions + operation guard]    │   │
│  └───────────────┬─────────────────────────────────────────┘    │
│                  │ agent executes via Bash tool                  │
└──────────────────┼──────────────────────────────────────────────┘
                   │
   ┌───────────────▼──────────────────────────────────────────┐
   │                   revenium-cli (on PATH)                  │
   │   config set key <API_KEY>                                │
   │   alerts budget create --threshold N --period PERIOD      │
   │   alerts budget get <anomaly-id>                          │
   └───────────────┬──────────────────────────────────────────┘
                   │ HTTPS
   ┌───────────────▼──────────────────────────────────────────┐
   │                  Revenium API                             │
   │  (token metering, budget alerts, spend reporting)        │
   └──────────────────────────────────────────────────────────┘
```

**Persistent state bridge:**

```
Agent instructions (SKILL.md body)
       │ instructs agent to write anomaly ID to
       ▼
~/.openclaw/skills/revenium/config.json  (or flat file)
       │ agent reads on each budget check
       ▼
revenium alerts budget get <anomaly-id>
```

### Component Responsibilities

| Component | Responsibility | Implementation |
|-----------|----------------|----------------|
| SKILL.md frontmatter | Declares dependencies, gates skill loading | YAML with `metadata.openclaw.requires.bins: ["revenium"]` |
| SKILL.md setup section | First-time config: API key capture, budget creation, anomaly ID persistence | Markdown instructions executed by agent |
| SKILL.md operation guard | Pre-operation budget check: read anomaly ID, call CLI, warn if exceeded | Markdown instructions — always-on guard pattern |
| revenium-cli | Executes API calls to Revenium platform | Go binary on user's PATH |
| Anomaly ID store | Persists anomaly ID from budget creation for subsequent checks | Simple JSON or text file in skill directory |
| Revenium API | Source of truth for spend vs threshold | External service, accessed only via CLI |

## Recommended Project Structure

```
~/.openclaw/skills/revenium/     # global install location
└── SKILL.md                     # single file: all skill logic

openclaw/                        # this repository (development)
├── SKILL.md                     # the deliverable
├── .planning/
│   ├── PROJECT.md
│   └── research/
└── README.md                    # install instructions
```

### Structure Rationale

- **Single SKILL.md:** OpenClaw skills are intentionally self-contained. All logic — frontmatter gates, setup flow, and operation guard — lives in one file. No separate scripts, no build step.
- **~/.openclaw/skills/revenium/:** Global install location makes the skill available to all agents on the machine. The skill directory (not just the file) is needed so the skill can write a sibling `config.json` for anomaly ID persistence.
- **Repository mirrors install location:** The repo root contains `SKILL.md` directly — `cp SKILL.md ~/.openclaw/skills/revenium/SKILL.md` is the full install.

## Architectural Patterns

### Pattern 1: Binary Gate via requires.bins

**What:** Declare required CLI binaries in `metadata.openclaw.requires.bins`. OpenClaw checks PATH at load time and silently drops the skill if the binary is missing.

**When to use:** Every CLI-wrapping skill. Prevents confusing errors when the underlying tool isn't installed.

**Trade-offs:** Fail-silent (skill just doesn't appear) is clean UX but provides no guidance to users who haven't installed the binary yet. Mitigate with install specs in metadata.

**Example:**
```yaml
---
name: revenium
description: Track and enforce token usage budgets via Revenium CLI
metadata: {"openclaw":{"requires":{"bins":["revenium"]}}}
---
```

### Pattern 2: Two-Phase Skill Instructions (Setup + Guard)

**What:** Structure the SKILL.md body in two clearly delineated sections: a one-time setup flow and an always-on operation guard. The agent is instructed to detect which phase applies.

**When to use:** Any skill that requires initial configuration before it can perform its ongoing function.

**Trade-offs:** All logic in one file keeps things simple but the instructions must be precise about when each section applies — ambiguity leads to the agent re-running setup on every operation.

**Example structure:**
```markdown
## Setup (run once, when no anomaly ID is stored)

1. Ask the user for their Revenium API key
2. Run: revenium config set key <API_KEY>
3. Ask the user for their budget amount and period
4. Run: revenium alerts budget create --threshold <N> --period <PERIOD>
5. Save the returned anomaly ID to {baseDir}/config.json

## Operation Guard (run before every operation)

1. Read the anomaly ID from {baseDir}/config.json
2. Run: revenium alerts budget get <anomaly-id>
3. If budget exceeded: warn the user and ask permission to continue
4. If budget not exceeded: proceed silently
```

### Pattern 3: File-Based State for Anomaly ID Persistence

**What:** Use a JSON file co-located in the skill directory (`{baseDir}/config.json`) to store the anomaly ID between agent sessions.

**When to use:** Any skill that generates a reference ID at setup time and needs it for every subsequent operation. The file approach survives agent restarts and new sessions — unlike in-conversation memory.

**Trade-offs:** File write is a Bash tool call. Agent must be instructed to handle the case where the file doesn't exist (trigger setup). JSON is human-readable so users can inspect or reset.

**Alternative considered — openclaw.json:** Could store anomaly ID in `~/.openclaw/openclaw.json` via `skills.entries.revenium.env`, but this requires the user to manually edit config or a separate config-changer skill. File-in-skill-dir is self-contained.

## Data Flow

### First-Time Setup Flow

```
Agent detects no config.json at {baseDir}/config.json
    ↓
Agent asks user: "What is your Revenium API key?"
    ↓
Agent runs: revenium config set key <API_KEY>
    ↓
Agent asks user: "What is your budget amount and period?"
    ↓
Agent runs: revenium alerts budget create --threshold N --period PERIOD
    ↓
CLI returns: {"anomalyId": "abc-123", ...}
    ↓
Agent writes: {baseDir}/config.json  ← {"anomalyId": "abc-123"}
    ↓
Setup complete — skill transitions to guard mode
```

### Per-Operation Budget Check Flow

```
User requests any agent operation
    ↓
Agent reads: {baseDir}/config.json → anomalyId
    ↓ (if missing, trigger setup flow first)
Agent runs: revenium alerts budget get <anomalyId>
    ↓
CLI returns: {spent: N, threshold: M, exceeded: bool}
    ↓
exceeded == false → proceed silently with operation
exceeded == true  → warn user, ask "Continue anyway? (y/n)"
    ↓
User response gates whether operation runs
```

### Key Data Flows

1. **API key flow:** User → agent prompt → `revenium config set key` → Revenium CLI config file (not in SKILL.md, not logged)
2. **Anomaly ID flow:** Revenium API response → agent → `{baseDir}/config.json` → read on each operation → CLI lookup
3. **Budget status flow:** `revenium alerts budget get` → CLI → Revenium API → spend/threshold response → agent decision logic

## Build Order (Dependency Implications)

The skill has a natural build sequence driven by logical dependencies:

```
1. Frontmatter + binary gate
   └── Establishes SKILL.md exists and loads when revenium is on PATH

2. Setup flow instructions
   └── Requires: frontmatter works (skill loads)
   └── Produces: working API config + anomaly ID in config.json

3. Operation guard instructions
   └── Requires: setup flow complete (anomaly ID exists)
   └── Requires: correct CLI output parsing to detect exceeded state

4. User permission prompt on exceeded
   └── Requires: operation guard detects exceeded state correctly
```

**Implication:** Build and test the frontmatter gate first (skill loads/drops correctly), then the setup flow in isolation, then the guard loop. The guard is untestable until setup produces a valid anomaly ID.

## Anti-Patterns

### Anti-Pattern 1: Inline Setup Logic in the Guard

**What people do:** Write one unified instruction block that always checks "is config set? if not, set it" mixed with the budget check logic.

**Why it's wrong:** Mixes two distinct states (needs-setup vs. operational) into one ambiguous flow. The agent may ask for API keys on every operation if the conditional detection is fuzzy, or silently skip re-setup when the config.json is accidentally deleted.

**Do this instead:** Separate setup and guard into clearly labeled sections. Instruct the agent: "Run the Setup section only if `{baseDir}/config.json` does not exist. Run the Operation Guard section before every other operation."

### Anti-Pattern 2: Storing the API Key in config.json

**What people do:** Write the Revenium API key into `{baseDir}/config.json` alongside the anomaly ID for easy access.

**Why it's wrong:** The skill directory may be world-readable. The key is already stored by `revenium config set key` in the CLI's own config (typically `~/.config/revenium/config.yaml`). Double-storing it in the skill dir creates an unnecessary exposure surface.

**Do this instead:** Store only the anomaly ID in `{baseDir}/config.json`. The API key lives exclusively in the CLI's own config file.

### Anti-Pattern 3: Using requires.env for the API Key

**What people do:** Gate the skill on `REVENIUM_API_KEY` being set as an environment variable, then use that env var in CLI calls.

**Why it's wrong:** The revenium-cli stores the key via `revenium config set key`, not env vars. Forcing env var gating means the skill won't load unless the user sets an env var — conflicting with the skill's own setup flow that handles key configuration.

**Do this instead:** Gate only on the binary (`requires.bins: ["revenium"]`). Let the setup flow handle API key configuration via the CLI's native config mechanism.

### Anti-Pattern 4: Skipping the Operation Guard on "Quick" Operations

**What people do:** Instruct the agent to only check budget before "major" or "expensive" operations, skipping it for file reads, summaries, etc.

**Why it's wrong:** Token spend is cumulative and unpredictable. What feels "small" (reading a large codebase for context) may consume significant tokens. The value of the guardrail is its unconditional nature — any exception creates a hole.

**Do this instead:** Check before every operation, proceed silently when budget is fine. The latency cost of one CLI call is acceptable; the cost of silent overage is not.

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| Revenium API | Via revenium-cli binary (not direct HTTP) | Agent never calls API directly; all calls via CLI |
| revenium-cli config store | `revenium config set key` writes to CLI's own config dir | Location is CLI-managed, not skill-managed |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| SKILL.md instructions ↔ revenium-cli | Agent executes Bash commands | Agent is the orchestrator; CLI is a pure executor |
| SKILL.md instructions ↔ config.json | Agent reads/writes via Bash (cat, echo, jq) | File is the only persistence mechanism |
| SKILL.md ↔ OpenClaw system prompt | OpenClaw injects skill reference at startup; agent loads SKILL.md body on demand | ~97 chars overhead per skill in system prompt |

## Scaling Considerations

This skill runs on a single developer machine. Scaling is not a concern. The only "scaling" dimension is latency:

| Concern | Reality | Mitigation |
|---------|---------|------------|
| Budget check latency | One HTTPS round-trip per operation | Accept it; latency is ~100-500ms, acceptable for guardrail |
| Revenium API unavailability | CLI call fails | Skill instructions should specify fail-open or fail-closed behavior explicitly |
| Multiple agents on same machine | All share the same anomaly ID in config.json | Intended — single shared budget per machine per PROJECT.md |

## Sources

- [Skills - OpenClaw official docs](https://docs.openclaw.ai/tools/skills) — SKILL.md format, frontmatter fields, requires.bins/env, system prompt injection (MEDIUM confidence — fetched 2026-03-13)
- [Skills Config - OpenClaw official docs](https://docs.openclaw.ai/tools/skills-config) — openclaw.json skills configuration (MEDIUM confidence)
- [Creating Skills - OpenClaw Lab](https://openclawlab.com/en/docs/tools/creating-skills/) — supplementary skill creation docs (LOW confidence — content incomplete)
- [OpenClaw skills guide - LumaDock](https://lumadock.com/tutorials/openclaw-skills-guide) — community patterns, binary gating (MEDIUM confidence)
- [What are OpenClaw Skills? - DigitalOcean](https://www.digitalocean.com/resources/articles/what-are-openclaw-skills) — ecosystem overview (MEDIUM confidence)
- [agent-wallet-cli SKILL.md example](https://github.com/openclaw/skills/blob/main/skills/donald-jackson/agent-wallet-cli/SKILL.md) — real CLI wrapper skill example (HIGH confidence — official skills registry)

---
*Architecture research for: OpenClaw skill wrapping revenium-cli for token budget enforcement*
*Researched: 2026-03-13*
