---
phase: 10-tool-registry-tool-event-metering
plan: "00"
subsystem: testing
tags: [test-scaffolding, tool-registry, tool-event-metering, tdd, red-phase]
dependency_graph:
  requires: []
  provides:
    - tests/test_report_tool_argv.sh (TOOLEV-01..04 argv assertions, RED gate for Plans 01+02)
    - tests/stub-revenium.sh extended with tools+tool-event switches
  affects:
    - plans 01 and 02 (GREEN target: implement until this test passes)
tech_stack:
  added: []
  patterns:
    - Hermetic argv-capture test (mirrors test_guardrail_argv.sh / test_report_jobs_argv.sh)
    - stub-revenium.sh capability probe switch pattern (mirrors STUB_REVENIUM_NO_JOBS)
key_files:
  created:
    - tests/test_report_tool_argv.sh
  modified:
    - tests/stub-revenium.sh
decisions:
  - "count_adjacent awk helper used instead of Python heredoc for adjacent-line counting (avoids ${var} expansion inside <<'PY' single-quoted heredocs)"
  - "ARGV_FILE_T as explicit parameter to argv_vals removes global state risk"
  - "GROUP T / GROUP I / GROUP P structure mirrors test_report_jobs_argv.sh fixture group naming"
metrics:
  duration: "~7 minutes"
  completed: "2026-06-04"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 1
  files_created: 1
---

# Phase 10 Plan 00: Wave 0 Test Scaffolding Summary

Hermetic bash integration test harness covering TOOLEV-01..04 via argv capture, with stub extensions for the `tools`/`meter tool-event` CLI surface — RED against unmodified report.sh, GREEN target for Plans 01 and 02.

## Tasks Completed

| Task | Description | Commit | Files |
|------|-------------|--------|-------|
| 1 | Extend stub-revenium.sh with tools + meter tool-event switches | 69e8bfc | tests/stub-revenium.sh |
| 2 | Create hermetic tool-metering integration test (RED) | 786916e | tests/test_report_tool_argv.sh |

## What Was Built

### Task 1: stub-revenium.sh extensions

Extended the existing argv-capturing revenium stub with three new Phase 10 branches:

- **`tools --help` branch**: exits 0 by default; exits 1 when `STUB_REVENIUM_NO_TOOLS=1` is set (forces `TOOLS_CLI_CAPABLE=false` for fail-open tests). Mirrors the existing `jobs --help` / `STUB_REVENIUM_NO_JOBS` pattern.
- **`meter tool-event --help` branch**: prints `--tool-id string` so the dual probe in report.sh sets `TOOLS_CLI_CAPABLE=true`. Only for the `--help` invocation — real `meter tool-event` calls fall through to the default `exit 0`.
- **`tools create` failure branch**: when `STUB_REVENIUM_TOOLS_FAIL=1`, exits 1 with a non-409 error (`Error: 500 tools service unavailable`). Exercises the fail-open registration path.

Argv capture block preserved first; default `exit 0` preserved last. New switch documentation added to header comment in the same style as existing job switches.

### Task 2: test_report_tool_argv.sh

Created a hermetic integration test structured after `test_guardrail_argv.sh` (primary analog) and `test_report_jobs_argv.sh` (run_report signature):

**Helpers:**
- `make_openclaw_home` — builds tmp home with `revenium-tools.ledger` and `revenium-tool-events.ledger` in addition to the existing ledger files
- `argv_vals <flag> <file>` — extracts values following a flag in the argv capture file
- `count_grep <pattern> <file>` — counts matching lines (consistent with existing tests)
- `count_adjacent <t1> <t2> <file>` — counts adjacent line pairs (for `tools create` and `meter tool-event` pair detection)
- `run_report <home> <argv_file> [key=value...]` — runs report.sh with stub on PATH

**Session fixture** (from RESEARCH.md):
- One `toolCall` (id=`toolu_test001`, name=`read`) at 10:01:05.000Z
- One `toolResult` at 10:01:05.250Z (250ms delta, `isError:false`)
- Produces one TOOL_CALL completion + one CHAT completion

**Test groups:**
- **GROUP T (TOOLEV-01..03)**: Basic tool registry and tool-event assertions
- **GROUP I (TOOLEV-01 registry dedup, TOOLEV-04 event dedup)**: Idempotency across two report.sh ticks
- **GROUP P (TOOLEV-04 fail-open)**: `STUB_REVENIUM_NO_TOOLS=1` → zero tool work, completion unaffected

**RED gate confirmed**: Test runs to completion (no crash), prints `Results: 7 passed, 10 failed`, exits 1. TOOLEV-01 and TOOLEV-02 timing/success assertions all FAIL as expected pre-implementation.

## Verification Results

```
bash -n tests/stub-revenium.sh              → exit 0 (syntax OK)
bash -n tests/test_report_tool_argv.sh      → exit 0 (syntax OK)
bash tests/test_report_tool_argv.sh         → Results: 7 passed, 10 failed; exit 1 (RED)
bash tests/test_report_jobs_argv.sh         → Results: 71 passed, 0 failed; exit 0 (no regression)
bash tests/test_guardrail_argv.sh           → exit 0 (no regression)
```

## Deviations from Plan

None — plan executed exactly as written.

The one structural addition beyond the template: `count_adjacent` helper function (replacing a Python heredoc that would have had shell variable expansion issues inside `<<'PY'` single-quoted heredocs). The awk approach is cleaner, consistent with existing test patterns, and avoids the Bash 3.2 portability concern.

## Known Stubs

None — this plan creates test scaffolding only. No production code stubs exist.

## Threat Flags

None — no new network endpoints, auth paths, or schema changes introduced. Test scaffolding runs fully hermetic under `mktemp -d` with a `trap cleanup EXIT`. No `REVENIUM_API_KEY` is set in the hermetic home (stub replaces the CLI, per T-10-00-02 threat register).

## Self-Check: PASSED

- tests/stub-revenium.sh: FOUND (modified)
- tests/test_report_tool_argv.sh: FOUND (created)
- Commit 69e8bfc: FOUND (Task 1 — stub extension)
- Commit 786916e: FOUND (Task 2 — hermetic test)
