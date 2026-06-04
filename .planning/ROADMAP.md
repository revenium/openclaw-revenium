# Roadmap: Revenium OpenClaw Skill

## Milestones

- ✅ **v1.0 Budget Guardrails & Metering** — Phases 1–4 (shipped 2026-06-03)
- ✅ **v1.1 Agentic Job Tracking** — Phases 5–8 (shipped 2026-06-04)
- 🚧 **v1.2 Metering Completeness** — Phases 9–10 (in progress)

## Phases

<details>
<summary>✅ v1.0 Budget Guardrails & Metering (Phases 1–4) — SHIPPED 2026-06-03</summary>

Full details archived in [`milestones/v1.0-ROADMAP.md`](milestones/v1.0-ROADMAP.md).

- [x] **Phase 1: Skill Scaffolding** (1/1) — completed 2026-03-14
- [x] **Phase 2: Setup Flow** (1/1) — completed 2026-05-29
- [x] **Phase 3: Guardrail Engine** (8/8) — completed 2026-05-31
- [x] **Phase 4: Task Metering & Attribution** (4/4) — completed 2026-06-03

</details>

<details>
<summary>✅ v1.1 Agentic Job Tracking (Phases 5–8) — SHIPPED 2026-06-04</summary>

Full details archived in [`milestones/v1.1-ROADMAP.md`](milestones/v1.1-ROADMAP.md).

- [x] **Phase 5: Job Declaration Foundation** (3/3) — completed 2026-06-03
- [x] **Phase 6: Job Lifecycle Wiring** (3/3) — completed 2026-06-03
- [x] **Phase 7: Root-Session Job Rollup** (2/2) — completed 2026-06-03
- [x] **Phase 8: Halt → CANCELLED Outcome** (2/2) — completed 2026-06-03

Post-ship fix: the agent-written-marker pipeline never fired in production (OpenClaw loads SKILL.md on-demand) — fixed by injecting completion-gate directives into AGENTS.md via post-install.sh; validated end-to-end.

</details>

### 🚧 v1.2 Metering Completeness (In Progress)

**Milestone Goal:** Close the metering-visibility gaps found while debugging v1.1 in production — make guardrail enforcement and tool usage observable as first-class Revenium transactions, not just Chat/Tool Call completions. (Revenium renders a completion's `operationType` as the transaction type: CHAT→Chat, TOOL_CALL→Tool Call, GUARDRAIL→Guardrail.)

- [x] **Phase 9: Guardrail Event Metering** — emit a GUARDRAIL transaction on each halt / warn / shadow enforcement transition, deduped + fail-open (completed 2026-06-04)
- [ ] **Phase 10: Tool Registry & Tool-Event Metering** — register tools and meter tool invocations in Revenium (planned)

## Phase Details

### Phase 9: Guardrail Event Metering

**Goal**: Every guardrail enforcement event — a halt, a warn, or a shadow-mode would-have-halted — surfaces in Revenium as a discrete `GUARDRAIL` transaction, emitted once per event and never at the expense of enforcement.
**Depends on**: Phase 3 (guardrail-check.sh enforcement state + transitions), Phase 6/7 (agent + agentic-job attribution), v1.1 AGENTS.md wiring.
**Requirements**: GRDEV-01, GRDEV-02, GRDEV-03, GRDEV-04, GRDEV-05, GRDEV-06
**Success Criteria** (what must be TRUE):

  1. A guardrail **halt** produces exactly one `GUARDRAIL` transaction in Revenium (`--operation-type GUARDRAIL --task-type budget_guardrail_halt`), deduped so repeated cron ticks during the same halt never re-emit (GRDEV-01)
  2. A guardrail **warn** produces exactly one `GUARDRAIL` transaction per warn onset — transition-gated, not one per tick while warned (GRDEV-02)
  3. A **shadow** would-have-halted produces exactly one `GUARDRAIL` transaction per breach (GRDEV-03)
  4. Each guardrail transaction is attributed to the agent (root session) and carries the open `--agentic-job-id` when a job is in progress (GRDEV-04)
  5. Guardrail-event metering is fully fail-open — a metering error never blocks the status write, halt/warn/shadow notification, or cron tick — and `report.sh` no longer emits the dead operation-type `GUARDRAIL` heuristic (GRDEV-05, GRDEV-06)

**Plans:** 3/3 plans complete
Plans:

- [x] 09-00-PLAN.md — Wave 0: test scaffolding (tests/test_guardrail_argv.sh, stub-revenium.sh guardrails switch) + resolve live meter-completion CLI questions
- [x] 09-01-PLAN.md — Core metering: common.sh ledger constants, warn-onset detection, Section M _emit_guardrail_event (halt/warn/shadow), attribution + dedup, fail-open
- [x] 09-02-PLAN.md — Remove dead report.sh GUARDRAIL heuristic (D-12 / GRDEV-06) + test assertion

### Phase 10: Tool Registry & Tool-Event Metering

**Goal**: Agent tool usage is observable in Revenium — tools are registered and invocations are metered — without double-counting the completions already metered as `TOOL_CALL`.
**Depends on**: Phase 9 (sequential; shares the report.sh/metering surface). **Needs `/gsd-discuss-phase 10` + spec before planning** (`meter tool-event` was out-of-scope in v1.1; open design questions on double-counting, what to register, per-call vs one-time).
**Requirements**: TOOLEV-01, TOOLEV-02, TOOLEV-03, TOOLEV-04
**Success Criteria** (what must be TRUE):

  1. Agent tools are registered in Revenium via `revenium tools create` (TOOLEV-01)
  2. Tool invocations appear in Revenium as tool-events via `revenium meter tool-event` (TOOLEV-02)
  3. Tool-event metering does not double-count against existing `TOOL_CALL` completions (TOOLEV-03)
  4. Tool registry + tool-event work is fail-open and idempotency-gated against duplicate registrations/events (TOOLEV-04)

**Plans:** 2/3 plans executed
**Wave 1**

- [x] 10-00-PLAN.md — Wave 0 test scaffolding: tests/test_report_tool_argv.sh (TOOLEV-01..04 argv assertions) + stub-revenium.sh tools/tool-event switches (RED gate)

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 10-01-PLAN.md — Registry foundation: common.sh tool ledger constants, TOOLS_CLI_CAPABLE probe, normalize_tool_id/classify_tool_type, _register_tool create-once (TOOLEV-01/04)

**Wave 3** *(blocked on Wave 2 completion)*

- [ ] 10-02-PLAN.md — Tool-event emission: _meter_tool_event + toolCall scan loop in process_session, explicit --success, no double-count, fail-open (TOOLEV-02/03/04)

## Progress

**Execution Order:** Phases execute in numeric order: 9 → 10

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Skill Scaffolding | v1.0 | 1/1 | Complete | 2026-03-14 |
| 2. Setup Flow | v1.0 | 1/1 | Complete | 2026-05-29 |
| 3. Guardrail Engine | v1.0 | 8/8 | Complete | 2026-05-31 |
| 4. Task Metering & Attribution | v1.0 | 4/4 | Complete | 2026-06-03 |
| 5. Job Declaration Foundation | v1.1 | 3/3 | Complete | 2026-06-03 |
| 6. Job Lifecycle Wiring | v1.1 | 3/3 | Complete | 2026-06-03 |
| 7. Root-Session Job Rollup | v1.1 | 2/2 | Complete | 2026-06-03 |
| 8. Halt → CANCELLED Outcome | v1.1 | 2/2 | Complete | 2026-06-03 |
| 9. Guardrail Event Metering | v1.2 | 3/3 | Complete    | 2026-06-04 |
| 10. Tool Registry & Tool-Event Metering | v1.2 | 2/3 | In Progress|  |
