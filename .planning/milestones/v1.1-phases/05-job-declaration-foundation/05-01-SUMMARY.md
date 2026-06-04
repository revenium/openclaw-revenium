---
phase: 05-job-declaration-foundation
plan: "01"
subsystem: job-taxonomy-foundation
tags: [taxonomy, installer, test-harness, wave-0, red]
dependency_graph:
  requires: []
  provides:
    - job-taxonomy.json with 11-label job vocabulary (JOBDEC-01)
    - JOB_TAXONOMY_FILE constant in common.sh
    - job-taxonomy seeding + write-job-marker.sh chmod in post-install.sh
    - tests/test_write_job_marker.sh Wave 0 RED harness (JOBDEC-01/03/04)
  affects:
    - scripts/common.sh
    - scripts/post-install.sh
tech_stack:
  added: []
  patterns:
    - taxonomy seeding via post-install.sh (mirrors task-taxonomy pattern)
    - JOB_TAXONOMY_FILE constant following STATE_DIR precedent
    - Wave 0 RED test harness (TDD red-green-refactor; green in plan 02)
key_files:
  created:
    - job-taxonomy.json
    - tests/test_write_job_marker.sh
  modified:
    - scripts/common.sh
    - scripts/post-install.sh
decisions:
  - "JOB_TAXONOMY_FILE uses ${STATE_DIR}/job-taxonomy.json path (mirrors TAXONOMY_FILE); install path is collapsed SKILL_DIR==STATE_DIR per OpenClaw model"
  - "Wave 0 RED harness ships in plan 01 before writer exists; plan 02 turns it green"
  - "refactoring (with -ing) is the correct job label, distinct from task-taxonomy's refactor"
metrics:
  duration: "~4 minutes"
  completed: "2026-06-03"
  tasks_completed: 2
  tasks_total: 2
  files_created: 2
  files_modified: 2
---

# Phase 5 Plan 01: Job Taxonomy Foundation Summary

Ship the 11-label job taxonomy JSON, JOB_TAXONOMY_FILE constant in common.sh, taxonomy seeding + write-job-marker.sh chmod in post-install.sh, and the Wave 0 RED integration test harness for the writer.

## What Was Built

### Task 1: job-taxonomy.json + common.sh + post-install.sh wiring (f0d812c)

Created `job-taxonomy.json` at repo root with the 11 snake_case labels ported verbatim from the Hermes skill spec: `feature_development`, `bug_fix`, `code_review`, `refactoring`, `research`, `debugging`, `testing`, `documentation`, `devops`, `planning`, `interrupted`. Shape: `{"labels": {"<label>": {"description", "examples"}}}` — exact match to `task-taxonomy.json` structure.

Modified `scripts/common.sh` to add `JOB_TAXONOMY_FILE="${STATE_DIR}/job-taxonomy.json"` immediately after the `TAXONOMY_FILE` line (line 53), with an updated comment block listing both constants. The existing TAXONOMY_FILE, MARKERS_DIR, SESSIONS_DIR lines are byte-for-byte unchanged.

Modified `scripts/post-install.sh` in two places: (1) added `write-job-marker.sh` to the `for script in ...` chmod loop (Pitfall 4 — permission-denied prevention); (2) added a job-taxonomy seeding block immediately after the task-taxonomy block, mirroring the if/elif/else structure with JOB_TAXONOMY_SRC/DST = `${SKILL_DIR}/job-taxonomy.json` and a warning message naming write-job-marker.sh.

### Task 2: tests/test_write_job_marker.sh Wave 0 RED harness (8c96a5a)

Created `tests/test_write_job_marker.sh` mirroring `tests/test_write_marker.sh` structure (PASS/FAIL counters, mktemp tmp OPENCLAW_HOME tree, fake session JSONL, cleanup trap, `run_job_marker()` helper). Implements all 12 assertions from the JOBDEC-01/03/04 verification map:

1. Valid well-formed call exits 0 and prints `job marker written:`
2. Written record has all 7 mandatory fields (kind/ts/sid/agentic_job_id/job_name/job_type/status), `kind=="job"`, ISO8601 ts
3. markers/ dir mode 0700 (macOS `stat -f "%Lp"` / Linux `stat -c "%a"`)
4. Unknown job_type exits non-zero, no line appended
5. Invalid status value exits non-zero, no line appended
6. Missing mandatory flag exits non-zero
7. Two rapid invocations yield exactly 2 non-corrupt JSON lines (flock + O_APPEND)
8. `failure_reason` present for FAILED, absent for SUCCESS and CANCELLED (D-13)
9. Field with `:` sanitized to `_` (JOBDEC-04)
10. Field with `|` sanitized to `_` (JOBDEC-04)
11. Field with embedded newline does not break JSONL line count
12. Field longer than 300 chars truncated to ≤ 256 chars in written record

Harness is syntactically valid (`bash -n` passes) and is intentionally RED pending the writer (plan 02 turns it green). Wave 0 exit: 5 PASS / 11 FAIL.

## Decisions Made

- **JOB_TAXONOMY_FILE path**: `${STATE_DIR}/job-taxonomy.json` — follows established `TAXONOMY_FILE` precedent; STATE_DIR is the collapsed SKILL_DIR in OpenClaw's model, so the path resolves to `~/.openclaw/skills/revenium/job-taxonomy.json` at runtime.
- **Wave 0 RED harness**: Shipped in plan 01 before the writer exists per the Nyquist Wave 0 rule in 05-VALIDATION.md. This encodes the full testing contract before any implementation.
- **refactoring label**: Kept as-is (Hermes label with -ing); does not normalize to `refactor` which is the task-taxonomy label for a different purpose.
- **12 test assertions**: Added `|`-sanitization (test 10) and newline-sanitization-line-count (test 11) as separate assertions beyond the 10-row table in PATTERNS.md, per the plan task description requiring 12 rows.

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None — this plan ships config and test infrastructure only; no UI or data-rendering components.

## Threat Flags

None — no new network endpoints, auth paths, or schema changes at trust boundaries introduced.

## Self-Check

### Files exist:
- `job-taxonomy.json`: FOUND
- `scripts/common.sh` (modified): FOUND
- `scripts/post-install.sh` (modified): FOUND
- `tests/test_write_job_marker.sh`: FOUND

### Commits exist:
- f0d812c: FOUND (feat(05-01))
- 8c96a5a: FOUND (test(05-01))

## Self-Check: PASSED
