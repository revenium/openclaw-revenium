---
gsd_state_version: 1.0
milestone: v1.4
milestone_name: NemoClaw/OpenShell Support
status: planning
last_updated: "2026-06-07T00:00:00.000Z"
last_activity: 2026-06-07 — Milestone v1.4 started (defining requirements)
progress:
  total_phases: 0
  completed_phases: 0
  total_plans: 0
  completed_plans: 0
  percent: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-06-04 after v1.2 milestone)

**Core value:** Agents never silently blow through token budgets — every turn is guardrail-checked and the user keeps control past a threshold — and **every cost-incurring activity** (agent completions, guardrail enforcement events, and tool invocations) is metered and attributed by root session, task type, and agentic job, so spend is fully observable in Revenium with no blind spots.
**Current focus:** v1.4 NemoClaw/OpenShell Support — defining requirements

## Current Position

Phase: Not started (defining requirements)
Plan: —
Status: Defining requirements
Last activity: 2026-06-07 — Milestone v1.4 started

## Performance Metrics

**Velocity:**

- Total plans completed: 25 (v1.0)
- Average duration: ~5 min
- Total execution time: ~5 min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 1. Skill Scaffolding | 1/1 | ~5 min | ~5 min |
| 02 | 1 | - | - |
| 04 | 4 | - | - |
| 05 | 3 | - | - |
| 06 | 3 | - | - |
| 07 | 2 | - | - |
| 08 | 2 | - | - |
| 09 | 3 | - | - |
| 10 | 3 | - | - |
| 11 | 3 | - | - |

**Recent Trend:**

- Last 5 plans: 01-01 (~5 min)
- Trend: baseline

*Updated after each plan completion*

## v1.1 Phase Map

| Phase | Name | Requirements | Depends on |
|-------|------|--------------|------------|
| 5 | Job Declaration Foundation | JOBDEC-01..04 | Phase 4 |
| 6 | Job Lifecycle Wiring | JLIFE-01..05 | Phase 5 |
| 7 | Root-Session Job Rollup | JROLL-01..03 | Phase 6 |
| 8 | Halt → CANCELLED Outcome | JHALT-01..02 | Phases 6, 7 |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [v1.1]: Agent-written `kind:"job"` markers (not classifier plugin) — consistent with v1.0 task-type architecture; avoids unconfirmed OpenClaw session-end hook dependency
- [v1.1]: Job tracking is observability-only — per-job-type budget rules deferred; enforcement stays on `AGENT:STARTS_WITH` with server-side job rollup
- [Phase 4]: Task-type correlation by `completion_id` + marker-after fallback (markers land after the completion they classify) — same correlation concern applies to job markers
- [Phase 4]: `AGENT:STARTS_WITH:openclaw-` attribution (D-07) — root-session rollup; job rollup (Phase 7) extends this resolver
- [Phase 11]: `allowConversationAccess: true` required in config to register before_agent_finalize/agent_end hooks (D-05 revised) — SDK silently blocks without it; plugin reads no conversation content
- [Phase 11]: post-install must not auto-restart the gateway — install step documents restart requirement and emits note only (Pitfall 6)

### Roadmap Evolution

- Phase 11 added (2026-06-05): Structural Marker Enforcement via before_agent_finalize plugin — starts milestone v1.3 Reliable Attribution. Origin: live diagnosis on ClawHub host 98.82.34.123 showed the agent drops the end-of-turn marker gate even with AGENTS.md directives present. Research seed: `.planning/research/marker-enforcement-before-agent-finalize.md`.

### Pending Todos

None yet.

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 260327-o1o | Replace DONE session skip with line-offset tracking in report.sh | 2026-03-27 | 7481c0c | [260327-o1o-replace-done-session-skip-with-line-offs](./quick/260327-o1o-replace-done-session-skip-with-line-offs/) |
| 260604-qo0 | Job Outcome Type stuck at PENDING — map SUCCESS arcs to --outcome-type CONVERTED (JOUT-01 slice) | 2026-06-04 | 532e3b7 | [260604-qo0-job-outcome-converted](./quick/260604-qo0-job-outcome-converted/) |
| 260605-enh | Idempotent + uniquely-named Revenium budget rules in setup-guardrails.sh (stop duplicate cost-control rules; REVENIUM_BUDGET_LABEL) | 2026-06-05 | 63043ae | [260605-enh-idempotent-uniquely-named-revenium-budge](./quick/260605-enh-idempotent-uniquely-named-revenium-budge/) |

### Blockers/Concerns

None blocking. Standing follow-up carried forward: Phase 9 live guardrail-halt E2E on host 172.16.1.247 (see Deferred Items) — needs a forced halt on the real host to confirm a GUARDRAIL transaction lands in Revenium.

Resolved during v1.1/v1.2 (cleared): Phase 7 marker-race (omit-and-retry shipped), Phase 8 synthetic-interrupted-job halt integration (handle_halt shipped), Phase 4 subagent→root job_id rollup (verified at resolver/unit level).

## Deferred Items

Items acknowledged and deferred at v1.3 milestone close on 2026-06-06:

| Category | Item | Status | Note |
|----------|------|--------|------|
| uat_gap | 11-HUMAN-UAT | accepted | SC-1 numeric coverage record waived by user — gate behavior confirmed working end-to-end on the live ClawHub host; only the before/after verify-markers.sh percentages were lost (terminal history cleared). 0 open scenarios. |
| quick_task | 260327-o1o / 260604-qo0 / 260605-enh | missing (cosmetic) | All three quick tasks are COMPLETE with committed SUMMARYs; flagged only because their SUMMARY frontmatter lacks a `status:` field. No action needed. |
| carry-forward | 09-HUMAN-UAT / 09-VERIFICATION | still open | Phase 9 live guardrail-halt E2E on host 172.16.1.247 — first deferred at v1.2 (below), still validated via production use rather than formal UAT. Re-surfaced at v1.3 close; remains a standing follow-up. |

Items acknowledged and deferred at v1.2 milestone close on 2026-06-04:

| Category | Item | Status | Note |
|----------|------|--------|------|
| uat_gap | 09-HUMAN-UAT | partial | 1 pending scenario: force a live guardrail halt on host 172.16.1.247 and confirm a GUARDRAIL transaction lands in Revenium. Deferred — validated in production use on the test host rather than formal UAT here. |
| verification_gap | 09-VERIFICATION | human_needed | Phase 9 shipped with human_needed verification, gated on the same live halt test; guardrail-event metering is in production use. |

Items acknowledged and deferred at v1.0 milestone close on 2026-06-03:

| Category | Item | Status | Note |
|----------|------|--------|------|
| uat_gap | 04-HUMAN-UAT | RESOLVED 2026-06-03 | Both caveats verified by user: in-skill D-08 legacy notice fires as designed; subagent→root spend rollup confirmed end-to-end. |
| verification_gap | 01-VERIFICATION | human_needed | Phase 1 shipped with human_needed verification; skill scaffolding is in production use. |
| verification_gap | 03-VERIFICATION | human_needed | Phase 3 shipped with human_needed verification; guardrail engine is in production use. |
| quick_task | 260327-o1o-replace-done-session-skip-with-line-offs | missing | Actually COMPLETE (commit 7481c0c). No action needed. |

## Session Continuity

Last session: 2026-06-05T00:00:00.000Z
Stopped at: Phase 11 plan 03 complete — v1.3 milestone complete
Resume file: None

## Operator Next Steps

- Start the next milestone with /gsd-new-milestone
