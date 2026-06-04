# Roadmap: Revenium OpenClaw Skill

## Overview

Build the skill suite that turns every OpenClaw agent on the machine into a guardrail-enforced, metered agent. The work flows in four locked phases: first the skill must load correctly (scaffolding), then the agent must be able to configure its budget (setup flow), then the core guardrail engine replaces the legacy budget-alert model with first-class guardrail rules (guardrail engine), and finally task-type metering and subagent trace correlation complete the observability picture. Each phase is a hard prerequisite for the next — nothing is parallelizable.

## Phases

**Phase Numbering:**

- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Skill Scaffolding** - Valid SKILL.md that loads in OpenClaw and gates on revenium binary (completed 2026-03-14)
- [x] **Phase 2: Setup Flow** - Agent-guided first-time config of API key, budget, and anomaly ID persistence (completed 2026-05-29)
- [x] **Phase 3: Guardrail Engine** - Replace legacy budget-alert enforcement with guardrails-native rules: common infrastructure, setup-guardrails.sh, guardrail-check.sh, updated SKILL.md and cron pipeline (completed 2026-05-31)
- [x] **Phase 4: Task Metering & Attribution** - Task-type taxonomy, mandatory TASK CLASSIFICATION in SKILL.md, --task-type on every meter completion, and subagent trace correlation via root session ID (completed 2026-06-03)

## Phase Details

### Phase 1: Skill Scaffolding

**Goal**: A valid SKILL.md exists at `~/.openclaw/skills/revenium/` that correctly loads when `revenium` is on PATH and is silently absent when it is not
**Depends on**: Nothing (first phase)
**Requirements**: SKAF-01, SKAF-02, SKAF-03, SKAF-04
**Success Criteria** (what must be TRUE):

  1. Running `openclaw skills list` shows the revenium skill when `revenium` is on PATH
  2. The skill does not appear in `openclaw skills list` when `revenium` is removed from PATH
  3. SKILL.md YAML frontmatter parses without error (no silent drop due to colon-space or multi-line metadata)
  4. The skill directory exists at `~/.openclaw/skills/revenium/SKILL.md`

**Plans:** 1/1 plans complete

Plans:

- [x] 01-01-PLAN.md — Author SKILL.md with valid frontmatter and body skeleton, install to OpenClaw, verify binary gating

### Phase 2: Setup Flow

**Goal**: An agent following the skill instructions can configure the Revenium API key, create a budget alert, and persist the anomaly ID — with idempotent re-run behavior
**Depends on**: Phase 1
**Requirements**: SETUP-01, SETUP-02, SETUP-03, SETUP-04, SETUP-05, SETUP-06, SETUP-07, SETUP-08
**Success Criteria** (what must be TRUE):

  1. On first use, agent prompts for API key and configures `revenium-cli` via `revenium config set key`
  2. Agent prompts for budget amount and period, then creates a budget alert via `revenium alerts budget create`
  3. The anomaly ID returned from alert creation is written to `{baseDir}/config.json`
  4. Re-running setup with an existing `config.json` skips budget creation instead of creating a duplicate alert
  5. User can explicitly request re-configuration and the agent re-runs setup from scratch

**Plans:** 1/1 plans complete

Plans:

- [x] 02-01-PLAN.md — Author Setup and /revenium Command sections with complete agent instructions for configuration, idempotency, and reconfiguration

### Phase 3: Guardrail Engine

**Goal**: Replace the legacy budget-alert model with guardrails-native enforcement: `common.sh` shared helpers, `setup-guardrails.sh` interactive rule creation, `guardrail-check.sh` cron stage, updated `cron.sh` pipeline (no migration code, per D-02), rewritten SKILL.md enforcement section (guardrail-status.json schema, halt logic, setup flow delegation), and updated `BUDGET-GUARD.md` workspace bootstrap file (filename unchanged, per D-05)
**Depends on**: Phase 2
**Requirements**: GUARD-01, GUARD-02, GUARD-03, GUARD-04, GUARD-05, GUARD-06
**Success Criteria** (what must be TRUE):

  1. `setup-guardrails.sh --interactive` creates at least one guardrails budget rule via `revenium guardrails budget-rules create` and writes `ruleIds` array to `config.json`
  2. `guardrail-check.sh` polls `revenium guardrails enforcement-rules get` and writes `guardrail-status.json` atomically on every cron tick
  3. When any non-shadow rule is in `block` state and autonomous mode is on, `guardrail-status.json` sets `halted: true` and the agent emits the verbatim halt string
  4. Legacy `alertId`-only installs are treated as "setup not complete" (run Setup Flow); `guardrail-check.sh` exits 0 silently on such installs (no auto-migration, per D-02/D-03/D-04)
  5. SKILL.md reads `guardrail-status.json` (not `budget-status.json`) and the halt check uses `haltedRule` fields
  6. `BUDGET-GUARD.md` is injected via `bootstrap-extra-files` and references `guardrail-status.json`

**Plans:** 8/8 plans complete
Plans:
**Wave 1**

- [x] 03-01-PLAN.md — Upgrade OpenClaw CLI + author common.sh shared library

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 03-02-PLAN.md — Author guardrail-check.sh cron enforcement stage (writes guardrail-status.json)
- [x] 03-03-PLAN.md — Author setup-guardrails.sh interactive rule creation

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 03-04-PLAN.md — Wire cron.sh/post-install.sh/clear-halt.sh; delete budget-check.sh
- [x] 03-05-PLAN.md — Rewrite SKILL.md + BUDGET-GUARD.md guardrail-native enforcement

**Gap Closure** *(closes GUARD-03/GUARD-04 warn-and-ask gap + CR-01/CR-02 from review)*

- [x] 03-06-PLAN.md — guardrail-check.sh: emit warned/warnedRules signal (GUARD-03/04 producer) + CR-02 fail-open guard
- [x] 03-07-PLAN.md — SKILL.md warn-and-ask branch (GUARD-03/04 consumer) + setup-guardrails.sh clear ruleIds on recreate (CR-01)
- [x] 03-08-PLAN.md — Per-turn warn wiring: post-install.sh AGENTS.md injection + BUDGET-GUARD.md learn warned:true → warn-and-ask (GUARD-03/04 always-on surface); README budget-status.json doc drift fix

### Phase 4: Task Metering & Attribution

**Goal**: Every meter completion carries a `--task-type` from the controlled taxonomy; SKILL.md mandates task classification before every substantive turn; subagent spend rolls up under the root session via `AGENT:STARTS_WITH:openclaw-{root_session_id}` naming; setup offers optional per-task-type guardrail rules
**Depends on**: Phase 3
**Requirements**: METER-01, METER-02, METER-03, TRACE-01, TRACE-02
**Success Criteria** (what must be TRUE):

  1. `task-taxonomy.json` exists at `~/.openclaw/skills/revenium/task-taxonomy.json` with the standard 8-label vocabulary (research, analysis, generation, review, code_review, refactor, planning, debugging)
  2. SKILL.md contains a mandatory TASK CLASSIFICATION section that fires before every substantive turn and writes a per-session task marker
  3. `report.sh` reads the task marker and passes `--task-type <label>` on every `revenium meter completion` call (defaulting to `unclassified` when no marker is present)
  4. `report.sh` resolves the root session ID and passes `--agent "openclaw-{root_session_id}"` so subagent spend aggregates correctly in Revenium
  5. `setup-guardrails.sh --interactive` offers optional per-task-type budget rules drawn from `task-taxonomy.json`

**Plans:** 4/4 plans complete

Plans:

**Wave 1**

- [x] 04-01-PLAN.md — Foundation: task-taxonomy.json + common.sh constants/resolver wrapper + get-root-session-id.py + test harness
**Wave 2** *(blocked on Wave 1)*

- [x] 04-02-PLAN.md — write-marker.sh + report.sh task-type correlation and --agent/--task-type wiring
- [x] 04-03-PLAN.md — setup-guardrails.sh STARTS_WITH base filter + per-task-type budget-rule picker
**Wave 3** *(blocked on Waves 1-2)*

- [x] 04-04-PLAN.md — SKILL.md TASK CLASSIFICATION + legacy notice; cron.sh marker prune; post-install wiring

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Skill Scaffolding | 1/1 | Complete    | 2026-03-14 |
| 2. Setup Flow | 1/1 | Complete    | 2026-05-29 |
| 3. Guardrail Engine | 8/8 | Complete   | 2026-05-31 |
| 4. Task Metering & Attribution | 4/4 | Complete    | 2026-06-03 |
