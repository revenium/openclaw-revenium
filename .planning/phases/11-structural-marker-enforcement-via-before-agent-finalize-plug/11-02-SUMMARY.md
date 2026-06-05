---
phase: 11-structural-marker-enforcement-via-before-agent-finalize-plug
plan: "02"
subsystem: verify-markers
tags: [diagnostic, SC-4, SC-5, bash, python-heredoc]
dependency_graph:
  requires: []
  provides: [verify-markers.sh, test_verify_markers.sh]
  affects: []
tech_stack:
  added: []
  patterns:
    - env-passing Python heredoc (same as write-marker.sh)
    - cron-session exclusion via sessions.json agent:main:cron: prefix
    - set -uo pipefail + source common.sh pattern
key_files:
  created:
    - scripts/verify-markers.sh
    - tests/test_verify_markers.sh
  modified: []
decisions:
  - "Output format: tabular stdout-only (no tee, no log file) — interactive diagnostic not a cron stage"
  - "Task-marker counting excludes job markers (kind != 'job') per D-03 — only task classifications counted"
  - "Coverage% = round(markers/completions*100); 0% when completions=0 to avoid division-by-zero"
  - "Sessions sorted alphabetically for deterministic output across runs"
metrics:
  duration: "~4 minutes"
  completed: "2026-06-05"
  tasks_completed: 3
  files_created: 2
  files_modified: 0
---

# Phase 11 Plan 02: verify-markers.sh Diagnostic Summary

verify-markers.sh reads non-cron session JSONL files to count assistant completions and task-type marker records, reports per-session gap + coverage%, and emits a TOTAL summary line — establishing the measurable baseline for the ~1/64 classification gap before the before_agent_finalize plugin lands.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Implement scripts/verify-markers.sh | e3ffaa0 | scripts/verify-markers.sh (created) |
| 2 | Implement tests/test_verify_markers.sh (SC-4) | 22ffd7e | tests/test_verify_markers.sh (created) |
| 3 | Regression-confirm no change to report.sh / guardrail contract (SC-5) | — (no file changes) | — |

## Verification Results

- `bash tests/test_verify_markers.sh`: 16/16 passed
- `bash tests/test_report_argv.sh`: 10/10 passed (SC-5 regression — unchanged)
- `bash tests/test_guardrail_argv.sh`: 18/18 passed (SC-5 regression — unchanged)
- `bash -n scripts/verify-markers.sh`: clean
- `git diff --name-only scripts/report.sh scripts/guardrail-check.sh`: empty (unmodified)

## Output Column Format

```
session_id                                   completions markers   gap coverage%
--------------------------------------------------------------------------------
<uuid>                                                 3       3     0     100%
<uuid>                                                 3       1     2      33%
<uuid>                                                 3       0     3       0%
--------------------------------------------------------------------------------
TOTAL: 9 completions, 4 markers, 5 gap, 44% coverage
```

## Test Fixture Scenarios

| Scenario | Session | Completions | Markers | Expected Gap | Expected Coverage |
|----------|---------|-------------|---------|--------------|-------------------|
| 1 | SID_FULL | 3 | 3 | 0 | 100% |
| 2 | SID_PART | 3 | 1 | 2 | 33% |
| 3 | SID_NONE | 3 | 0 | 3 | 0% |
| 4 (cron) | SID_CRON | 2 | 2 | excluded | excluded |
| 5 (summary) | TOTAL | 9 | 4 | 5 | 44% |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Removed `report.sh` string from comment in verify-markers.sh**
- **Found during:** Task 1 acceptance criteria check
- **Issue:** The automated verify command `! grep -q 'report.sh' scripts/verify-markers.sh` matched a documentation comment mentioning report.sh as the reference for marker reading discipline.
- **Fix:** Replaced comment to describe the restriction without naming report.sh directly.
- **Files modified:** scripts/verify-markers.sh
- **Commit:** e3ffaa0

## Known Stubs

None — verify-markers.sh reads real data from SESSIONS_DIR/MARKERS_DIR; no hardcoded empty values in the production path.

## Self-Check: PASSED

- [x] scripts/verify-markers.sh exists at expected path
- [x] tests/test_verify_markers.sh exists at expected path
- [x] Commit e3ffaa0 exists (Task 1)
- [x] Commit 22ffd7e exists (Task 2)
- [x] scripts/report.sh unmodified
- [x] scripts/guardrail-check.sh unmodified
