# Roadmap: Revenium OpenClaw Skill

## Milestones

- ✅ **v1.0 Budget Guardrails & Metering** — Phases 1–4 (shipped 2026-06-03)
- ✅ **v1.1 Agentic Job Tracking** — Phases 5–8 (shipped 2026-06-04)
- ✅ **v1.2 Metering Completeness** — Phases 9–10 (shipped 2026-06-04)

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

<details>
<summary>✅ v1.2 Metering Completeness (Phases 9–10) — SHIPPED 2026-06-04</summary>

Full details archived in [`milestones/v1.2-ROADMAP.md`](milestones/v1.2-ROADMAP.md).

- [x] **Phase 9: Guardrail Event Metering** (3/3) — completed 2026-06-04
- [x] **Phase 10: Tool Registry & Tool-Event Metering** (3/3) — completed 2026-06-04

Closed the metering-visibility gaps found while debugging v1.1 in production — guardrail enforcement events and tool usage are now first-class Revenium transactions (`GUARDRAIL` / tool-events), not just `CHAT`/`TOOL_CALL` completions.

Deferred at close: Phase 9 live guardrail-halt UAT/verification on host 172.16.1.247 (see STATE.md → Deferred Items).

</details>

## Progress

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
| 9. Guardrail Event Metering | v1.2 | 3/3 | Complete | 2026-06-04 |
| 10. Tool Registry & Tool-Event Metering | v1.2 | 3/3 | Complete | 2026-06-04 |
