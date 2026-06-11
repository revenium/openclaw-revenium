---
gsd_state_version: 1.0
milestone: v1.4
milestone_name: NemoClaw/OpenShell Support
status: verifying
last_updated: "2026-06-11T01:30:29.364Z"
last_activity: 2026-06-11
progress:
  total_phases: 5
  completed_phases: 5
  total_plans: 18
  completed_plans: 18
  percent: 100
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-06-07 after v1.4 milestone start)

**Core value:** Agents never silently blow through token budgets — every turn is guardrail-checked and the user keeps control past a threshold — and **every cost-incurring activity** (agent completions, guardrail enforcement events, and tool invocations) is metered and attributed by root session, task type, and agentic job, so spend is fully observable in Revenium with no blind spots.
**Current focus:** v1.4 milestone complete — all 5 phases done

## Current Position

Phase: 16 (skill-deploy-docs) — COMPLETE
Plan: 3 of 3 — COMPLETE
Status: v1.4 milestone all plans executed; ready for /gsd-verify-work
Last activity: 2026-06-11

## Performance Metrics

**Velocity:**

- Total plans completed: 40 (v1.0)
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
| 12 | 2 | - | - |
| 13 | 3 | - | - |
| 14 | 3 | - | - |
| 15 | 7 | - | - |

**Recent Trend:**

- Last 5 plans: 01-01 (~5 min)
- Trend: baseline

*Updated after each plan completion*
| Phase 15 P05 | 30 | 1 tasks | 2 files |
| Phase 16 P01 | 8 | 2 tasks | 3 files |
| Phase 16 P02 | 3 | 2 tasks | 2 files |
| Phase 16 P03 | 120 | 2 tasks | 3 files |

## v1.4 Phase Map

| Phase | Name | Requirements | Depends on |
|-------|------|--------------|------------|
| 12 | Parallel Install Scaffolding & Detection | NCINST-01, NCINST-02 | Phase 11 (existing path must not regress) |
| 13 | Sandbox Provisioning — Egress, CLI & Authenticated Metering | NCEGRESS-01, NCCLI-01, NCCLI-02 | Phase 12 |
| 14 | Host-Side Metering Loop | NCMETER-01 | Phase 13 |
| 15 | Per-Turn Enforcement Plugin | NCENF-01, NCENF-02 | Phase 14 |
| 16 | Skill Deploy & Docs | NCDEPLOY-01, NCDEPLOY-02 | Phase 15 |

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

- [v1.4]: Parallel install path only — NemoClaw path gates on Linux+Docker, explicitly refuses macOS; existing standalone path untouched
- [v1.4]: Metering runs host-side over `nemoclaw share mount` — per-tick `exec` rejected (synchronous, hang-prone, accumulated process leaks)
- [v1.4]: Per-turn guardrail directive delivered via OpenClaw `before_prompt_build` plugin — `skill install` + AGENTS.md do not deliver it in-sandbox (spike 005 confirmed)
- [v1.4]: NCENF-01 (`before_prompt_build` plugin) is the highest-risk requirement — must be authored from official `openclaw plugins init` scaffold, not hand-rolled; spike 006 partial (hung turn on hand-stub)
- [v1.1]: Agent-written `kind:"job"` markers (not classifier plugin) — consistent with v1.0 task-type architecture; avoids unconfirmed OpenClaw session-end hook dependency
- [v1.1]: Job tracking is observability-only — per-job-type budget rules deferred; enforcement stays on `AGENT:STARTS_WITH` with server-side job rollup
- [Phase 4]: Task-type correlation by `completion_id` + marker-after fallback (markers land after the completion they classify) — same correlation concern applies to job markers
- [Phase 4]: `AGENT:STARTS_WITH:openclaw-` attribution (D-07) — root-session rollup; job rollup (Phase 7) extends this resolver
- [Phase 11]: `allowConversationAccess: true` required in config to register before_agent_finalize/agent_end hooks (D-05 revised) — SDK silently blocks without it; plugin reads no conversation content
- [Phase 11]: post-install must not auto-restart the gateway — install step documents restart requirement and emits note only (Pitfall 6)
- [Phase ?]: B-01 RESOLVED: Gate A passes live with promptChars=1645 (15-04 fix works on OpenClaw 2026.5.22)
- [Phase ?]: B-05 still failing: Nemotron routes exec through tool_search_code indirect calls; before_tool_call never fires; disk persistence fix is moot on this host
- [Phase 16]: SC1/NCDEPLOY-01 and SC2/NCDEPLOY-02 verified live (Re-run 3, faab3be) — D-02 ready assertion PASSED; zero undocumented install steps; --force idempotency fix shipped; overall install exit-1 is Phase 15 Gate A (B-01/NCENF-01) tracked as follow-up todo

### Roadmap Evolution

- Phases 12–16 added (2026-06-07): v1.4 NemoClaw/OpenShell Support roadmap created. 5 phases consuming all 10 v1.4 requirements. Build basis: 6 spikes proven on live host 34.224.27.67 (sandbox `revenium-spike`). Phase 15 flagged highest-risk (NCENF-01 `before_prompt_build` plugin — mechanism proven but hand-stub hung the turn).
- Phase 11 added (2026-06-05): Structural Marker Enforcement via before_agent_finalize plugin — starts milestone v1.3 Reliable Attribution. Origin: live diagnosis on ClawHub host 98.82.34.123 showed the agent drops the end-of-turn marker gate even with AGENTS.md directives present. Research seed: `.planning/research/marker-enforcement-before-agent-finalize.md`.

### Pending Todos

- [nemoclaw-install-gate-a-exit1] install.sh --nemoclaw overall exit-1 at Phase 15 Gate A (B-01/NCENF-01) on live Nemotron host — medium severity; skill deploy SC1 unaffected; fix requires updating Gate A promptChars check to accept --agent flag or mock path. See `.planning/todos/pending/nemoclaw-install-gate-a-exit1.md`.

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 260327-o1o | Replace DONE session skip with line-offset tracking in report.sh | 2026-03-27 | 7481c0c | [260327-o1o-replace-done-session-skip-with-line-offs](./quick/260327-o1o-replace-done-session-skip-with-line-offs/) |
| 260604-qo0 | Job Outcome Type stuck at PENDING — map SUCCESS arcs to --outcome-type CONVERTED (JOUT-01 slice) | 2026-06-04 | 532e3b7 | [260604-qo0-job-outcome-converted](./quick/260604-qo0-job-outcome-converted/) |
| 260605-enh | Idempotent + uniquely-named Revenium budget rules in setup-guardrails.sh (stop duplicate cost-control rules; REVENIUM_BUDGET_LABEL) | 2026-06-05 | 63043ae | [260605-enh-idempotent-uniquely-named-revenium-budge](./quick/260605-enh-idempotent-uniquely-named-revenium-budge/) |

### Blockers/Concerns

Phase 15 risk: NCENF-01 (`before_prompt_build` guardrail-directive plugin) is the highest-risk requirement. Spike 006 is PARTIAL — mechanism proven viable (nemoclaw plugin reaches every turn), but a hand-stubbed plugin hung the agent turn. Must author from `openclaw plugins init` official scaffold and validate on the live sandbox before merging. Plan this phase carefully.

Standing follow-up carried forward: Phase 9 live guardrail-halt E2E on host 172.16.1.247 (see Deferred Items) — needs a forced halt on the real host to confirm a GUARDRAIL transaction lands in Revenium.

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

Last session: 2026-06-11T01:30:29.359Z
Stopped at: Phase 16 context gathered
Resume file: None

## Operator Next Steps

- Plan Phase 12: `/gsd-plan-phase 12`
