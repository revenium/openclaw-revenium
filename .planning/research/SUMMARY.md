# Project Research Summary

**Project:** Revenium OpenClaw Skill
**Domain:** OpenClaw skill wrapping a CLI binary (revenium-cli) for agent budget enforcement
**Researched:** 2026-03-13
**Confidence:** MEDIUM-HIGH

## Executive Summary

This project delivers a single `SKILL.md` file — an OpenClaw agent skill that wraps `revenium-cli` to enforce token spend budgets. There are no npm packages, build steps, code files, or frameworks: the entire deliverable is prose instructions in markdown with a YAML frontmatter block. The skill is installed globally at `~/.openclaw/skills/revenium/` where OpenClaw automatically injects it into the agent's system prompt, making it available to every agent on the machine.

The recommended approach is straightforward: write a single `SKILL.md` with two clearly separated sections — a one-time setup flow (API key config, budget alert creation, anomaly ID persistence) and an always-on operation guard (pre-operation budget check with warn-and-ask on exceeded). The only meaningful technical challenge is state persistence: the anomaly ID returned by `revenium alerts budget create` must be written to a file (`{baseDir}/config.json`) so the guard can reference it across sessions and restarts.

The primary risks are YAML authoring mistakes that silently kill skill loading (unquoted colons in `description`, multi-line `metadata` field), agent LLM discretion overriding budget check instructions, and binary PATH resolution differences between interactive and headless OpenClaw environments. All three risks have clear mitigations documented in research and must be addressed during SKILL.md authoring and testing.

## Key Findings

### Recommended Stack

The "stack" is OpenClaw's AgentSkills v1 format plus the revenium-cli binary. All skill logic is expressed in a single SKILL.md — no code, no dependencies, no build tooling. The revenium-cli binary (Go, arm64, ~12MB) handles all Revenium API calls; the skill never touches the API directly.

**Core technologies:**

- **OpenClaw SKILL.md format (AgentSkills v1):** The sole delivery artifact. Injected by OpenClaw into the agent system prompt. No alternative format exists.
- **revenium-cli (on PATH):** All API operations. Verified command surface: `config set key`, `alerts budget create --threshold N --period P`, `alerts budget get <id>`, `alerts budget list`, global flags `--json`, `-y`, `-q`.
- **YAML frontmatter (single-line JSON metadata):** Declares skill identity and gates load on binary presence. The `metadata` field MUST be a single-line JSON value — a parser constraint that is not prominently documented.
- **Bash (agent shell tool):** The agent executes all CLI commands via its Bash/shell tool. Skills instruct the agent what to run; the agent executes.
- **`{baseDir}/config.json`:** File-based state store co-located in the skill directory. Sole mechanism for persisting the anomaly ID across sessions.

### Expected Features

Features research identified a clear MVP boundary driven by the logical dependency chain: API key config must precede budget creation, budget creation must precede anomaly ID persistence, and persistence must precede the guard loop.

**Must have (table stakes):**
- Binary gating via `requires.bins: ["revenium"]` — skill must not load when binary is absent
- First-time setup: prompt for API key, configure via `revenium config set key`
- First-time setup: prompt for budget amount and period, create alert via `revenium alerts budget create`
- Anomaly ID persistence to `{baseDir}/config.json` — the pivot between setup and ongoing operation
- Idempotent setup: check for existing anomaly ID (and list existing alerts) before creating a new one
- Pre-operation budget check via `revenium alerts budget get <anomaly-id>` before every tool call
- Warn-and-ask when budget exceeded — human retains control
- Silent pass-through when budget is fine — zero friction in normal operation

**Should have (competitive differentiators):**
- Budget status context in the warning message (current spend vs. threshold vs. period) — makes warnings actionable rather than abstract
- Setup re-run command (dedicated trigger to reconfigure without reinstalling)
- List-and-select existing alerts on setup — prevents duplicate alert creation for returning users

**Defer to v2+:**
- Grace mode toggle (warn-only vs. hard-stop behavior)
- Configurable check granularity (every N operations vs. every operation)

**Anti-features to avoid:**
- Token count estimation in the skill — Revenium meters server-side; agent estimates would be wrong
- Bundling the revenium-cli binary inside the skill — format does not support executables
- Multi-budget support (per-project or per-agent) — exceeds the global single-skill model
- Automatic budget increase requests — defeats the purpose of the guardrail

### Architecture Approach

The skill has two runtime phases: a one-time setup flow and an always-on operation guard. These must be clearly delineated sections in SKILL.md so the agent knows exactly when each applies. The agent acts as the orchestrator — it reads instructions, executes CLI commands via Bash, writes/reads the config file, and makes the allow/deny decision. The revenium-cli is a pure executor with no agent-side logic.

**Major components:**

1. **SKILL.md frontmatter** — declares name, description, and `requires.bins: ["revenium"]` gate; controls whether the skill loads at all
2. **Setup section** — one-time flow: API key input, budget creation, anomaly ID persistence to `{baseDir}/config.json`; triggered when config.json is absent
3. **Operation guard section** — runs before every agent tool call; reads anomaly ID from config.json, calls `revenium alerts budget get`, routes to warn-and-ask or silent pass-through
4. **`{baseDir}/config.json`** — the only persistent state; stores anomaly ID (and optionally alert name for sanity-checking); written during setup, read on every guard check
5. **revenium-cli** — Go binary on PATH; handles all Revenium API communication; agent never calls API directly

### Critical Pitfalls

1. **YAML frontmatter silently kills skill loading** — Any unquoted colon-space (`: `) in `description` or other string values causes the skill to be silently dropped with no error. Avoid by wrapping all string values in double quotes. Verify after every frontmatter change with `openclaw skills list`.

2. **`metadata` field must be single-line JSON** — Multi-line YAML for `metadata` is rejected by OpenClaw's embedded parser, causing the `requires.bins` gate to be silently ignored. Keep `metadata` as a single-line JSON string regardless of length.

3. **Binary PATH resolution fails in non-login shell environments** — OpenClaw may exec in a non-login shell that does not source `~/.zshrc` or Homebrew initializations, so `revenium` is not found at runtime even though `requires.bins` passed at load time (a confirmed OpenClaw bug). Mitigate by including a `which revenium` verification step in setup and documenting system-level PATH requirements.

4. **Agent treats skill instructions as suggestions, not mandates** — LLMs exercise discretion and may skip the budget check for operations they deem low-risk. Counteract with explicit mandatory framing ("BEFORE executing any tool call, you MUST run..."), imperative language, and adversarial testing.

5. **Anomaly ID has no native persistence mechanism** — OpenClaw sessions reset (daily by default, on `/reset`, on context overflow). Relying on agent in-context memory for the anomaly ID guarantees loss overnight. The anomaly ID must be written to a file during setup and read back on every guard check.

6. **Re-running setup creates duplicate budget alerts** — Without an idempotency check, each setup run creates a new alert in Revenium. The setup flow must call `revenium alerts budget list` first and offer to reuse an existing alert before calling `alerts budget create`.

## Implications for Roadmap

Based on research, the natural build order is driven by hard dependencies in the feature chain: the skill must load before setup can run, setup must complete before the guard can work, and the guard must work before any polish or differentiators are meaningful.

### Phase 1: Skill Scaffolding and Binary Gate

**Rationale:** Everything else depends on the skill loading correctly. The two most dangerous silent failure modes (YAML parse errors, multi-line metadata) must be eliminated first before any functional work can be tested.
**Delivers:** A valid SKILL.md that loads in `openclaw skills list`, correctly appears when `revenium` is on PATH, and is silently absent when it is not.
**Addresses:** Binary gating (`requires.bins`), YAML frontmatter correctness, skill install location
**Avoids:** YAML colon-space bug (Pitfall 1), single-line metadata constraint (Pitfall 2)

### Phase 2: Setup Flow (API Key + Budget Creation + Anomaly ID Persistence)

**Rationale:** The guard loop cannot be built or tested without a valid anomaly ID. Setup is the prerequisite for everything operational. Idempotency and duplicate-alert prevention must be designed here, not retrofitted.
**Delivers:** A working first-time setup that collects API key and budget parameters, creates the alert, and writes the anomaly ID to `{baseDir}/config.json`. A returning-user path that detects existing config and skips creation.
**Addresses:** API key setup, budget creation, anomaly ID persistence, idempotent setup
**Avoids:** Duplicate alert creation (Pitfall 6), anomaly ID loss on session reset (Pitfall 5)

### Phase 3: Operation Guard (Pre-operation Budget Check)

**Rationale:** Core guardrail behavior. Depends entirely on Phase 2 producing a valid anomaly ID and config file.
**Delivers:** A guard instruction that reads config.json, calls `revenium alerts budget get`, and correctly routes to warn-and-ask (exceeded) or silent pass-through (within budget). Mandatory framing to reduce agent discretion.
**Addresses:** Pre-operation budget check, warn-and-ask on exceeded, silent pass-through when OK
**Avoids:** Agent skipping budget check (Pitfall 4), binary PATH failure at runtime (Pitfall 3)

### Phase 4: Polish and Differentiators

**Rationale:** Once the core guardrail works end-to-end (including cross-session persistence verified on a fresh session the day after setup), add the features that improve UX quality without changing the fundamental behavior.
**Delivers:** Budget status context in warning messages (spend vs. threshold vs. period), setup re-run command, list-and-select for existing alerts, improved error recovery paths.
**Addresses:** Budget status in agent context, setup re-run, list-and-select existing alerts
**Avoids:** Vague warning messages (UX pitfall), no recovery path for missing state (UX pitfall)

### Phase Ordering Rationale

- Phase 1 before everything: YAML errors are silent and will waste hours of debugging if not caught at the start
- Phase 2 before Phase 3: The guard is completely untestable without a real anomaly ID from a completed setup
- Idempotency in Phase 2 not Phase 4: Retrofitting idempotency after the guard is built risks data inconsistency; it belongs in the same phase as creation
- Phase 4 after cross-session verification: Differentiators should not ship before the core is confirmed to work on a cold session (next day, after reset)

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 3 (Operation Guard):** Instruction framing to enforce mandatory behavior in LLM agents is an active research area; the exact phrasing that minimizes agent discretion may need iterative testing. No definitive guidance exists.
- **Phase 3 (Operation Guard):** The Revenium API response schema for `alerts budget get --json` should be verified against the live binary before coding the parsing instructions; field names (`exceeded`, `currentValue`, `threshold`) should be confirmed.

Phases with standard patterns (skip deep research):
- **Phase 1 (Skill Scaffolding):** Well-documented in official OpenClaw docs. YAML quoting and single-line metadata are known constraints with clear solutions.
- **Phase 2 (Setup Flow):** CLI command syntax is fully verified against the binary. File-based state persistence is a standard pattern confirmed in community skill examples.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Skill format verified via official docs; CLI commands verified via direct binary introspection; no unknowns in what to build |
| Features | MEDIUM | Table-stakes features are authoritative (from PROJECT.md and official docs); differentiator priority based on inferred user needs rather than usage data |
| Architecture | MEDIUM | Core patterns (binary gate, two-phase setup/guard, file-based persistence) verified via official docs and real skill examples; exact instruction phrasing for LLM compliance is empirical |
| Pitfalls | MEDIUM-HIGH | YAML and metadata pitfalls confirmed via official issues (#22134) and docs; agent instruction compliance and PATH resolution confirmed via official issues (#30681, #41549); anomaly ID persistence patterns inferred from community examples |

**Overall confidence:** MEDIUM-HIGH

### Gaps to Address

- **Revenium API response schema:** The exact JSON field names returned by `revenium alerts budget get --json` (particularly the field that signals "budget exceeded") should be verified by running the command against the live binary before writing parsing instructions. The guard loop depends on this.
- **Agent instruction compliance phrasing:** No authoritative source defines the optimal mandatory framing for OpenClaw skill instructions. The framing in Phase 3 will need adversarial testing (attempt to prompt the agent to skip the check) and likely iteration.
- **Network failure behavior:** The skill must define a fail-open or fail-closed policy when the Revenium API is unreachable. Research did not find a definitive community consensus on which is more appropriate for a budget guardrail; this is a product decision to make during Phase 3.
- **darwin/arm64 only confirmed:** The revenium-cli binary is confirmed on arm64 macOS. Linux and x86_64 compatibility is unverified. Not a blocker for v1 but worth noting if the skill is to be distributed broadly.

## Sources

### Primary (HIGH confidence)
- `https://docs.openclaw.ai/tools/skills` — SKILL.md format, frontmatter fields, `requires.bins`, `requires.env`, system prompt injection, AgentSkills v1 spec
- `https://docs.openclaw.ai/tools/skills-config` — `openclaw.json` schema, per-skill config, env injection
- `https://raw.githubusercontent.com/openclaw/openclaw/main/skills/1password/SKILL.md` — Real CLI-wrapping skill example (frontmatter, `requires.bins`, instruction prose)
- `revenium-cli --help` + all subcommand `--help` variants — Authoritative CLI command surface, verified against binary
- `https://github.com/openclaw/skills/blob/main/skills/donald-jackson/agent-wallet-cli/SKILL.md` — Official skills registry example of CLI wrapper skill
- `https://github.com/openclaw/openclaw/issues/22134` — Confirmed silent YAML parse error behavior
- `https://github.com/openclaw/openclaw/issues/41549` — Confirmed PATH resolution bug in non-login shell exec
- `https://github.com/openclaw/openclaw/issues/30681` — Confirmed agent discretion over-riding skill instructions

### Secondary (MEDIUM confidence)
- `https://lumadock.com/tutorials/openclaw-skills-guide` — Community patterns for binary gating and skill structure
- `https://www.digitalocean.com/resources/articles/what-are-openclaw-skills` — Ecosystem overview
- `https://docs.revenium.io/cost-and-performance-alerts` — Alert configuration reference, webhook payload fields
- `https://github.com/openclaw/clawhub/blob/main/docs/skill-format.md` — Single-line metadata constraint documentation

### Tertiary (LOW confidence)
- `https://lobehub.com/skills/amnadtaowsoam-cerebraskills-budget-guardrails` — Competitor feature reference (single source, needs validation)
- Industry guardrail pattern sources (authoritypartners.com, agno.com, galileo.ai) — Conceptual validation for warn-and-ask and pre-action approval patterns

---
*Research completed: 2026-03-13*
*Ready for roadmap: yes*
