# Roadmap: Revenium OpenClaw Skill

## Milestones

- ✅ **v1.0 Budget Guardrails & Metering** — Phases 1–4 (shipped 2026-06-03)
- ✅ **v1.1 Agentic Job Tracking** — Phases 5–8 (shipped 2026-06-04)
- ✅ **v1.2 Metering Completeness** — Phases 9–10 (shipped 2026-06-04)
- ✅ **v1.3 Reliable Attribution** — Phase 11 (shipped 2026-06-05)

## Phases

### ✅ v1.3 Reliable Attribution (Shipped 2026-06-05)

**Milestone Goal:** Make task/job marker attribution reliable on real installs — markers must not depend on the LLM remembering an end-of-turn directive. Diagnosed live on the ClawHub host (`98.82.34.123`, opus-4-8): the v1.1 AGENTS.md directive is present and in-context, yet the agent drops the end-of-turn `write-marker.sh` gate (~1 of 64 completions marked). The fix is a typed OpenClaw `before_agent_finalize` plugin that forces classification before the agent can yield.

- [x] **Phase 11: Structural Marker Enforcement via before_agent_finalize plugin** (3/3) — completed 2026-06-05

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
| 11. Structural Marker Enforcement | v1.3 | 3/3 | Complete    | 2026-06-05 |

## Phase Details

### Phase 11: Structural Marker Enforcement via before_agent_finalize plugin

**Goal:** Per-turn task classification is structurally enforced, not LLM-compliance-dependent — a typed OpenClaw `before_agent_finalize` plugin (`revenium-marker-gate`) forces the agent to run `write-marker.sh` before it can finalize a substantive turn, bounded (`retry.maxAttempts`) and fail-open (never blocks the reply). Plus a `scripts/verify-markers.sh` diagnostic that makes the completions-vs-markers gap measurable.

**Depends on:** Phase 10. New tech surface (TypeScript OpenClaw plugin) — needs `/gsd-discuss-phase 11` + research before planning.

**Research seed:** [`.planning/research/marker-enforcement-before-agent-finalize.md`](research/marker-enforcement-before-agent-finalize.md) — live diagnosis, the `before_agent_finalize` contract, plugin design, and open questions (plugin home/distribution, task-only vs job gating, `session_end` job-closure, host validation).

**Success Criteria** (what must be TRUE):

  1. A `before_agent_finalize` plugin hook detects that a substantive turn produced no task marker and sends the agent back one bounded pass to run `write-marker.sh` — verified on the ClawHub host (`98.82.34.123`, opus-4-8) raising marked-completion coverage well above the current ~1-in-64 baseline
  2. The gate is **fail-open and bounded**: `retry.maxAttempts` caps the forced passes; if the agent still doesn't classify, the harness finalizes anyway — a hook error or timeout never blocks the user's reply
  3. The plugin reads no conversation content — it observes `exec` tool calls only via the `before_tool_call` hook (not a conversation hook); it sets `allowConversationAccess: true` solely because the SDK requires that flag to register the `before_agent_finalize` + `agent_end` hooks (both are `CONVERSATION_HOOK_NAMES`; without the flag they are silently blocked). `post-install.sh` sets the flag and verifies via `openclaw plugins inspect` that `before_agent_finalize` is registered. The plugin is packaged/installable on a ClawHub host alongside the skill
  4. `scripts/verify-markers.sh` reports, per session, completions vs. markers so the gap is observable before/after
  5. No change to budget-rule logic, `config.json` `ruleIds`, or the `guardrail-status.json` halt/warn contract; existing `report.sh` `unclassified` default + completion_id correlation preserved

**Plans:** 3/3 plans complete

Plans:
- [x] 11-01-PLAN.md — Build the revenium-marker-gate plugin package (source, node:test suite, committed dist/index.js) — SC-1, SC-2, SC-3
- [x] 11-02-PLAN.md — verify-markers.sh per-session completions-vs-markers diagnostic + test; report.sh/guardrail regression — SC-4, SC-5
- [x] 11-03-PLAN.md — post-install.sh idempotent plugin install + enable + inspect; ClawHub host E2E validation — SC-1, SC-2, SC-3 (confirmed on live host)
