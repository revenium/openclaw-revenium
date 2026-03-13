# Feature Research

**Domain:** AI agent budget/guardrail skill (OpenClaw skill format)
**Researched:** 2026-03-13
**Confidence:** MEDIUM — OpenClaw skill ecosystem verified via web sources; Revenium CLI command surface defined by PROJECT.md (authoritative); guardrail patterns verified via multiple industry sources.

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features users assume exist. Missing these = product feels incomplete.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Binary gating via `requires.bins` | Skill must not silently fail when `revenium` is absent — users expect a clear "this skill won't load" signal | LOW | OpenClaw loads `requires.bins` at skill eligibility check time; no binary = skill excluded from system prompt automatically |
| First-time setup: API key prompt | Any credential-gated tool must ask for the credential on first run — users won't find `revenium config set key` themselves | LOW | Skill instructs the agent to ask the user interactively during setup; agent runs the CLI command with the provided value |
| First-time setup: budget amount + period prompt | Creating a budget alert requires threshold and period — users expect guided setup, not raw CLI invocations | LOW | Agent asks for amount (numeric) and period (DAILY/WEEKLY/MONTHLY/QUARTERLY), then calls `revenium alerts budget create` |
| Auto-create budget alert | Users expect the skill to handle the "create the alert" step — not instruct them to do it manually | LOW | One CLI call: `revenium alerts budget create --threshold <amount> --period <period>` |
| Budget check before every operation | The core guardrail expectation: every agent action is budget-gated, not just some | MEDIUM | Skill instructions must instruct the agent to run `revenium alerts budget get <anomaly-id>` as a pre-action step every time |
| Warn-and-ask when budget exceeded | Users expect explicit human confirmation before the agent proceeds past a threshold — silent continuation is a trust violation | LOW | Skill instructions tell the agent: if budget exceeded, surface a warning and ask the user for permission before continuing |
| Silent pass-through when budget OK | Users expect zero friction during normal operations — warnings only when relevant | LOW | Skill instructions must say: if budget not exceeded, proceed without any user interruption |
| Anomaly ID persistence | The budget check needs a stable reference to the alert created during setup — users expect this to "just work" on subsequent runs | MEDIUM | Anomaly ID returned from `alerts budget create` must be stored (e.g., in a config file at `~/.openclaw/skills/revenium/config`) and read back on subsequent invocations |
| Idempotent setup | Running setup a second time should not create a duplicate budget alert — users expect safe re-runs | MEDIUM | Skill must check if an anomaly ID is already stored before calling `alerts budget create`; if present, skip creation |

### Differentiators (Competitive Advantage)

Features that set the product apart. Not required, but valued.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Budget status in agent context | Instead of just blocking, the skill surfaces current spend vs. threshold in the agent's warning message (e.g., "You have used $4.80 of your $5.00 monthly budget") | MEDIUM | Requires parsing `alerts budget get` output for `currentValue` and `threshold` fields; makes the warning actionable rather than abstract |
| List-and-select existing alerts on setup | If the user already has budget alerts configured in Revenium, offer to select one instead of creating a duplicate | MEDIUM | Uses `revenium alerts budget list`; reduces friction for returning users; requires agent to parse list output |
| Configurable check granularity | Allow users to set how frequently checks happen (every N operations vs. every operation) to balance oversight with latency | HIGH | Network round-trip per operation adds latency; skip-N pattern requires counter state; likely out of scope for v1 |
| Grace mode toggle | Let the user set "warn-only" vs "hard-stop" behavior so power users can choose between human-in-loop and fully autonomous continuation | MEDIUM | Stored preference in config; changes the agent's response to an exceeded budget from "ask permission" to "stop entirely" |
| Setup re-run command | A distinct "reconfigure" invocation that lets users update budget amount, period, or API key without uninstalling | LOW | Skill instructions include a dedicated setup trigger phrase; clears stored config and re-runs the setup flow |

### Anti-Features (Commonly Requested, Often Problematic)

Features that seem good but create problems.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Token counting/estimation in the skill | Users want to know "how many tokens will this cost?" before running | Revenium does the actual metering server-side; the agent has no reliable way to estimate future token costs pre-run; any estimate would be wrong and create false confidence | Rely on Revenium's `currentValue` from `alerts budget get` — it reflects actual post-hoc spend, which is accurate |
| Bundling the revenium binary inside the skill | Users want zero-dependency install | Binary distribution via a SKILL.md file is not supported by the OpenClaw skill format; single-file SKILL.md cannot include executables; creates security surface and update management complexity | Require `revenium` on PATH; document install steps in SKILL.md description or README |
| Multi-budget support (per-project or per-agent) | Power users want fine-grained budget tracking per repository or workflow | Requires tracking multiple anomaly IDs, mapping them to project contexts, and selecting the right one at runtime — far exceeds the scope of a single SKILL.md-based guardrail | Single shared budget per machine matches the "global skill" install model; scoped budgets belong in Revenium's dashboard, not this skill |
| Notification webhooks / email config | Users want to route budget alerts to Slack, PagerDuty, etc. | Revenium already provides built-in email notifications; duplicating this in the skill creates maintenance burden and overlap; the skill's job is agent-side enforcement, not notification routing | Document that Revenium's web dashboard handles notification channels; link users there |
| Real-time streaming budget updates | Users want a live dashboard inside the agent | WebSocket or polling loop is not compatible with the OpenClaw skill model (single SKILL.md, no persistent daemon); would require a separate service outside the skill | Point-in-time check before each operation is architecturally correct for this model |
| Automatic budget increase requests | Agent proactively asks Revenium to raise the budget when exceeded | Defeats the purpose of the guardrail; removes human control over spend decisions | Hard guardrail: always stop and ask the human; the human decides whether to raise the budget in the Revenium dashboard |

---

## Feature Dependencies

```
[API Key Configuration]
    └──requires──> [Budget Alert Creation]
                       └──requires──> [Anomaly ID Persistence]
                                          └──requires──> [Budget Check (pre-operation)]
                                                             └──requires──> [Warn-and-Ask OR Silent Pass-through]

[Idempotent Setup]
    └──requires──> [Anomaly ID Persistence]
    └──requires──> [API Key Configuration]

[Budget Status in Agent Context (differentiator)]
    └──requires──> [Budget Check (pre-operation)]

[List-and-Select Existing Alerts (differentiator)]
    └──requires──> [API Key Configuration]
    └──enhances──> [Budget Alert Creation] (replaces creation with selection when alert exists)

[Grace Mode Toggle (differentiator)]
    └──enhances──> [Warn-and-Ask] (adds configurable response behavior)

[Setup Re-run Command (differentiator)]
    └──requires──> [Anomaly ID Persistence]
    └──conflicts──> [Idempotent Setup] (re-run intentionally bypasses idempotency guard)
```

### Dependency Notes

- **API Key Configuration requires Budget Alert Creation:** The CLI will not accept any command without a valid API key configured; all budget operations are gated on `revenium config set key` completing successfully.
- **Budget Alert Creation requires Anomaly ID Persistence:** The anomaly ID returned from `alerts budget create` is the only handle for subsequent `alerts budget get` calls; without persistence, every session requires re-creating the alert.
- **Anomaly ID Persistence requires Budget Check:** The check is the entire reason for persisting the ID; these features are the same functional unit split across setup and runtime.
- **Setup Re-run conflicts with Idempotent Setup:** Idempotent setup skips creation when an ID is stored; setup re-run must explicitly bypass this check. They require separate code paths / trigger conditions.

---

## MVP Definition

### Launch With (v1)

Minimum viable product — what's needed to validate the core guardrail concept.

- [ ] Binary gating via `requires.bins: [revenium]` — skill won't load without binary; no broken state
- [ ] First-time setup: prompt for API key, configure via `revenium config set key` — credential bootstrap
- [ ] First-time setup: prompt for budget amount + period, create alert via `revenium alerts budget create` — guardrail creation
- [ ] Anomaly ID persistence to config file — enables subsequent checks without re-setup
- [ ] Idempotent setup — safe to re-run; skips creation if already configured
- [ ] Pre-operation budget check via `revenium alerts budget get <anomaly-id>` — the core guardrail loop
- [ ] Warn-and-ask on budget exceeded — human retains control
- [ ] Silent pass-through when budget OK — zero friction during normal operations

### Add After Validation (v1.x)

Features to add once core is working and user feedback confirms demand.

- [ ] Budget status in agent context (current spend vs. threshold in warning message) — add when users report that the "budget exceeded" warning is too abstract to act on
- [ ] Setup re-run command — add when users report friction in updating their configuration
- [ ] List-and-select existing alerts on setup — add when users report duplicate alert creation as a pain point

### Future Consideration (v2+)

Features to defer until product-market fit is established.

- [ ] Grace mode toggle (warn-only vs. hard-stop) — defer until usage data shows split between users who want autonomous override vs. strict control
- [ ] Configurable check granularity (every N ops) — defer until latency complaints from high-frequency users emerge; adds state complexity

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Binary gating (`requires.bins`) | HIGH | LOW | P1 |
| API key setup prompt | HIGH | LOW | P1 |
| Budget amount + period prompt | HIGH | LOW | P1 |
| Budget alert creation | HIGH | LOW | P1 |
| Anomaly ID persistence | HIGH | LOW | P1 |
| Pre-operation budget check | HIGH | MEDIUM | P1 |
| Warn-and-ask on exceeded | HIGH | LOW | P1 |
| Silent pass-through when OK | HIGH | LOW | P1 |
| Idempotent setup | MEDIUM | LOW | P1 |
| Budget status in warning (spend vs. threshold) | MEDIUM | LOW | P2 |
| Setup re-run command | MEDIUM | LOW | P2 |
| List-and-select existing alerts | MEDIUM | MEDIUM | P2 |
| Grace mode toggle | LOW | MEDIUM | P3 |
| Configurable check granularity | LOW | HIGH | P3 |

**Priority key:**
- P1: Must have for launch
- P2: Should have, add when possible
- P3: Nice to have, future consideration

---

## Competitor Feature Analysis

| Feature | Generic cost guardrail tools (e.g., LiteLLM proxy) | Cloud budget alerts (Azure/AWS) | OpenClaw Budget Guardrails skill (Cerebras) | Our Approach |
|---------|-------------------------------|-----------------|----------------------------------------------|--------------|
| Agent-side enforcement | Proxy-level, not agent-aware | No agent integration | Agent-prompt-injected rules | Pre-operation CLI check injected via system prompt |
| Setup automation | Manual config file editing | Web dashboard only | Not specified | Agent-guided interactive setup |
| Binary dependency model | SDK/proxy required | Cloud SDK required | Not applicable | `requires.bins` gating; user installs binary to PATH |
| Human-in-loop on exceeded | Automatic block (no ask) | Email notification only | Not documented | Warn + ask for permission before continuing |
| Persistent alert state | Stateless per-call | Managed by cloud | Not applicable | Anomaly ID stored in skill config file |
| Period-based reset | Per-request only | Monthly budgets | Not documented | DAILY/WEEKLY/MONTHLY/QUARTERLY via Revenium |

---

## Sources

- [OpenClaw Skills Format — official docs](https://docs.openclaw.ai/tools/skills) — `requires.bins`, `requires.env`, frontmatter fields (MEDIUM confidence, verified via WebFetch)
- [Budget Guardrails skill on LobeHub](https://lobehub.com/skills/amnadtaowsoam-cerebraskills-budget-guardrails) — competitor feature reference (LOW confidence, single source)
- [Revenium Cost & Performance Alerts docs](https://docs.revenium.io/cost-and-performance-alerts) — alert types, webhook payload fields (MEDIUM confidence, verified via WebFetch)
- [AI Agent Guardrails: Production Guide for 2026](https://authoritypartners.com/insights/ai-agent-guardrails-production-guide-for-2026/) — industry patterns for budget caps, human-in-loop (LOW confidence, WebSearch)
- [Guardrails for AI Agents — Agno](https://www.agno.com/blog/guardrails-for-ai-agents) — warn-and-ask, pre-action approval patterns (LOW confidence, WebSearch)
- [Essential Framework for AI Agent Guardrails — Galileo](https://galileo.ai/blog/ai-agent-guardrails-framework) — circuit-breaker and token ceiling patterns (LOW confidence, WebSearch)
- [OpenClaw Wikipedia](https://en.wikipedia.org/wiki/OpenClaw) — skill registry size, ClawHub context (LOW confidence, WebSearch)
- PROJECT.md (authoritative) — `revenium` CLI command surface, anomaly ID concept, skill install path, constraints

---
*Feature research for: OpenClaw budget/guardrail skill using revenium-cli*
*Researched: 2026-03-13*
