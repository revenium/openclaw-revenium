---
phase: "07-root-session-job-rollup"
plan: "01"
subsystem: "tests"
tags: [tdd, integration-test, job-rollup, subagent, red-tests]
dependency_graph:
  requires: []
  provides: [JROLL-01-test, JROLL-02-test, JROLL-03-test]
  affects: [tests/test_report_jobs_argv.sh]
tech_stack:
  added: []
  patterns:
    - sessions_spawn inline JSONL fixture for get-root-session-id.py resolver
    - child-via-root UUID constants (ROOT_UUID_X/CHILD_UUID_X naming)
    - count_grep/awk getline negative+positive assertion pattern extended for rollup
key_files:
  modified:
    - tests/test_report_jobs_argv.sh
decisions:
  - Inline sessions_spawn JSONL in test (not external fixture file) to keep each group self-contained — mirrors GROUP A pattern and avoids fixture path coupling
  - ROOT session JSONL includes a completion line so root job create/outcome fires in GROUP F/H (verifies root-only gate behavior is correct RED)
  - GROUP G uses only the child session's orphan marker (no root marker) to represent the race-window scenario cleanly
metrics:
  duration: "~5 min"
  completed: "2026-06-03T21:15:24Z"
  tasks_completed: 2
  files_modified: 1
---

# Phase 7 Plan 01: Wave-0 RED Test Harness for Subagent Job Rollup — Summary

**One-liner:** Three new integration test groups (F/G/H) in `test_report_jobs_argv.sh` with inline `sessions_spawn` fixtures covering all four Phase 7 behavioral cases (inherit/race-omit/orphan-drop/suppress), failing RED until 07-02 ships.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add GROUP F + GROUP G with sessions_spawn fixtures | eb3d655 | tests/test_report_jobs_argv.sh |
| 2 | Add GROUP H (subagent job marker suppression) | babd693 | tests/test_report_jobs_argv.sh |

## What Was Built

Extended `tests/test_report_jobs_argv.sh` with three new test groups:

**GROUP F (JROLL-01 — subagent inherits root's agentic_job_id):**
- Builds a ROOT session JSONL with a `sessions_spawn` tool-result line linking to `CHILD_UUID_F` — required so `get-root-session-id.py` resolves child->root.
- ROOT also has a completion and a `kind:"job"` marker for `root-job-1a2b`.
- CHILD has a completion and its OWN `kind:"job"` marker for `child-job-9z9z`.
- Asserts: child completion ships `--agentic-job-id root-job-1a2b` (not `child-job-9z9z`); `--agentic-job-name`/`--agentic-job-type` carry root values; exactly 1 `^create$` token; 1 `JOB:root-job-1a2b:created:` ledger row.

**GROUP G (JROLL-02 race-omit + D-07 orphan-drop):**
- ROOT session JSONL with `sessions_spawn` link (so child is identified as subagent), but NO root job marker (race window).
- CHILD has an orphan marker `orphan-job-7x7x`.
- Asserts: 0 `--agentic-job-id` tokens; `--agent`/`--task-type` still present; 0 `^create$`/`^outcome$` tokens; child completion IS reported (`TX:comp-child-g001` in ledger).

**GROUP H (JROLL-03 — subagent own job marker suppressed):**
- ROOT session with `sessions_spawn` link + root completion + root marker `root-job-5e6f`.
- CHILD has its own marker `sub-job-3c4d`.
- Asserts: 0 `JOB:sub-job-3c4d:` ledger rows (suppression); 1 `JOB:root-job-5e6f:created:` row; child completion stamps `--agentic-job-id root-job-5e6f` (JROLL-01+03 compatible); `sub-job-3c4d` never leaks into `--agentic-job-id`.

## Verification Results

```
bash -n tests/test_report_jobs_argv.sh  → exits 0 (syntax valid)
bash tests/test_report_jobs_argv.sh     → exits 1 (RED as expected, GROUPS F/G/H fail)
grep -c 'GROUP F' ...                   → 3
grep -c 'GROUP G' ...                   → 3
grep -c 'GROUP H' ...                   → 3
grep -c 'sessions_spawn' ...            → 10 (>= 3 requirement)
grep -c 'agent:main:subagent:' ...      → 4 (>= 3 requirement)
GROUPS A–E pass (35/35 assertions green)
```

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None. This plan is test-only (no production code modified). The FAILing assertions are intentional RED state — they document the gap in `report.sh` that 07-02 will close.

## Threat Flags

None. Test-only changes; no new network endpoints, auth paths, or file access patterns introduced.

## Self-Check: PASSED

- `tests/test_report_jobs_argv.sh` exists and modified: FOUND
- Task 1 commit eb3d655: FOUND
- Task 2 commit babd693: FOUND
- `bash -n tests/test_report_jobs_argv.sh` exits 0: VERIFIED
- `bash tests/test_report_jobs_argv.sh` exits non-zero: VERIFIED (exit code 1)
- GROUPS A-E all print PASS: VERIFIED
- cleanup_all covers TMP_HOME_F, TMP_HOME_G, TMP_HOME_H: VERIFIED
