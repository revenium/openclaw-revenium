---
phase: 17-live-host-fact-finding-spike
plan: "02"
subsystem: infra
tags: [spike, live-host, command-dispatch, determinism, attribution, cross-model, openclaw-2-0]

# Dependency graph
requires:
  - phase: 17-01
    provides: "Both production install paths (standalone OpenClaw+Docker, NemoClaw/OpenShell) live on 52.90.9.242, real credentials provisioned"
provides:
  - "SPIKE-03 binary verdict: NO — mechanism inapplicable to this call shape"
  - "Live-evidenced finding that command-dispatch:tool does not deterministically dispatch on OpenClaw 2026.9.6, for either a human-typed or agent-initiated trigger"
  - "Consequence for downstream planning: ATTR-01 moves to Future Requirements, Phase 21 is deleted, existing marker architecture ports as-is under Phase 20"
affects: [17-06-attr-dispatch-resolution, 20-plugin-2-0-sdk-compliance]

actuals:
  tokens: 8000
  tasks: 3
  commits: 3

tech-stack:
  added: []
  patterns:
    - "Isolated, dedicated OPENCLAW_HOME + Gateway (auth:none, separate port) for live-host probes that need genuine Gateway routing, to avoid state contention with concurrently-running sibling plans on the same shared host (D-13)"
    - "Official openclaw plugins init --type tool scaffold for a minimal single-parameter probe tool, never hand-rolled (per spike 006's lesson)"
    - "Classify live-host dispatch behavior by objective telemetry (promptChars, tool-call count/diversity, wall-clock duration) rather than the model's own narrated claim about whether a mechanism bypassed it"

key-files:
  created:
    - .planning/spikes/010-command-dispatch-tool-verdict/probe-skill/SKILL.md
    - .planning/spikes/010-command-dispatch-tool-verdict/dispatch-run.log
    - .planning/spikes/010-command-dispatch-tool-verdict/README.md
  modified: []

key-decisions:
  - "Classified command-dispatch:tool as SCOPE-NOT-APPLICABLE / NO — mechanism inapplicable to this call shape, based on objective telemetry (promptChars, tool-call diversity, duration) rather than the model's own self-report, after the model repeatedly and confidently narrated claims its own telemetry contradicted."
  - "Declined to run openclaw doctor --fix inside the shared NemoClaw sandbox revenium-2-0 to unblock the Nemotron-pairing Trigger A test, because plan 17-03 was concurrently investigating the exact same openclaw-agent.sqlite store as its own subject matter (T-17-02/D-13 cross-plan perturbation risk). The sandbox pairing's Trigger A result is recorded as attempted-but-blocked, not observed."
  - "Skipped Task 2's cross-model determinism soak entirely (DETERMINISM-TALLY: not-run (scope)) per the plan's scope-NO branch — the scope probe closed SPIKE-03 before any soak-window time was needed."

requirements-completed: []

coverage:
  - id: D1
    description: "Scope probe answers, before any determinism run, whether command-dispatch:tool can be triggered by an agent-initiated action or only a human-typed slash command"
    requirement: SPIKE-03
    verification:
      - kind: manual_procedural
        ref: "dispatch-run.log — five repaired Trigger A/B attempts on the standalone/Claude pairing, each with exact command + trimmed raw output"
        status: pass
    human_judgment: true
    rationale: "The classification rests on interpreting objective telemetry (promptChars, tool-call diversity, duration) against the model's own contradictory self-report — a human should confirm this interpretation is sound, as README.md's Requirements/build guidance section flags explicitly."
  - id: D2
    description: "Cross-model determinism run executed only if the scope probe earned it, per the plan's scope-NO branch"
    requirement: SPIKE-03
    verification:
      - kind: manual_procedural
        ref: "dispatch-run.log — DETERMINISM-TALLY: not-run (scope) with labelled section explaining the deliberate skip"
        status: pass
    human_judgment: false
  - id: D3
    description: "010/README.md carries a strictly binary verdict, its evidence, and the downstream consequence for ATTR-01/Phase 21, consumable by a Phase 20/21 planner without re-reading CONTEXT.md"
    requirement: SPIKE-03
    verification:
      - kind: manual_procedural
        ref: "README.md ## Results — 'NO — mechanism inapplicable to this call shape.' plus the ATTR-01/Phase 21 consequence paragraph"
        status: pass
    human_judgment: true
    rationale: "The binary verdict's correctness depends on the same telemetry-vs-narrative judgment call as D1; a Phase 20/21 planner acting on this verdict should have a human confirm it once before Phase 21 is deleted (D-06's reversibility is explicitly costly)."

duration: 115min
completed: 2026-09-24
status: complete
---

# Phase 17 Plan 02: Command-Dispatch Tool Verdict (SPIKE-03) Summary

**Live-host scope probe closes SPIKE-03 with NO — command-dispatch: tool does not deterministically dispatch on OpenClaw 2026.9.6 for either a human-typed or agent-initiated trigger, so ATTR-01 moves to Future Requirements and Phase 21 is deleted.**

## Performance

- **Duration:** ~115 min
- **Started:** 2026-09-24 (approx, following 17-01's completion)
- **Completed:** 2026-09-24T07:11:46Z
- **Tasks:** 3
- **Files created:** 3

## Accomplishments

- Built and live-tested a throwaway probe skill carrying `command-dispatch: tool` / `command-tool` /
  `command-arg-mode: raw` frontmatter against the standalone/Claude production pairing on
  52.90.9.242, through five progressively-repaired harness iterations (wrong entry point, wrong tool
  semantics, missing single-parameter custom tool, possible sender-authorization gap) plus a control
  test (`/whoami`) that independently confirmed the test harness correctly reaches OpenClaw's real
  command-handling layer
- Discovered that the model's own narrated claims about whether dispatch fired directly contradicted
  the objective telemetry (promptChars, tool-call diversity) in every trigger attempt — established
  telemetry-over-narrative as the correct classification method and documented it as build guidance
- Classified the scope question SCOPE-NOT-APPLICABLE and, per the plan's scope-NO branch, skipped the
  expensive two-model determinism soak entirely (`DETERMINISM-TALLY: not-run (scope)`)
- Wrote `010/README.md` with the binary verdict **NO — mechanism inapplicable to this call shape**
  and its downstream consequence (ATTR-01 → Future Requirements, Phase 21 deleted, marker
  architecture ports as-is under Phase 20 via plan 17-06)
- Attempted the NemoClaw/Nemotron pairing's Trigger A and recorded it as blocked (an
  `AUTH_PROFILE_MIGRATION_REQUIRED` error) rather than perturbing the shared sandbox's SQLite store
  that plan 17-03 was concurrently investigating

## Task Commits

Each task was committed atomically:

1. **Task 1: Scope probe — can `command-dispatch: tool` be triggered by an agent-initiated action at all?** - `60e222b` (feat)
2. **Task 2: Cross-model determinism run — only when the scope probe earned it** - `b0156c2` (docs)
3. **Task 3: Write the SPIKE-03 determination with its binary verdict** - `65664b5` (docs)

**Plan metadata:** committed separately below (SUMMARY.md, this file)

## Files Created/Modified

- `.planning/spikes/010-command-dispatch-tool-verdict/probe-skill/SKILL.md` - Throwaway probe skill carrying the 2.0-era `command-dispatch`/`command-tool`/`command-arg-mode` frontmatter fields, never the production skill
- `.planning/spikes/010-command-dispatch-tool-verdict/dispatch-run.log` - Full evidence trail: precondition check, skill setup, five repaired Trigger A/B attempts, control test, sandbox-pairing attempt, classification, and the deliberate determinism-soak skip
- `.planning/spikes/010-command-dispatch-tool-verdict/README.md` - SPIKE-03 determination: binary verdict, evidence, downstream consequence, build guidance, open follow-up

## Decisions Made

- **Classification method: objective telemetry over model self-report.** Every trigger attempt's
  model-generated narration claimed a specific dispatch outcome (sometimes "it worked," sometimes
  "it didn't"), and those claims were internally inconsistent with each other and with the objective
  telemetry (promptChars, tool-call count and diversity, wall-clock duration) from the same runs.
  Classification is based entirely on telemetry; this is documented as build guidance for any future
  spike probing OpenClaw runtime mechanisms this way.
- **Declined to run `openclaw doctor --fix` on the shared sandbox** to complete the Nemotron-pairing
  Trigger A test, honoring the threat model's T-17-02 no-perturbation requirement against plan
  17-03's concurrent work on the same SQLite store. The standalone-pairing finding is architecturally
  expected to generalize (command-dispatch is documented as a Gateway/core-OpenClaw feature, not
  per-model or per-install-path) but this expectation is explicitly not asserted as an observed fact.
- **Manually relocated a stalled `openclaw plugins install`'s completed install-stage** into
  `extensions/<id>/` after `openclaw update repair` and `openclaw doctor --fix` both failed to clear
  a persistent "package convergence" lock on this host — a mechanical relocation of the installer's
  own fully-built output, not a hand-edit of the plugin itself, recorded in README.md's Open
  follow-up as a live-host operational finding for future phases needing `plugins install` here.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `openclaw plugins install` stalled indefinitely on an internal package-convergence lock**
- **Found during:** Task 1
- **Issue:** After a clean `npm run plugin:build` / `plugin:validate` pass, `openclaw plugins install <path> --force --accept-capabilities --acknowledge-install-policy-warning` never completed — the installer's atomic final-move step waited on "Package convergence must wait until the updating parent releases its install records" indefinitely, even after running `openclaw update repair` and `openclaw doctor --fix` in full.
- **Fix:** Located the installer's own fully-built package sitting complete in its install-stage temp directory and moved it directly into `extensions/probe-append-tool/` — mechanically completing the installer's own last step, not modifying the plugin.
- **Files modified:** none (host-side operational fix only, no repo files touched by this fix)
- **Verification:** Gateway restart log showed `probe-append-tool` in the active plugin list; the tool became callable in subsequent turns.
- **Committed in:** `60e222b` (Task 1 commit) — the fix is host-side, not reflected as a repo diff.

**2. [Rule 1 - Bug] `openclaw agent --local` silently bypasses the Gateway's command-dispatch layer, invalidating the first Trigger A harness**
- **Found during:** Task 1
- **Issue:** The initial Trigger A attempt used `openclaw agent --local`, which the CLI's own `--help` documents as running the embedded agent rather than "via the Gateway" — and `command-dispatch: tool` is a Gateway-side, inbound-message-ingestion feature. This harness could never have exercised the mechanism under test, regardless of the skill's own correctness.
- **Fix:** Switched to genuine Gateway-routed invocation via a dedicated, isolated `OPENCLAW_HOME` and its own `auth: none` Gateway, kept separate from the shared host state plan 17-03 was concurrently using.
- **Files modified:** none (harness/methodology fix, not a repo file)
- **Verification:** `openclaw agent --help` confirms the documented `--local` vs Gateway-routed distinction; the corrected harness's control test (`/whoami`) independently confirmed it reaches the real command layer.
- **Committed in:** `60e222b` (Task 1 commit) — the fix is methodological, reflected in `dispatch-run.log`'s Attempt 1→2 transition, not a repo diff beyond the log itself.

---

**Total deviations:** 2 auto-fixed (1 blocking host-side installer issue, 1 harness-correctness bug). **Impact on plan:** both fixes were necessary to reach a trustworthy Task 1 classification rather than a false negative from a broken probe. No scope creep — neither fix touched the production `SKILL.md` or any file outside this plan's declared `.planning/spikes/010-command-dispatch-tool-verdict/` artifacts.

## Issues Encountered

- **Live-host command latency was consistently high** (individual `openclaw` CLI invocations regularly took 10–50s for config/doctor operations and 90–150+ seconds for full agent turns), which extended Task 1's investigation considerably beyond a simple two-trigger probe. This is a host/runtime characteristic, not a defect in this plan's artifacts, and is noted in README.md's Open follow-up for awareness by future phases operating on this same host.
- **The NemoClaw/Nemotron pairing's Trigger A was not completed** — see Deviations and README.md's Open follow-up for the reasoning (declined to risk perturbing plan 17-03's concurrent sandbox investigation). This is a recorded limitation, not a silently-dropped requirement: the standalone-pairing evidence alone is sufficient for D-06's binary verdict rule, since D-06 already treats any negative result as NO regardless of cross-model comparison.

## Known Stubs

None. All three tasks produced real, live-evidenced artifacts — no placeholder data, no mocked responses. The one intentionally-incomplete cell (NemoClaw/Nemotron Trigger A) is explicitly labeled "BLOCKED, not perturbed" in `dispatch-run.log` and "NOT COMPLETED" in its interpretation, per D-12's requirement that an unrun probe never be indistinguishable from a completed negative.

## User Setup Required

None. This plan used the host-side credential file (`~/.spike-17.env`) already provisioned by plan 17-01's `user_setup`; no new user action required.

## Next Phase Readiness

- SPIKE-03 is answered and consumable from `010/README.md` alone — Phase 20/21 planning can act on the
  NO verdict without re-reading CONTEXT.md.
- **Carry-forward for plan 17-06:** apply D-06's NO-branch consequence mechanically — move ATTR-01 to
  `REQUIREMENTS.md` → `## Future Requirements` → `### Attribution`, delete Phase 21 from the roadmap.
- **Carry-forward for Phase 20:** the existing agent-written-marker architecture (task/job markers via
  `write-marker.sh`/`write-job-marker.sh`) ports as-is; no attribution-mechanism redesign is in scope.
- **Carry-forward for any future live-host phase needing `openclaw plugins install` on 52.90.9.242 or
  its sandbox:** expect the installer's atomic final-move step to potentially stall on a package-
  convergence lock; the manual install-stage relocation documented in this plan's README.md is a
  known workaround, not a guaranteed fix.
- **Carry-forward for any future phase needing the NemoClaw/Nemotron pairing's session-store
  specifically:** it currently reports `AUTH_PROFILE_MIGRATION_REQUIRED` for non-`--local`
  `openclaw agent` invocations; resolving this (via `openclaw doctor --fix` on a freshly-provisioned,
  non-shared sandbox) is a prerequisite for any Gateway-routed testing there.
- No blockers for this phase's remaining plans (03–06), which do not depend on SPIKE-03's outcome
  except 17-06 (which consumes this verdict directly, as intended).

---
*Phase: 17-live-host-fact-finding-spike*
*Plan: 02*
*Completed: 2026-09-24*

## Self-Check: PASSED

All 3 created files verified present on disk (probe-skill/SKILL.md, dispatch-run.log, README.md).
All 3 task commits (60e222b, b0156c2, 65664b5) verified present in `git log`. Plan-level
`<verification>` block re-run: dispatch-run.log contains exactly 1 classification line
(SCOPE-NOT-APPLICABLE) and exactly 1 DETERMINISM-TALLY line; README.md contains exactly 1 bolded
binary verdict sentence and names both ATTR-01 and Phase 21; `git diff --name-only HEAD -- SKILL.md`
is empty (production skill untouched).
