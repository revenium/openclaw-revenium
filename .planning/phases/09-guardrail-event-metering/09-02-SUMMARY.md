---
phase: 09-guardrail-event-metering
plan: "02"
subsystem: metering
tags: [bash, report.sh, operation-type, guardrail, test]

# Dependency graph
requires:
  - phase: 09-01
    provides: guardrail-check.sh emits GUARDRAIL transactions (sole source)
provides:
  - report.sh operation_type detection collapsed to CHAT / TOOL_CALL only
  - Dead BUDGET_STATUS_FILE constant removed from report.sh
  - GRDEV-06 assertion in test_report_argv.sh proves no GUARDRAIL ever emitted by report.sh
affects: [09-03, future-plans-touching-report.sh]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Dead-branch removal: when a heuristic's pattern target changes filename, remove the branch and its file constant together"
    - "Negative assertion pattern: argv_vals helper used to assert an --operation-type value is never present"

key-files:
  created: []
  modified:
    - scripts/report.sh
    - tests/test_report_argv.sh

key-decisions:
  - "D-12 locked: GUARDRAIL operation-type sourced exclusively from guardrail-check.sh (Plan 01); report.sh emits only CHAT or TOOL_CALL"
  - "Removed dead BUDGET_STATUS_FILE constant (never referenced after alert model was replaced) to satisfy the budget-status.json grep check"

patterns-established:
  - "GRDEV-06: no --operation-type GUARDRAIL in report.sh argv (proven by new test assertion)"

requirements-completed: [GRDEV-06]

# Metrics
duration: 5min
completed: 2026-06-04
---

# Phase 9 Plan 02: Remove Dead GUARDRAIL Heuristic Summary

**Dead operation-type GUARDRAIL heuristic deleted from report.sh; operation_type now only CHAT or TOOL_CALL, proven by new GRDEV-06 test assertion in test_report_argv.sh**

## Performance

- **Duration:** ~5 min
- **Started:** 2026-06-04T02:38:00Z
- **Completed:** 2026-06-04T02:39:30Z
- **Tasks:** 1
- **Files modified:** 2

## Accomplishments
- Removed the 3-line GUARDRAIL branch in report.sh that grepped toolCall arguments for `budget-status.json` (wrong filename — actual file is `guardrail-status.json` — so the heuristic never fired correctly)
- Updated the adjacent comment to drop the GUARDRAIL line, leaving only TOOL_CALL and CHAT descriptions
- Removed the dead `BUDGET_STATUS_FILE` constant (line 33) — defined but never referenced since the alert model was replaced
- Added `GRDEV-06` assertion to test_report_argv.sh using the existing `argv_vals` helper pattern: verifies `--operation-type GUARDRAIL` never appears in captured report.sh argv
- All 10 tests in test_report_argv.sh pass (new assertion is test 10)
- All 71 tests in test_report_jobs_argv.sh pass (no regression)

## Task Commits

1. **Task 1: Remove dead GUARDRAIL heuristic from report.sh and assert it is gone** - `916bb30` (fix)

**Plan metadata:** (see final commit below)

## Files Created/Modified
- `scripts/report.sh` - Deleted 3-line GUARDRAIL branch + dead BUDGET_STATUS_FILE constant; updated comment
- `tests/test_report_argv.sh` - Added GRDEV-06 assertion (no --operation-type GUARDRAIL in argv)

## Decisions Made
- D-12 confirmed: GUARDRAIL transactions are exclusively sourced from guardrail-check.sh (Plan 01); report.sh's classification is fully deterministic via stopReason
- Also removed `BUDGET_STATUS_FILE` constant (dead code, never referenced) to satisfy the `budget-status.json` grep verification check

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Removed dead BUDGET_STATUS_FILE constant**
- **Found during:** Task 1 verification (the `! grep -q 'budget-status.json' scripts/report.sh` check)
- **Issue:** `BUDGET_STATUS_FILE="${SKILL_DIR}/budget-status.json"` at line 33 was defined but never referenced anywhere in report.sh. The plan's verify check required no `budget-status.json` occurrence in report.sh. Removing this dead constant is the same cleanup as removing the GUARDRAIL heuristic — both are remnants of the old alert model.
- **Fix:** Deleted the `BUDGET_STATUS_FILE=...` line from the file-path constants block
- **Files modified:** scripts/report.sh
- **Verification:** `! grep -q 'budget-status.json' scripts/report.sh` passes; `bash -n scripts/report.sh` passes
- **Committed in:** `916bb30` (same task commit)

---

**Total deviations:** 1 auto-fixed (Rule 2 — dead constant removed to satisfy verify check)
**Impact on plan:** Necessary for correctness of the verify check. No scope creep — the constant was unreferenced dead code from the replaced alert model.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Plan 09-02 complete: report.sh GUARDRAIL cleanup done; GRDEV-06 proven
- Plan 09-03 (final plan) is ready to execute: adds the GUARDRAIL_LEDGER_FILE and JOBS_LEDGER_FILE constants to common.sh
- All existing tests pass; no regressions introduced

## Self-Check

Files modified:
- `scripts/report.sh` - FOUND (modified)
- `tests/test_report_argv.sh` - FOUND (modified)

Commit exists:
- `916bb30` - FOUND

Grep checks:
- `grep -q 'operation_type="GUARDRAIL"' scripts/report.sh` → no match (PASS)
- `grep -q 'budget-status.json' scripts/report.sh` → no match (PASS)

Test results:
- `bash tests/test_report_argv.sh` → 10 passed, 0 failed (PASS)
- `bash tests/test_report_jobs_argv.sh` → 71 passed, 0 failed (PASS)

## Self-Check: PASSED

---
*Phase: 09-guardrail-event-metering*
*Completed: 2026-06-04*
