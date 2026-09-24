---
phase: 15-per-turn-enforcement-plugin
plan: "07"
subsystem: live-validation
tags: [live-validation, gap-closure, sc3-renegotiation, cr-01, wr-01, b-05, nemoclaw]

# Dependency graph
requires:
  - phase: 15-06
    provides: "CR-01 || true guard, WR-01 markedTaskRuns.has fix, B-05 transcript-scan scanTranscriptForExec"
provides:
  - "Round-3 live re-validation evidence (CR-01, WR-01, B-05) in 15-VALIDATION.md"
  - "Human-reviewed SC3 decision: renegotiate (not PASS)"
  - "SC3 renegotiated in ROADMAP.md: NCENF-02 scoped to direct-exec agents, Nemotron agent/embedded CLI indirection documented as known limitation"
affects: [ROADMAP.md, 15-VALIDATION.md, Phase 16 framing]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "SC3 renegotiation: scope marker enforcement to the runner path that supports lifecycle hooks (gateway sessions vs CLI embedded runner)"

key-files:
  created: []
  modified:
    - .planning/phases/15-per-turn-enforcement-plugin/15-VALIDATION.md
    - .planning/ROADMAP.md

key-decisions:
  - "SC3 renegotiated (not PASS): before_agent_finalize never fires for openclaw agent --json CLI turns (agent/embedded runner skips gateway lifecycle hooks) — end-to-end marker cannot be demonstrated via nemoclaw exec on this host"
  - "NCENF-02 marker revise loop scoped to agents that invoke exec directly (full gateway messaging sessions) — not CLI-driven turns"
  - "Nemotron tool_search_code indirection + agent/embedded runner documented as known structural limitations; no further gap-closure cycle spawned"

patterns-established:
  - "Scope renegotiation: when a lifecycle hook cannot be exercised on the test host due to runner architecture, scope the success criterion to the runner path that does fire the hook — document the limitation honestly"

requirements-completed: [NCENF-01, NCENF-02]

# Metrics
duration: ~20min (continuation executor — Task 3 + SUMMARY only)
completed: 2026-06-10
---

# Phase 15 Plan 07: Live Re-Validation + SC3 Renegotiation Summary

**CR-01 and WR-01 confirmed RESOLVED live; SC3 renegotiated per human approval — NCENF-02 marker revise loop scoped to direct-exec/gateway sessions, Nemotron agent/embedded CLI indirection documented as known limitation in ROADMAP.md**

## Performance

- **Duration:** ~20min (Task 3 + SUMMARY by continuation executor; Task 1 + Task 2 checkpoint by prior executor)
- **Started:** 2026-06-10T16:00:00Z (prior executor Task 1)
- **Completed:** 2026-06-10
- **Tasks:** 3 (Task 1 auto, Task 2 checkpoint, Task 3 auto — SC3 renegotiate branch)
- **Files modified:** 2 (15-VALIDATION.md, ROADMAP.md)

## Accomplishments

- Task 1: Deployed Plan 15-06 fixes to live sandbox 34.224.27.67, gathered round-3 evidence for CR-01 (RESOLVED), WR-01 (RESOLVED), and B-05 (STILL NOT DEMONSTRATED — honest record); appended RE-VALIDATION section to 15-VALIDATION.md
- Task 2: Human reviewed live evidence, confirmed CR-01 + WR-01 resolved, and rendered SC3 decision: "approved: SC3 renegotiate"
- Task 3: Executed SC3 scope-renegotiation in ROADMAP.md — scoped NCENF-02's marker revise loop to agents that invoke exec directly (gateway sessions), documented Nemotron tool_search_code + agent/embedded runner indirection as known limitation, cited 15-VALIDATION.md round-3 evidence; SC1/SC2/SC4/SC5 unchanged

## Task Commits

1. **Task 1: Live re-validation evidence** - `e3ef40f` (docs: round-3 RE-VALIDATION in 15-VALIDATION.md)
2. **Task 2: Human checkpoint** - no commit (blocking checkpoint — human rendered SC3 decision)
3. **Task 3: SC3 scope-renegotiation** - `03b49a7` (docs(15-07): renegotiate SC3 scope per live B-05 limitation)

## Files Created/Modified

- `.planning/phases/15-per-turn-enforcement-plugin/15-VALIDATION.md` — Round-3 RE-VALIDATION addendum: CR-01 diagnostic-on-no-injection + pass-on-injection, WR-01 non-downgrade-across-recover, B-05 structural limitation honest record; sandbox restore commands recorded
- `.planning/ROADMAP.md` — Phase 15 SC3 renegotiated: NCENF-02 scoped to direct-exec agents/gateway sessions, Nemotron `tool_search_code` + `agent/embedded` CLI runner documented as known limitations; SC3 renegotiation note added with date and pointer to 15-VALIDATION.md round-3 evidence

## Decisions Made

**SC3 renegotiated (not PASS):**

The live re-validation confirmed that `before_agent_finalize` does not fire for `openclaw agent --json` CLI turns on this host. The `openclaw agent --json` path uses the `agent/embedded` runner, which skips gateway lifecycle hooks (`before_agent_finalize`, `agent_end`). This was confirmed in the 15-06 schema probe (3 instrumented turns, zero hook firings) and corroborated again in round-3. The transcript-scan fix (`scanTranscriptForExec`, 57/57 unit tests) is correct code but cannot be exercised end-to-end via `nemoclaw exec` CLI turns.

Per the human-approved SC3 renegotiation fallback: NCENF-02's marker revise loop is scoped to agents that invoke exec directly in full gateway messaging sessions (SMS, web UI, channel-mediated turns). CLI-driven `openclaw agent --json` turns using `agent/embedded` runner are a documented known limitation. No further gap-closure cycle will be spawned — the phase closes honestly in this round.

## Deviations from Plan

None — plan executed exactly as written. The Task 3 renegotiate branch ran exactly as specified for the "approved: SC3 renegotiate" human decision outcome. The no-op PASS branch was not triggered.

## Issues Encountered

None in Task 3. Task 1 found that `before_agent_finalize` still does not fire for CLI turns (consistent with 15-06 probe finding) — this routed to the Task 2 SC3 renegotiation checkpoint as designed.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

Phase 15 is complete with SC3 honestly closed via renegotiation:
- SC1 (per-turn directive injection): VERIFIED live — CR-01 resolved, Gate A passes on injection and fails closed with diagnostic on no-injection
- SC2 (halt-honoring under NemoClaw): VERIFIED live — session sc2halted2 evidence (Plan 15-03)
- SC3 (marker attribution): RENEGOTIATED — scoped to direct-exec/gateway sessions; Nemotron tool_search_code + agent/embedded limitation documented
- SC4 (fail-open): STRUCTURALLY EVIDENCED — double try/catch, 57/57 unit tests
- SC5 (scaffold shape): EVIDENCED — configSchema + openclaw.extensions confirmed

Phase 16 (Skill Deploy & Docs) is unblocked. The SC3 renegotiation should inform Phase 16 documentation: the NemoClaw marker-attribution path works for gateway sessions, not CLI-driven embedded-runner turns.

---
*Phase: 15-per-turn-enforcement-plugin*
*Completed: 2026-06-10*

## Self-Check: PASSED

- Task 1 commit `e3ef40f` exists in git log: FOUND
- Task 3 commit `03b49a7` exists in git log: FOUND
- `.planning/phases/15-per-turn-enforcement-plugin/15-VALIDATION.md` exists: FOUND (round-3 section appended)
- `.planning/ROADMAP.md` SC3 renegotiation present: FOUND (grep "SC3" confirmed)
- SC1/SC2/SC4/SC5 unchanged in ROADMAP.md: CONFIRMED (diff shows only SC3 line modified)
- STATE.md not modified: CONFIRMED (no STATE.md changes staged or committed)
