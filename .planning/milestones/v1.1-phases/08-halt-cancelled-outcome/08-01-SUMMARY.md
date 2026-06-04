---
phase: 08-halt-cancelled-outcome
plan: "01"
subsystem: tests
tags: [tdd, halt-handler, job-lifecycle, red-tests, stub, guardrail]
dependency_graph:
  requires:
    - "tests/stub-revenium.sh (Phase 6/7 switches)"
    - "tests/test_report_jobs_argv.sh (GROUP A-H Phase 6/7 baseline)"
    - "scripts/report.sh (current — no halt handler)"
  provides:
    - "STUB_REVENIUM_HALT_JOBS_FAIL switch in tests/stub-revenium.sh"
    - "GROUP I/J/K/L/M halt RED tests in tests/test_report_jobs_argv.sh"
    - "write_halt_fixture helper for guardrail-status.json"
  affects:
    - "scripts/report.sh (Plan 08-02 implements the GREEN path)"
tech_stack:
  added: []
  patterns:
    - "write_halt_fixture: printf/static quoting only — no eval (T-08-01)"
    - "GROUP J sha1: env-passing python3 hashlib.sha1 (not hard-coded hex)"
    - "GROUP M M2: GROUP D exit-code-capture pattern (|| report_rc_m2=$?)"
    - "STUB_REVENIUM_HALT_JOBS_FAIL: printf+grep-qF idiom — no eval (T-08-02)"
key_files:
  created: []
  modified:
    - "tests/stub-revenium.sh"
    - "tests/test_report_jobs_argv.sh"
decisions:
  - "Use env-passing python3 sha1 in GROUP J (not hard-coded hex) so assertion is not stale when implementation changes haltedAt format"
  - "GROUP M M2 uses GROUP D exit-code-capture pattern (not GROUP B || true) to make the exit-0 assertion reachable"
  - "STUB_REVENIUM_HALT_JOBS_FAIL placed after STUB_REVENIUM_JOBS_FAIL in routing block so it only catches halt-specific calls (CANCELLED result or guardrail-halt- prefix)"
  - "write_halt_fixture inlined as shell function using printf/quoting only — avoids eval for JSON construction (T-08-01)"
metrics:
  duration: "~4 minutes"
  completed_date: "2026-06-03"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 2
---

# Phase 8 Plan 01: Halt-Handler RED Tests Summary

RED test scaffolding for the Phase 8 halt handler — five new test groups (I/J/K/L/M) + STUB_REVENIUM_HALT_JOBS_FAIL switch that lock JHALT-01/JHALT-02 behavior into executable assertions before implementation.

## What Was Built

### Task 1: `tests/stub-revenium.sh` — STUB_REVENIUM_HALT_JOBS_FAIL switch

Added one new opt-in switch inside the existing `jobs create`/`jobs outcome` routing block. When `STUB_REVENIUM_HALT_JOBS_FAIL=1` is set, `jobs outcome` and `jobs create` fail with `Error: 500 halt jobs service unavailable` only for halt-driver calls:
- `--agentic-job-id` value containing `guardrail-halt-` prefix (synthetic interrupted job)
- `--result CANCELLED` argument (halt-driven close of a real open job)

Normal per-session calls with regular job ids and SUCCESS/FAILED results pass through unchanged, preserving GROUP A-H invariants.

Detection uses `printf '%s\n' "$@" | grep -qF --` idiom (same pattern as STUB_REVENIUM_409_FOR) — no eval, no string interpolation (T-08-02 mitigated).

### Task 2: `tests/test_report_jobs_argv.sh` — GROUP I-M + write_halt_fixture

Added `write_halt_fixture <openclaw_home> <halted_at>` helper that writes `${home}/skills/revenium/guardrail-status.json` with full halted fields using `printf`/static quoting only (T-08-01 mitigated).

Five new test groups:

| Group | Requirement | Scenario | Key Assertion |
|-------|------------|----------|---------------|
| I | JHALT-01/D-04 | Single open job at halt | `outcome add-auth-9f3c --result CANCELLED` in argv; no synthetic |
| J | JHALT-02/D-05/D-09 | Zero open jobs at halt | `create guardrail-halt-<hex> --type interrupted` + CANCELLED; hex computed via env-passing python3 sha1 |
| K | D-08 | Two open jobs at halt | Both `add-auth-9f3c` and `refactor-api-1b1b` closed CANCELLED; no synthetic |
| L | D-03 | Two runs, same haltedAt | CANCELLED outcome + JOB:halt gate each appear exactly once across both runs |
| M1 | D-10 | JOBS_CLI_CAPABLE=false | Zero halt tokens; report.sh exits 0 |
| M2 | D-10 | STUB_REVENIUM_HALT_JOBS_FAIL=1 | report.sh exits 0; metering intact; JOB:halt gate NOT written on failure |

## Test Results

```
GROUP A-H (Phase 6/7 baseline): 39 PASS, 0 FAIL — invariants preserved
GROUP I-M (Phase 8 halt handler): 14 PASS, 18 FAIL — RED as expected
Total: 53 passed, 18 failed (suite exits non-zero)
```

The 14 GROUP I-M passes are fail-open assertions (M1, M2 sub-cases that test current behavior) and negative-absence checks that correctly pass on the current report.sh. The 18 failures are the positive halt-handler assertions that will turn GREEN when Plan 08-02 lands.

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| 1 | a3fc9ad | test(08-01): extend stub-revenium.sh with STUB_REVENIUM_HALT_JOBS_FAIL switch |
| 2 | 0e6fe11 | test(08-01): add GROUP I-M halt-handler RED tests + guardrail-status.json fixture |

## Deviations from Plan

None — plan executed exactly as written. All acceptance criteria met:
- `grep -c 'STUB_REVENIUM_HALT_JOBS_FAIL' tests/stub-revenium.sh` = 2 (doc comment + routing check)
- New switch lives inside existing `jobs create`/`jobs outcome` routing `if` block
- Detection uses `printf '%s\n' "$@" | grep -qF --` idiom (no eval)
- `bash -n tests/stub-revenium.sh` exits 0
- `bash -n tests/test_report_jobs_argv.sh` exits 0
- `grep -c 'guardrail-halt-' tests/test_report_jobs_argv.sh` = 22 (>= 1)
- `grep -c 'guardrail-status.json' tests/test_report_jobs_argv.sh` = 3 (>= 1)
- GROUP J uses env-passing `python3 ... hashlib.sha1` (not hard-coded literal)
- GROUP M has both STUB_REVENIUM_NO_JOBS (M1) and STUB_REVENIUM_HALT_JOBS_FAIL (M2)
- GROUP M M2 uses `|| report_rc_m2=$?` capture pattern (GROUP D analog)
- GROUP A-H byte-unchanged (53 GROUP A-H assertions all pass)
- Suite is RED on current report.sh (exits 1, 18 failures in GROUP I-M)

## Threat Surface Scan

No new network endpoints, auth paths, file access patterns, or schema changes introduced. This plan modifies test files only. The two threat mitigations from the plan's threat model were applied:
- T-08-01: `write_halt_fixture` builds JSON via `printf`/static quoting — no eval
- T-08-02: `STUB_REVENIUM_HALT_JOBS_FAIL` detection uses `printf+grep-qF` — no eval, no argv interpolation

## Self-Check: PASSED

- tests/stub-revenium.sh: modified, contains STUB_REVENIUM_HALT_JOBS_FAIL (2 occurrences)
- tests/test_report_jobs_argv.sh: modified, contains GROUP I/J/K/L/M
- Commit a3fc9ad: FOUND (test(08-01): extend stub-revenium.sh...)
- Commit 0e6fe11: FOUND (test(08-01): add GROUP I-M halt-handler RED tests...)
- Suite exit code: 1 (RED as expected)
- GROUP A-H: all 39 assertions pass
