---
phase: 05-job-declaration-foundation
plan: "03"
subsystem: job-declaration-directive
tags: [job-declaration, skill-md, directive, documentation, green]
dependency_graph:
  requires:
    - scripts/write-job-marker.sh (05-02)
    - job-taxonomy.json (05-01)
    - SKILL.md §TASK CLASSIFICATION (structural model — D-05)
  provides:
    - SKILL.md §JOB DECLARATION directive (JOBDEC-02)
    - references/job-declaration.md operational detail
  affects:
    - SKILL.md (JOB DECLARATION section inserted in guard-first position)
    - references/ (new job-declaration.md)
tech_stack:
  added: []
  patterns:
    - Guard-first SKILL.md ordering (HALT CHECK → Guardrail Check → TASK CLASSIFICATION → JOB DECLARATION → Path Resolution)
    - Arc-boundary trigger model (D-01, not per-turn)
    - Uncertainty-bias-to-CANCELLED status bar (D-02)
    - Pivot-cancel rule (D-03)
    - Soft granularity floor (D-04)
    - kebab-slug+4-hex agentic_job_id format (D-08)
key_files:
  created:
    - references/job-declaration.md
  modified:
    - SKILL.md
decisions:
  - "JOB DECLARATION inserted strictly after TASK CLASSIFICATION and before Path Resolution (Pitfall 6 guard-first ordering — T-05-09 mitigated)"
  - "references/job-declaration.md opens with Operational Detail framing mirroring references/task-classification.md (role-analog)"
  - "SKILL.md directive includes the full 11-label job_type table inline (avoids agent needing to open the reference file just to pick a label)"
  - "failure_reason documented as FAILED-only in both SKILL.md and references/job-declaration.md (D-13)"
metrics:
  duration: "~5 minutes"
  completed: "2026-06-03"
  tasks_completed: 2
  tasks_total: 2
  files_created: 1
  files_modified: 1
---

# Phase 5 Plan 03: JOB DECLARATION Directive Summary

Added the agent-facing JOB DECLARATION directive (JOBDEC-02) to SKILL.md — arc-boundary-triggered section modeled on TASK CLASSIFICATION, plus `references/job-declaration.md` with full operational detail including arc definition, status bar, pivot-cancel rule, and 4 worked examples using the actual `write-job-marker.sh` named-flag invocation.

## What Was Built

### Task 1: Create references/job-declaration.md (489f91b)

Created `references/job-declaration.md` — the operational detail companion to the SKILL.md directive. Content ported and adapted from Hermes `references/job-declaration.md` with OpenClaw-specific divergences.

**Content included:**
- Arc definition: same-arc (same goal including follow-up fixes) vs new-arc (genuine pivot); disambiguation rule
- Trigger: 3 fire conditions + skip-only-when condition (binary, no borderline path)
- Status bar: SUCCESS (positive self-verified evidence), FAILED (narrow definitive-negative + failure_reason), CANCELLED (catch-all + uncertainty-bias default)
- Failure reason section: FAILED-only, correct vs incorrect usage examples
- Pivot-cancel rule: write CANCELLED for abandoned arc first, then begin new arc
- Granularity floor: soft guideline (D-04), no hard enforcement, zero-job sessions legitimate
- 4 worked examples using `bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh` invocation:
  - Example 1: SUCCESS (tests passed), id `add-pagination-endpoint-3b1e`
  - Example 2: CANCELLED (change made, not verified), id `fix-null-pointer-2c4d`
  - Example 3: FAILED with `--failure-reason`, id `fix-ci-upstream-blocker-9f2a`
  - Example 4: Pivot-cancel sequence (CANCELLED for abandoned arc, new arc begins)
- `agentic_job_id` minting guidance (kebab-slug + 4-hex, D-08)
- Confirmation and error handling: `job marker written: <path>` success signal; fail-loud-but-don't-block for errors

### Task 2: Insert JOB DECLARATION directive into SKILL.md (947b069)

Inserted `## JOB DECLARATION` into SKILL.md, strictly after `## TASK CLASSIFICATION` and before `## Path Resolution`, preserving the guard-first ordering contract (T-05-09 mitigation).

**Verification (ordering assertion):**
```
TASK CLASSIFICATION (tc=2554) < JOB DECLARATION (jd=4393) < Path Resolution (pr=8159)
```

**Section structure (10-point checklist from 05-PATTERNS.md, all satisfied):**
1. Section header: `## JOB DECLARATION`
2. Mandatory framing: arc-boundary trigger (not per-turn), D-01/D-04 references
3. `### Trigger (binary — no judgment calls)`: 3 fire conditions + skip-only-when
4. `### Required action`: Step 1 (pick job_type), Step 2 (mint agentic_job_id), Step 3 (call writer)
5. 11-label job_type table: all labels from job-taxonomy.json inline
6. Status bar: SUCCESS/FAILED/CANCELLED with uncertainty-bias-to-CANCELLED (D-02)
7. failure_reason guidance: FAILED-only (D-13)
8. Confirmation/error handling: mirrors write-marker.sh "marker written:" pattern
9. `### Why this matters`: Phase 6 job lifecycle API context
10. Reference to `references/job-declaration.md` for worked examples and pivot-cancel rule

**HALT CHECK, Guardrail Check Procedure, and TASK CLASSIFICATION sections: unchanged (verified by grep)**

## Decisions Made

- **Guard-first ordering enforced by automated assertion**: `python3` ordering check (`tc < jd < pr`) embedded in Task 2 verify step — matches T-05-09 mitigation plan.
- **11-label table included inline in SKILL.md**: Agent picks `job_type` without opening a reference file; removes a common friction point that would cause `unclassified` fallback.
- **SKILL.md directive is self-contained for the common case**: The `references/job-declaration.md` pointer is "for full worked examples and the pivot-cancel rule" — advanced detail, not required for the basic invocation.
- **Synthetic example IDs only**: `add-pagination-endpoint-3b1e`, `fix-null-pointer-2c4d`, `fix-ci-upstream-blocker-9f2a`, `refactor-auth-7a3b` — no real data in directive text (T-05-10 accepted).

## Deviations from Plan

None — plan executed exactly as written. Both tasks produced the artifacts specified, with all verification checks passing.

## Known Stubs

None — both files are pure documentation with no data source wiring required. The SKILL.md directive references `write-job-marker.sh` (shipped in 05-02) and `references/job-declaration.md` (created in Task 1 of this plan). No placeholders.

## Threat Flags

None — this plan creates only markdown documentation files. No new network endpoints, auth paths, file access patterns, or schema changes introduced.

## Self-Check

### Files exist:
- `references/job-declaration.md`: FOUND
- `SKILL.md` (modified): FOUND

### Commits exist:
- 489f91b (docs(05-03)): FOUND
- 947b069 (docs(05-03)): FOUND

## Self-Check: PASSED
