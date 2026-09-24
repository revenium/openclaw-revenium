---
status: complete
phase: 17-live-host-fact-finding-spike
source: [17-01-SUMMARY.md, 17-02-SUMMARY.md, 17-03-SUMMARY.md, 17-04-SUMMARY.md, 17-05-SUMMARY.md, 17-06-SUMMARY.md]
started: 2026-09-24T17:05:00Z
updated: 2026-09-24T17:20:00Z
---

## Current Test

[testing complete]

## Tests

<!--
  25 deliverables across six SUMMARYs. 16 auto-passed deterministically via their own
  passing `verification` refs (listed under Auto-Covered below) and are NOT presented here.
  The 9 below are `reason: human_judgment` — each is an interpretive call the executing
  plan itself flagged as needing a human. They are NOT defects.
-->

### 1. Revenium egress HTTP 400 classification
source: 17-01-SUMMARY.md (D4)
expected: The HTTP 400 "Missing request parameter: teamId" result — a 4th outcome the plan's three-way signal table (200/403/transport-failure) did not anticipate — is soundly classified as "egress proven, account-scoping incomplete" via CLI exit-code semantics (exit 4 validation vs exit 2 auth), documented in `007/README.md` Finding 7.
result: pass
note: Exit-code semantics are decisive, not interpretive: the CLI's own --help documents exit 4 Validation vs exit 2 Authentication. A dummy key fails at 2; this key reached 4, so egress and auth are proven and only account team-scoping is absent. Recorded as-is, not retried with a guessed team-id.

### 2. Telemetry-over-narrative methodology (SPIKE-03 scope probe)
source: 17-02-SUMMARY.md (D1)
expected: Classifying the scope probe on objective telemetry (promptChars, tool-call diversity, duration) rather than the model's own contradictory self-report is a sound methodology.
result: pass
note: Objective telemetry over model self-report is the correct instinct here — B-05 previously burned this project by trusting a model's account of its own behavior.

### 3. SPIKE-03 binary verdict drives Phase 21 deletion
source: 17-02-SUMMARY.md (D3)
expected: The NO verdict correctly resolves to NO under D-06's binary framing on a single-pairing result — i.e. the sandbox pairing did NOT also need to fail before concluding NO — and is a sound basis for deleting Phase 21 and moving ATTR-01 to Future Requirements. D-06 reversibility is explicitly costly.
result: pass
note: Verdict does not rest on induction from one pairing. It rests on an architectural fact: command-dispatch:tool intercepts inbound Gateway messages beginning with "/" sent as a message's sole content, a path an agent's mid-turn tool-call flow structurally never re-enters, regardless of model. 010/README.md states plainly that NemoClaw Trigger A was never completed and labels the expectation "not an observed fact".

### 4. Sandbox timeout attribution (export-trajectory)
source: 17-03-SUMMARY.md (D3)
expected: The SANDBOX cell's export-trajectory and doctor-inspect timeouts are soundly attributed to the same systemic gateway-lifecycle contention Task 1 found, rather than being a genuine export-trajectory approval-gate finding that is being silently discarded.
result: pass
note: Recorded as EXIT=124 against systemic gateway-lifecycle contention independently confirmed by Task 1, and explicitly marked distinct from an approval-gate result. Labelled NOT RUN / INCONCLUSIVE, not passed — nothing discarded.

### 5. created_via != 'cron' safe to build on
source: 17-03-SUMMARY.md (D4)
expected: Either the structural argument (schema-enforced enum, returns correct ground-truth session) is accepted as sufficient, OR Phase 19 must confirm it against a real cron-scheduled session first. No such session existed on the spike host to verify `created_via` is actually set to `'cron'`.
result: pass
note: Structural argument accepted WITH the open item 008 already carries: created_via is a schema-enforced CHECK enum including 'cron', but no OpenClaw-internal cron session existed to confirm the value is actually written. Phase 19 must confirm this as a first step before relying on the exclusion filter.

### 6. Candidate (a) ranking vs the least-bad-promotion prohibition
source: 17-04-SUMMARY.md (D3)
expected: Treating candidate (a)'s schema-present-but-unexercised parentage columns as a stronger evidentiary position than candidate (c)'s confirmed structural absence — without re-opening the ranking or escalating further — is a legitimate use of the phase's own escalation discretion, NOT a violation of its prohibition against promoting a least-bad candidate.
result: pass
note: Honors the phase's prohibition rather than violating it. fidelity-matrix.md states outright that no candidate clears session parentage with live-confirmed data, ranks only on the three fields where all three candidates have confirmed evidence, and records (c)'s absence as structurally confirmed against OpenClaw 2026.9.6 .d.ts. The bar is recorded unmet, exactly as required.

### 7. 009 and 011 readable cold by a downstream planner
source: 17-05-SUMMARY.md (D3) — the plan's own designated human-check
expected: Read as a Phase 19/20/23 planner who has read nothing else, the hook matrix states which hooks are buildable per pairing, the soak result is per cell rather than averaged, and every claim is re-runnable from the text alone.
result: pass
note: Verified by independent cold read (fresh agent context, read only 009 and 011). Per-pairing attribution unambiguous; soak stated per cell with no averaging. Two re-runnability gaps found and FIXED: Node version was absent from both READMEs and 011 never restated the OpenClaw build — both now carry an explicit versions: frontmatter stamp naming the standalone pairing as the only one captured.

### 8. SPIKE-04 delta is "not cleanly measurable" not a softened FAIL
source: 17-05-SUMMARY.md (D4)
expected: The granularity-mismatch explanation for the 56-vs-18 completions/ground-truth delta justifies recording D-04's "zero missed completions" half as "not cleanly measurable as designed" rather than a straightforward FAIL. Mismatch direction is over-reporting (ground truth undercounts real data), not under-reporting (a lock-contention loss).
result: pass
note: Traced a specific runId: 5 transcript_events rows against one llm_output fire, each with distinct totalTokens — genuinely different completions, not duplicates. SQL read counts per model API call including intermediate tool-decision calls; hook counts per turn. Delta direction is over-reporting by the mechanism under test, not loss. "Not cleanly measurable as designed" is accurate, not a softened FAIL.

### 9. Skill alone suffices to start Phase 19
source: 17-06-SUMMARY.md (D4) — the plan's own designated human-check
expected: A fresh agent invoking `Skill("spike-findings-openclaw-revenium")` reaches all five determinations, can tell which facts are live-verified on which pairing and which are open, and can begin Phase 19 planning without opening `.planning/spikes/` directly.
result: pass
note: Verified by independent cold read (fresh agent invoked the skill and read only what it points to). All five verdicts reachable in one table; Constraints section carries a proper both-pairings caveat. One real defect found and FIXED: the top-level context sentence implied both pairings were validated when only spike 007 reached both — rewritten to state explicitly that 008/009/010/011 are standalone-only and cross-pairing parity was NOT established. Also FIXED: 011's untraceable-runId caveat (join on a structurally-correct key, never a substring scan) was dropped from the synthesis and is now in What to Avoid.

## Auto-Covered (not presented — deterministically verified)

16 deliverables auto-passed via their own passing `verification` refs:

- 17-01: standalone path provisioned idempotently clearing all version floors; one real agent turn completed and read back read-only from the 2.0 SQLite store; NemoClaw path live simultaneously; `provision-2-0-host.sh` proven re-runnable (D-14, zero install actions on second run)
- 17-02: cross-model determinism run correctly executed only per the scope-NO branch
- 17-03: 2.0 session schema captured verbatim per cell, not inferred; candidate (a) graded on all four D-02 fields, both cells
- 17-04: candidate (c) built from sanctioned scaffold and installed with real provenance; graded on all four fields HOST-LOCAL with SANDBOX recorded unrun; `008/README.md` carries both D-03 determinations
- 17-05: hook-observer built and installed with real provenance HOST-LOCAL registering all six D-08 hooks; one shared live-traffic window produced both datasets (62-tick/61-minute soak)
- 17-06: MANIFEST rows 007-011 plus 8 new 2.0 constraints; COVERAGE.md with reasoned no-external-API declaration; skill re-scoped in place; SPIKE-03's NO applied mechanically to ATTR-01

## Summary

total: 9
passed: 9
issues: 0
pending: 0
skipped: 0
blocked: 0

## Gaps

<!-- No gaps. Checks 7 and 9 passed with caveats that were corrected in-session
     rather than deferred; see their notes and the fixes commit. -->

## Fixes applied during UAT

1. `.claude/skills/spike-findings-openclaw-revenium/SKILL.md` — top-level v2.0 context sentence
   rewritten. It read as though both pairings were validated; only spike 007 reached both.
   Now states explicitly that 008/009/010/011 are standalone-only, that cross-pairing parity was
   NOT established, and that B-05 / the SSHFS cell / NEMO-03 remain unrun.
2. `.claude/skills/spike-findings-openclaw-revenium/references/live-host-2-0-facts.md` — added
   011's untraceable-`runId` caveat to `## What to Avoid` (join on a structurally-correct key,
   never a `LIKE` substring scan). It existed in spike 011 but had been dropped from the synthesis.
3. `009/README.md` and `011/README.md` (and their skill mirrors) — added a `versions:` frontmatter
   stamp. Node was absent from both and the OpenClaw build absent from 011, so neither was
   re-runnable from its own text. The stamp also names the standalone pairing as the only one
   these results were captured on.
