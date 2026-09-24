---
gsd_state_version: 1.0
milestone: v2.0
milestone_name: OpenClaw 2.0 Cut-Over
current_phase: 17
current_phase_name: Live-Host Fact-Finding Spike
status: planning
stopped_at: Phase 17 context gathered
last_updated: "2026-09-24T03:41:27.840Z"
last_activity: 2026-09-23
last_activity_desc: ROADMAP.md created for v2.0 OpenClaw 2.0 Cut-Over (Phases 17–24, 27/27 requirements mapped)
state_head: e51d1da0c43b8b0c448861da66db68652211e073
progress:
  total_phases: 8
  completed_phases: 0
  total_plans: 6
  completed_plans: 0
  percent: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-09-23 — v2.0 milestone started, revised after research)

**Core value:** Agents never silently blow through token budgets — every turn is guardrail-checked and the user keeps control past a threshold — and **every cost-incurring activity** (agent completions, guardrail enforcement events, and tool invocations) is metered and attributed by root session, task type, and agentic job, so spend is fully observable in Revenium with no blind spots.
**Current focus:** Phase 17 — Live-Host Fact-Finding Spike

## Current Position

Phase: 17 (Live-Host Fact-Finding Spike) — READY TO EXECUTE
Plan: — (not yet planned)
Status: Roadmap created, ready to plan
Last activity: 2026-09-23 — ROADMAP.md created for v2.0 OpenClaw 2.0 Cut-Over (Phases 17–24, 27/27 requirements mapped)

Progress: [░░░░░░░░░░] 0%

## Performance Metrics

**Velocity:**

- Total plans completed: 43 (v1.0)
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
| 16 | 3 | - | - |

**Recent Trend:**

- Last 5 plans: 01-01 (~5 min)
- Trend: baseline

*Updated after each plan completion*
| Phase 15 P05 | 30 | 1 tasks | 2 files |
| Phase 16 P01 | 8 | 2 tasks | 3 files |
| Phase 16 P02 | 3 | 2 tasks | 2 files |
| Phase 16 P03 | 120 | 2 tasks | 3 files |

## v2.0 Phase Map

| Phase | Name | Requirements | Depends on |
|-------|------|--------------|------------|
| 17 | Live-Host Fact-Finding Spike | SPIKE-00..04 | Nothing (first phase; continues from Phase 16) |
| 18 | Version Gate & Install Health | GATE-01..04 | Phase 17 |
| 19 | Session Read Path & Root-Session Resolution | READ-01..04, PLUG-04 | Phases 17, 18 |
| 20 | Plugin 2.0 SDK Compliance | PLUG-01, PLUG-02, PLUG-03, PLUG-05 | Phase 17 |
| 21 | Attribution Dispatch Resolution (Contingent) | ATTR-01 (contingent on SPIKE-03 = yes) | Phases 19, 20 |
| 22 | NemoClaw/OpenShell Path on 2.0 | NEMO-01..03 | Phases 19, 20, 21 |
| 23 | Hard HALT & Version Canary Live Validation | HALT-01, CNRY-01..02 | Phases 19, 20, 22 |
| 24 | ClawHub Release & Post-Publish Verification | REL-01..02 | Phases 18, 19, 20, 21, 22, 23 |

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

- [v2.0]: Roadmap created 2026-09-23 — 8 phases (17–24), 27 requirements mapped (26 committed + 1 contingent), 100% coverage. Phase 17 (live-host spike) blocks everything else. Phase 19 (session read path) and Phase 21 (attribution dispatch, contingent on SPIKE-03) are kept in strictly separate phase groups with a green checkpoint between them — avoids the "rewrite-under-migration" pitfall. PLUG-04 (root-session resolution hooks) bundled into Phase 19 since it overlaps the code READ-03 rewrites, not into the attribution phase.
- [v2.0]: Target host for Phase 17: `52.90.9.242` (bare Ubuntu 26.04). The four AWS hosts used through v1.4 are dead and must not be planned against.
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

- Phases 17–24 added (2026-09-23): v2.0 OpenClaw 2.0 Cut-Over roadmap created. 8 phases consuming all 27 v2.0 requirements (26 committed + 1 contingent). Build basis: four independent researchers converged on spike-first, port-second, rewrite-third sequencing (`.planning/research/SUMMARY.md`). Phase 17 flagged as gating every other phase (live-host spike — session read mechanism, per-model hook matrix, command-dispatch:tool verdict). Phase 21 is explicitly contingent on Phase 17's SPIKE-03 finding.
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

Phase 17 is the milestone's critical gate: SPIKE-01 (session read mechanism) is unresolved from documentation alone — an obvious hook fallback (`session_end`) is itself confirmed broken upstream (#155696), and a plausible-sounding `openclaw sessions export` command was researched and found not to exist. No Phase 19+ work should begin before Phase 17 returns written answers.

Standing follow-up carried forward: Phase 9 live guardrail-halt E2E on host 172.16.1.247 (see Deferred Items) — needs a forced halt on the real host to confirm a GUARDRAIL transaction lands in Revenium. (Superseded in intent by v2.0 Phase 23's HALT-01, which re-proves hard HALT on the new 2.0 host.)

## Deferred Items

Items acknowledged and deferred at v1.4 milestone close on 2026-06-13:

| Category | Item | Status | Note |
|----------|------|--------|------|
| uat_gap | 14-HUMAN-UAT | accepted | Phase 14 host-side metering loop — the two human-verification items (live cron tick + GROUP F sshfs message on Linux) were confirmed during v1.4.1 UAT on multiple clean hosts; the metering loop is in production use across NemoClaw + vanilla deployments. 0 open scenarios. |
| todo | 16-review-deferred-findings | open (minor polish) | WR-04 (GROUP I-c exit-code assertion) and IN-03 (`~11 min` doc-timing wording) remain; IN-01 resolved during v1.4.1. Non-blocking docs/test polish. |
| quick_task | 260327-o1o / 260604-qo0 / 260605-enh | missing (cosmetic) | Same three quick tasks flagged at v1.3 close — all COMPLETE with committed work; flagged only because their SUMMARY frontmatter lacks a `status:` field. No action needed. |
| carry-forward | 09-HUMAN-UAT / 09-VERIFICATION | still open | Phase 9 (v1.2) live guardrail-halt E2E on host 172.16.1.247 — validated via production use rather than formal UAT; standing follow-up across milestones. NOT yet validated for v1.4: a real budget-BREACH → hard HALT firing end-to-end on Nemotron. |

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

Last session: 2026-09-24T02:54:17.292Z
Stopped at: Phase 17 context gathered
Resume file: .planning/phases/17-live-host-fact-finding-spike/17-CONTEXT.md

## Operator Next Steps

- Review the v2.0 roadmap (Phases 17–24). Once approved: `/gsd-plan-phase 17` (Live-Host Fact-Finding Spike).
