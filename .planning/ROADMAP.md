# Roadmap: Revenium OpenClaw Skill

## Overview

Build a single SKILL.md file that turns every OpenClaw agent on the machine into a budget-aware agent. The work flows in three locked phases: first the skill must load correctly (scaffolding), then the agent must be able to configure its budget (setup flow), then the agent must check that budget before every operation (guard). Each phase is a hard prerequisite for the next — nothing is parallelizable.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Skill Scaffolding** - Valid SKILL.md that loads in OpenClaw and gates on revenium binary (completed 2026-03-14)
- [ ] **Phase 2: Setup Flow** - Agent-guided first-time config of API key, budget, and anomaly ID persistence
- [ ] **Phase 3: Operation Guard** - Pre-operation budget check with warn-and-ask and configurable behavior

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
- [ ] 01-01-PLAN.md — Author SKILL.md with valid frontmatter and body skeleton, install to OpenClaw, verify binary gating

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
**Plans**: TBD

### Phase 3: Operation Guard
**Goal**: The agent checks budget status before every operation, routes to warn-and-ask or silent pass-through based on budget state, and respects user-configured grace mode behavior
**Depends on**: Phase 2
**Requirements**: GUARD-01, GUARD-02, GUARD-03, GUARD-04, GUARD-05, GUARD-06
**Success Criteria** (what must be TRUE):
  1. Agent runs `revenium alerts budget get <anomaly-id>` before every tool call without user prompting
  2. When budget is within threshold, agent proceeds to the operation without any interruption
  3. When budget is exceeded, agent shows current spend vs. threshold (e.g., "$4.80 of $5.00 daily budget used") and asks for permission before continuing
  4. User can set grace mode to hard-stop, causing the agent to refuse to continue when budget is exceeded
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Skill Scaffolding | 1/1 | Complete   | 2026-03-14 |
| 2. Setup Flow | 0/TBD | Not started | - |
| 3. Operation Guard | 0/TBD | Not started | - |
