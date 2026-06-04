---
phase: 10-tool-registry-tool-event-metering
plan: "01"
subsystem: report.sh
tags: [tool-registry, ledger, capability-probe, idempotency, fail-open, TOOLEV-01, TOOLEV-04]
requirements: [TOOLEV-01, TOOLEV-04]

dependency_graph:
  requires:
    - "10-00: test scaffold (test_report_tool_argv.sh + stub-revenium.sh extensions)"
  provides:
    - "TOOL_REGISTRY_LEDGER_FILE and TOOL_EVENTS_LEDGER_FILE constants in common.sh"
    - "TOOLS_CLI_CAPABLE dual probe in report.sh"
    - "normalize_tool_id, classify_tool_type, _register_tool helpers in report.sh"
    - "toolCall scan loop calling _register_tool (TOOLEV-01 registry foundation)"
  affects:
    - "10-02: _meter_tool_event wiring (builds on scan loop added here)"

tech_stack:
  added: []
  patterns:
    - "TOOLS_CLI_CAPABLE dual probe mirrors JOBS_CLI_CAPABLE (D-11 pattern)"
    - "Ledger dedup via grep -qF (fixed-string, safe for IDs with special chars)"
    - "argv-array discipline for tools create (T-04-09 / V5 security)"
    - "409-as-success backstop mirrors jobs create (D-06 pattern)"
    - "Env-passing python3 heredoc for toolCall scan (Bash 3.2 portability)"
    - "normalize_tool_id: __ -> --, _ -> -, lowercase via python3 (Bash 3.2 safe)"

key_files:
  created: []
  modified:
    - path: "scripts/common.sh"
      change: "Added TOOL_REGISTRY_LEDGER_FILE and TOOL_EVENTS_LEDGER_FILE constants in Phase 10 path-constants block"
    - path: "scripts/report.sh"
      change: "Added TOOL_REGISTRY_LEDGER_FILE/TOOL_EVENTS_LEDGER_FILE constants; touch calls; normalize_tool_id/classify_tool_type/_register_tool helpers; TOOLS_CLI_CAPABLE probe; toolCall scan loop calling _register_tool"
    - path: "tests/test_report_argv.sh"
      change: "Rule 1 fix: exclude meter tool-event --help probe from meter count assertion (prevents regression from TOOLS_CLI_CAPABLE probe)"

decisions:
  - "toolCall scan loop added in Plan 01 (not Plan 02) to satisfy TOOLEV-01 test assertions — _meter_tool_event wiring deferred to Plan 02"
  - "test_report_argv.sh meter count assertion extended to exclude TOOLS_CLI_CAPABLE probe calls (consistent with existing JOBS_CLI_CAPABLE exclusion)"

metrics:
  duration: "6m"
  completed_date: "2026-06-04"
  tasks_completed: 2
  files_modified: 3
---

# Phase 10 Plan 01: Tool Registry Foundation Summary

**One-liner:** TOOLS_CLI_CAPABLE probe, normalize_tool_id/classify_tool_type/_register_tool helpers, and toolCall scan loop in report.sh — tools registered exactly once in revenium-tools.ledger on first sight, fully fail-open.

## Tasks Completed

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | Add tool ledger constants to common.sh | e514c8e | scripts/common.sh |
| 2 | Add TOOLS_CLI_CAPABLE probe, ledger touches, and registry helpers to report.sh | e208d11 | scripts/report.sh, tests/test_report_argv.sh |

## Verification Results

**Syntax:** `bash -n scripts/common.sh` and `bash -n scripts/report.sh` both exit 0.

**Tool argv test:** `bash tests/test_report_tool_argv.sh` — 13 passed, 4 failed (RED expected for Plan 02 TOOLEV-02 assertions).

Passing (Plan 01 scope):
- TOOLEV-01: tools create --name read / --tool-id read / --tool-type BUILTIN in argv
- TOOLEV-01: TOOL:read: entry written to revenium-tools.ledger
- TOOLEV-01 idempotency: tools create called exactly once across two runs
- TOOLEV-04 fail-open: zero tools create / meter tool-event when TOOLS_CLI_CAPABLE=false
- TOOLEV-04 fail-open: meter completion still present when probe fails (v1.1 unaffected)
- TOOLEV-03: meter completion TOOL_CALL and CHAT still present (completion path untouched)

Acceptable RED (Plan 02 scope):
- TOOLEV-02: --success flag not found (requires _meter_tool_event)
- TOOLEV-02: --duration-ms 250 not found (requires _meter_tool_event)
- TOOLEV-02: TOOLEV:toolu_test001 not in ledger (requires _meter_tool_event)
- TOOLEV-04 event idempotency: meter tool-event count=2 (probe calls match adjacency check; Plan 02 must add --help exclusion)

**Regression suite:** All green.
- test_report_argv.sh: 10 passed, 0 failed
- test_report_jobs_argv.sh: 71 passed, 0 failed
- test_guardrail_argv.sh: 18 passed, 0 failed

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] toolCall scan loop added in Plan 01 (not deferred to Plan 02)**
- **Found during:** Task 2
- **Issue:** Without the toolCall scan loop, `_register_tool` is never called, and TOOLEV-01 test assertions (`tools create --name read`) cannot pass in Plan 01 — contradicting the plan's acceptance criteria.
- **Fix:** Added the full toolCall scan loop (gated on TOOLS_CLI_CAPABLE) inside process_session. Loop calls `_register_tool` only; `_meter_tool_event` is not yet defined and is deferred to Plan 02.
- **Files modified:** scripts/report.sh
- **Commit:** e208d11

**2. [Rule 1 - Bug] test_report_argv.sh meter count regression from TOOLS_CLI_CAPABLE probe**
- **Found during:** Task 2 regression verification
- **Issue:** `test_report_argv.sh` counts all `meter` argv tokens and subtracts `meter completion --help` probe calls. The new TOOLS_CLI_CAPABLE probe adds `meter tool-event --help`, creating an extra `meter` token. Count was 7 vs. expected 6 completions → FAIL.
- **Fix:** Extended the meter count filter to also subtract `meter tool-event --help` probe calls (awk triple-match, consistent with existing JOBS_CLI_CAPABLE exclusion pattern).
- **Files modified:** tests/test_report_argv.sh
- **Commit:** e208d11

## Known Stubs

None — tool registration is fully wired (create-once, ledger-gated, fail-open). Tool-event emission (`_meter_tool_event`) is intentionally deferred to Plan 02 and is not a stub but a planned extension.

## Threat Flags

No new unplanned threat surface. Threat model in PLAN.md covers all additions:
- T-10-01-01: tool name → argv (mitigated: argv-array discipline)
- T-10-01-02: tool_id → ledger key (mitigated: grep -qF, 64-char truncation)
- T-10-01-03: tools create hang/error (mitigated: fail-open return 0)
- T-10-01-04: API key leakage (mitigated: only tool id / type logged)

## Self-Check: PASSED

Files exist:
- scripts/common.sh: FOUND, contains TOOL_REGISTRY_LEDGER_FILE and TOOL_EVENTS_LEDGER_FILE
- scripts/report.sh: FOUND, contains _register_tool(), normalize_tool_id(), classify_tool_type(), TOOLS_CLI_CAPABLE probe

Commits exist:
- e514c8e: feat(10-01): add TOOL_REGISTRY_LEDGER_FILE and TOOL_EVENTS_LEDGER_FILE constants to common.sh
- e208d11: feat(10-01): add TOOLS_CLI_CAPABLE probe, ledger touches, and registry helpers to report.sh
