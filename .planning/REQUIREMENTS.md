# Requirements: Revenium OpenClaw Skill

**Defined:** 2026-03-13
**Core Value:** Agents never silently blow through token budgets — every operation is budget-checked, and the user always has control.

## v1 Requirements

### Skill Scaffolding

- [ ] **SKAF-01**: Skill directory exists at `~/.openclaw/skills/revenium/` with a valid `SKILL.md`
- [ ] **SKAF-02**: SKILL.md YAML frontmatter includes `requires.bins: ["revenium"]` to gate on binary availability
- [ ] **SKAF-03**: SKILL.md metadata uses single-line JSON to avoid silent parse failures
- [ ] **SKAF-04**: Skill appears in `openclaw skills list` when `revenium` is on PATH

### Setup Flow

- [ ] **SETUP-01**: Agent prompts user for Revenium API key on first use
- [ ] **SETUP-02**: Agent configures CLI via `revenium config set key <api-key>`
- [ ] **SETUP-03**: Agent prompts user for budget amount (numeric threshold)
- [ ] **SETUP-04**: Agent prompts user for budget period (DAILY, WEEKLY, MONTHLY, QUARTERLY)
- [ ] **SETUP-05**: Agent creates budget alert via `revenium alerts budget create --name <name> --threshold <amount> --period <period>`
- [ ] **SETUP-06**: Agent persists the returned anomaly ID to a config file for subsequent checks
- [ ] **SETUP-07**: Setup is idempotent — skips budget creation if anomaly ID already exists
- [ ] **SETUP-08**: Agent can reconfigure settings (re-run setup) when user requests it

### Budget Guard

- [ ] **GUARD-01**: Agent runs `revenium alerts budget get <anomaly-id> --json` before every operation
- [ ] **GUARD-02**: When budget is not exceeded, agent proceeds silently without user interruption
- [ ] **GUARD-03**: When budget is exceeded, agent warns user with current spend vs threshold context
- [ ] **GUARD-04**: When budget is exceeded, agent asks user for permission before continuing
- [ ] **GUARD-05**: Warning includes actionable budget status (e.g., "$4.80 of $5.00 daily budget used")
- [ ] **GUARD-06**: User can configure grace mode — choose between warn-and-ask (default) or hard-stop behavior

## v2 Requirements

### Enhanced Setup

- **SETUP-09**: Agent lists existing budget alerts and lets user select one instead of creating new
- **SETUP-10**: Configurable check granularity (every N operations) to reduce API call overhead

## Out of Scope

| Feature | Reason |
|---------|--------|
| Token counting/estimation | Revenium handles metering server-side; agent estimates would be inaccurate |
| Bundling revenium-cli binary | SKILL.md format doesn't support bundled executables; user installs to PATH |
| Multi-budget support (per-project/agent) | Complexity exceeds scope of a global skill; use Revenium dashboard for scoping |
| Notification webhooks/email | Revenium platform already provides built-in notifications |
| Auto-raising budget on exceeded | Defeats the guardrail purpose — human must decide |
| Real-time streaming updates | Incompatible with SKILL.md model (no persistent daemon) |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| SKAF-01 | — | Pending |
| SKAF-02 | — | Pending |
| SKAF-03 | — | Pending |
| SKAF-04 | — | Pending |
| SETUP-01 | — | Pending |
| SETUP-02 | — | Pending |
| SETUP-03 | — | Pending |
| SETUP-04 | — | Pending |
| SETUP-05 | — | Pending |
| SETUP-06 | — | Pending |
| SETUP-07 | — | Pending |
| SETUP-08 | — | Pending |
| GUARD-01 | — | Pending |
| GUARD-02 | — | Pending |
| GUARD-03 | — | Pending |
| GUARD-04 | — | Pending |
| GUARD-05 | — | Pending |
| GUARD-06 | — | Pending |

**Coverage:**
- v1 requirements: 18 total
- Mapped to phases: 0
- Unmapped: 18 ⚠️

---
*Requirements defined: 2026-03-13*
*Last updated: 2026-03-13 after initial definition*
