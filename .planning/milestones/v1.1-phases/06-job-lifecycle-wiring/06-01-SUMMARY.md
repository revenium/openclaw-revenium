---
phase: 06-job-lifecycle-wiring
plan: 01
subsystem: testing
tags: [bash, integration-test, stub, argv-capture, job-lifecycle, hermetic]

requires:
  - phase: 05-job-declaration-foundation
    provides: write-job-marker.sh, kind:"job" marker schema, job-taxonomy.json

provides:
  - tests/stub-revenium.sh extended with STUB_REVENIUM_NO_JOBS, STUB_REVENIUM_409_FOR, STUB_REVENIUM_JOBS_FAIL switches and dual capability-probe responses
  - tests/stub-meta-check.sh self-check script asserting all 10 stub behaviors
  - tests/test_report_jobs_argv.sh RED-gate integration test covering JLIFE-01..05 fixtures (fails against current unwired report.sh; turns green across Plans 02+03)

affects:
  - 06-02 (probe + JOBS_CLI_CAPABLE + ledger file plumbing — turns subset of fixtures green)
  - 06-03 (jobs create/outcome + CR-02/D-12 decoupling — turns remaining fixtures green)

tech-stack:
  added: []
  patterns:
    - "count_grep helper: grep -c with || true + ${r:-0} to avoid double-output bug when no match"
    - "STUB_REVENIUM_NO_JOBS/409_FOR/JOBS_FAIL env-switch pattern for hermetic capability-probe and failure-path testing"
    - "Separate OPENCLAW_HOME per fixture group to prevent ledger cross-contamination"
    - "env-passing python3 json.loads for --metadata JSON assertion (no eval, T-06-02)"

key-files:
  created:
    - tests/stub-meta-check.sh
    - tests/test_report_jobs_argv.sh
  modified:
    - tests/stub-revenium.sh

key-decisions:
  - "Pitfall 4: test_report_argv.sh left untouched and job-free; all Phase 6 job fixtures in new test_report_jobs_argv.sh to preserve the no-agentic-job negative assertion at line 285"
  - "grep -c || echo 0 replaced with count_grep helper to avoid double-output when grep exits 1 on no match"
  - "Separate OPENCLAW_HOME per fixture group so ledgers do not cross-contaminate between SUCCESS/FAILED/CANCELLED runs and decoupling run"

patterns-established:
  - "RED gate commitment: test_report_jobs_argv.sh intentionally fails 17 assertions against unwired report.sh; DO NOT weaken assertions to pass early"
  - "CR-02/D-12 decoupling fixture verifies (a) TX written once, (b) offset advanced, (c) report exits 0, (d) no JOB row on failure — four independent assertions per isolation requirement"

requirements-completed: [JLIFE-01, JLIFE-02, JLIFE-03, JLIFE-04, JLIFE-05]

duration: 8min
completed: 2026-06-03
---

# Phase 6 Plan 01: Job Lifecycle Wiring — Wave 0 Test Scaffolding Summary

**Hermetic RED-gate test `test_report_jobs_argv.sh` covering JLIFE-01..05 with 7 fixture groups (SUCCESS/FAILED/CANCELLED/fail-open/409/CR-02-D-12-decoupling/idempotency), plus extended `stub-revenium.sh` with 3 new env switches and `stub-meta-check.sh` self-check (all 10 stub criteria pass)**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-06-03T19:40:00Z
- **Completed:** 2026-06-03T19:47:31Z
- **Tasks:** 2
- **Files modified:** 3 (1 modified, 2 created in tests/)

## Accomplishments

- Extended `tests/stub-revenium.sh` with dual capability-probe responses (`jobs --help`, `meter completion --help`), `STUB_REVENIUM_NO_JOBS` fail-open switch, `STUB_REVENIUM_409_FOR` 409-conflict fake, and `STUB_REVENIUM_JOBS_FAIL` non-409 jobs-only failure switch (meter completion + config show stay clean). All switches respect the T-06-01 no-eval security constraint.
- Created `tests/stub-meta-check.sh`: 10-assertion self-check script verifying all stub behaviors; exits 0 (10/10 pass).
- Created `tests/test_report_jobs_argv.sh`: hermetic integration test with 7 fixture groups, 28 assertions, ~3.8s runtime. Fails RED (17 of 28 fail because report.sh has no job wiring yet). `test_report_argv.sh` stays 9/9 GREEN (Pitfall 4 preserved). Fixed `grep -c || echo 0` double-output bug by introducing `count_grep` helper.

## Task Commits

1. **Task 1: Extend stub-revenium.sh + add stub-meta-check.sh** - `860109e` (feat)
2. **Task 2: Create test_report_jobs_argv.sh RED gate** - `ef58986` (feat)

## Files Created/Modified

- `tests/stub-revenium.sh` — Extended with capability-probe responses, STUB_REVENIUM_NO_JOBS, STUB_REVENIUM_409_FOR, STUB_REVENIUM_JOBS_FAIL switches; argv-capture block unchanged
- `tests/stub-meta-check.sh` — Self-check script asserting all 10 Task 1 stub behaviors
- `tests/test_report_jobs_argv.sh` — New RED-gate integration test; 7 fixture groups; count_grep helper; no eval; <30s runtime

## Decisions Made

- **Pitfall 4 recorded**: `test_report_argv.sh` left untouched and job-free. All Phase 6 job fixtures live in `test_report_jobs_argv.sh`. Adding job markers to old Sessions A-D would silently break the no-agentic-job assertion at line 285.
- **count_grep helper**: `grep -c ... 2>/dev/null || echo 0` was producing `"0\n0"` when grep exits 1 (no match but file exists) because the `||` path also fires. Replaced with `count_grep` (subshell `; exit 0` pattern, empty → 0 default).
- **Separate OPENCLAW_HOME per group**: prevents ledger cross-contamination between SUCCESS/FAILED/CANCELLED batch run and the CR-02/D-12 decoupling run (which needs pristine empty offsets).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed `grep -c || echo 0` double-output producing `"0\n0"` string**
- **Found during:** Task 2 verification run
- **Issue:** `grep -c "pattern" file 2>/dev/null || echo 0` emits `0\n0` when grep finds no matches (grep exits 1, triggering `|| echo 0`, so both grep's "0" and echo's "0" appear), causing `[[ "0\n0" -eq N ]]` syntax errors
- **Fix:** Added `count_grep` helper function using `$(grep -c ...; exit 0)` subshell + `${r:-0}` default; replaced all 14 `|| echo 0` patterns
- **Files modified:** `tests/test_report_jobs_argv.sh`
- **Committed in:** ef58986 (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 — bug in grep count pattern)
**Impact on plan:** Required fix for test correctness; no scope changes.

## Issues Encountered

None beyond the grep-c bug noted above.

## Known Stubs

None. The test is intentionally RED (17 failing assertions) because report.sh has no job wiring. These are not stubs — they are documented expected failures that turn green across Plans 02 and 03.

## Threat Flags

None. No new network endpoints, auth paths, file access patterns, or schema changes introduced. All new files are test scripts; no production surface added.

## Next Phase Readiness

- Wave 0 complete: the feedback loop is established. Plans 02 and 03 can now be verified turn-green against `test_report_jobs_argv.sh`.
- Plan 02 (probe + JOBS_LEDGER_FILE + stamping) will turn green: JLIFE-04 fail-open (already passing), D-07/D-04 (already passing), plus the probe-based assertions once the probe and stamping land.
- Plan 03 (jobs create/outcome + CR-02/D-12) will turn the remaining 17 red assertions green.
- No blockers.

## Self-Check: PASSED

All committed files verified:
- `tests/stub-revenium.sh` — exists, bash -n passes, 10/10 stub-meta-check assertions pass
- `tests/stub-meta-check.sh` — exists, bash -n passes, exits 0
- `tests/test_report_jobs_argv.sh` — exists, bash -n passes, exits 1 RED (correct), test_report_argv.sh stays GREEN
- Commits 860109e and ef58986 present in git log

---
*Phase: 06-job-lifecycle-wiring*
*Completed: 2026-06-03*
