---
phase: 10-tool-registry-tool-event-metering
plan: "02"
subsystem: metering
tags: [tool-events, ledger, fail-open, idempotency, argv-array]
dependency_graph:
  requires: ["10-01"]
  provides: ["_meter_tool_event helper", "toolCall scan loop emitting tool-events"]
  affects: ["scripts/report.sh", "tests/test_report_tool_argv.sh"]
tech_stack:
  added: []
  patterns:
    - "grep -qF TOOLEV:<id> ledger dedup gate (mirrors _register_tool / guardrail ledger)"
    - "argv-array discipline for meter tool-event (mirrors post_to_revenium)"
    - "--success explicit flag to avoid CLI default-false (RESEARCH Pitfall 2)"
    - "toolCall scan loop wired AFTER completion metering (TOOLEV-04 sequencing)"
key_files:
  modified:
    - scripts/report.sh
    - tests/test_report_tool_argv.sh
decisions:
  - "Test idempotency assertion uses --duration-ms count (not count_adjacent meter/tool-event) to exclude probe invocations — mirrors test_report_jobs_argv.sh lines 491-493 pattern"
metrics:
  duration: "~10 min"
  completed: "2026-06-04T04:28:32Z"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 2
---

# Phase 10 Plan 02: _meter_tool_event + toolCall Scan Loop Summary

One-liner: `_meter_tool_event` helper plus scan loop wiring turns the Plan 00 target test fully GREEN — one `revenium meter tool-event` per toolCall with explicit --success, 250ms duration, and at-most-once ledger dedup.

## Tasks Completed

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | Add _meter_tool_event helper to report.sh | bea6c1a | scripts/report.sh |
| 2 | Wire toolCall scan loop (_meter_tool_event) + fix idempotency test | e7bccb8 | scripts/report.sh, tests/test_report_tool_argv.sh |

## What Was Built

### Task 1: _meter_tool_event helper

Added `_meter_tool_event()` to `scripts/report.sh` immediately before `post_to_revenium`, adjacent to `_register_tool` (Plan 01). The function:

- **Signature**: `toolcall_id, tool_id, ts, duration_ms, is_error, error_msg, root_sid`
- **Dedup gate**: `grep -qF "TOOLEV:${toolcall_id}" "${TOOL_EVENTS_LEDGER_FILE}"` — fixed-string search, separate from the completion `LEDGER_FILE` (CR-02 isolation per TOOLEV-04)
- **argv-array discipline**: `local ev_cmd=( revenium meter tool-event --tool-id ... )` — no eval, no string interpolation
- **Explicit --success**: `is_error==true` appends `--success=false` + optional `--error-message`; otherwise appends bare `--success` (never omitted — RESEARCH Pitfall 2)
- **ORG_NAME optional flag**: appended only when non-empty
- **Fail-open**: `return 0` on all paths; never touches `failed_count`/`reported_count`; never calls `meter completion` or uses `--operation-type` (TOOLEV-03 isolation)
- **Ledger write on success**: `printf '%s\n' "${ledger_key}" >> "${TOOL_EVENTS_LEDGER_FILE}"`

### Task 2: toolCall scan loop wiring + test assertion fix

Updated the toolCall scan loop inside `process_session` (AFTER the completion `while IFS= read -r line` loop, before `set_offset`) to call `_meter_tool_event` after `_register_tool` for each row extracted by the Python heredoc extractor.

Fixed `test_report_tool_argv.sh` TOOLEV-04 idempotency assertion: replaced `count_adjacent "meter" "tool-event"` (which counts both probe invocations AND real calls) with `count_grep "^--duration-ms$"` (exclusive to real `meter tool-event` posts, never in `--help` probe output). This mirrors the `test_report_jobs_argv.sh` lines 491-493 pattern for probe-awareness.

## Verification Results

```
bash -n scripts/report.sh: SYNTAX OK
bash tests/test_report_tool_argv.sh: 17 passed, 0 failed (was 13 passed, 4 failed)
bash tests/test_report_argv.sh: 10 passed, 0 failed
bash tests/test_report_jobs_argv.sh: 71 passed, 0 failed
bash tests/test_guardrail_argv.sh: 18 passed, 0 failed
```

All TOOLEV-02, TOOLEV-03, TOOLEV-04 assertions now GREEN.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Test assertion counted probe invocations as real calls**

- **Found during**: Task 2 verification — `count_adjacent "meter" "tool-event"` returned 3 instead of 1
- **Issue**: `TOOLS_CLI_CAPABLE` probe (`revenium meter tool-event --help`) writes `meter`, `tool-event`, `--help` to the stub argv file on every cron tick. With 2 ticks (runs 1 and 2), the probe appears twice; the real call appears once; merged count = 3, not 1.
- **Fix**: Changed the assertion to count `--duration-ms` occurrences, which only appears in actual `meter tool-event` posts (not in `--help` probes, not in `meter completion` which uses `--request-duration`).
- **Files modified**: `tests/test_report_tool_argv.sh` lines 305-312
- **Commit**: e7bccb8
- **Precedent**: Identical approach in `test_report_jobs_argv.sh` lines 491-493 for the `meter completion --help` probe.

## Known Stubs

None.

## Threat Flags

None — all new surface (tool-event argv construction, ledger writes, error-message handling) is covered by T-10-02-01 through T-10-02-05 in the plan's threat model and mitigated by argv-array discipline, env-passing Python heredoc, 256-char error truncation, and `grep -qF` fixed-string dedup.

## Self-Check: PASSED

- [x] `scripts/report.sh` exists with `_meter_tool_event()` defined
- [x] Commit bea6c1a exists: `git log --oneline | grep bea6c1a`
- [x] Commit e7bccb8 exists: `git log --oneline | grep e7bccb8`
- [x] All 17 target test assertions pass
- [x] No regressions in the 3 existing test suites (10/71/18 passed, 0 failed each)
