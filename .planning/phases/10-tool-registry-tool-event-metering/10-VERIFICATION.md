---
phase: 10-tool-registry-tool-event-metering
verified: 2026-06-04T04:40:00Z
status: passed
score: 4/4 must-haves verified
overrides_applied: 0
re_verification: false
---

# Phase 10: Tool Registry & Tool-Event Metering Verification Report

**Phase Goal:** Agent tool usage is observable in Revenium — tools are registered and invocations are metered — without double-counting the completions already metered as TOOL_CALL.
**Verified:** 2026-06-04T04:40:00Z
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #  | Truth (ROADMAP Success Criterion)                                                                               | Status     | Evidence                                                                                                                                                     |
|----|------------------------------------------------------------------------------------------------------------------|------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1  | TOOLEV-01: Agent tools are registered in Revenium via `revenium tools create`                                   | VERIFIED   | `_register_tool()` defined at report.sh:249; anchored dedup `grep -q "^TOOL:${tool_id}:"` at line 254; test asserts `tools create --name read --tool-id read --tool-type BUILTIN` in argv (PASS) |
| 2  | TOOLEV-02: Tool invocations appear in Revenium as tool-events via `revenium meter tool-event`                   | VERIFIED   | `_meter_tool_event()` defined at report.sh:293; toolCall scan loop at lines 1117-1202 calls it after completion loop; test asserts `--tool-id read`, `--agent openclaw-*`, bare `--success`, `--duration-ms 250` in argv (PASS) |
| 3  | TOOLEV-03: Tool-event metering does not double-count against existing `TOOL_CALL` completions                   | VERIFIED   | `_meter_tool_event` explicitly never calls `meter completion` or uses `--operation-type` (code comment + no reference in function body); completion path untouched (D-01); test asserts TOOL_CALL + CHAT completions still emitted AND no `--operation-type` contamination (PASS) |
| 4  | TOOLEV-04: Tool registry + tool-event work is fail-open and idempotency-gated                                   | VERIFIED   | Registry dedup: anchored `grep -q "^TOOL:${tool_id}:"` (CR-01 fixed, commit b3cef23); event dedup: anchored `grep -q "^${ledger_key}$"` (CR-02 fixed, commit b3cef23); TOOLS_CLI_CAPABLE probe at lines 1471-1477 gates all tool work; both helpers `return 0` on all paths, never touch `failed_count`/`reported_count`; prefix-collision regression tests PASS |

**Score:** 4/4 truths verified

### Required Artifacts

| Artifact                          | Expected                                                            | Status    | Details                                                                            |
|-----------------------------------|---------------------------------------------------------------------|-----------|------------------------------------------------------------------------------------|
| `scripts/common.sh`               | `TOOL_REGISTRY_LEDGER_FILE` and `TOOL_EVENTS_LEDGER_FILE` constants | VERIFIED  | Lines 73-74; 4 occurrences of both constants confirmed; Phase 10 comment block present |
| `scripts/report.sh`               | `_register_tool`, `_meter_tool_event`, `TOOLS_CLI_CAPABLE` probe    | VERIFIED  | `_register_tool()` line 249; `_meter_tool_event()` line 293; probe lines 1471-1477; `normalize_tool_id` line 221; `classify_tool_type` line 233; toolCall scan loop lines 1117-1202 |
| `tests/test_report_tool_argv.sh`  | Hermetic integration test covering TOOLEV-01..04 (19 assertions)    | VERIFIED  | File exists; `bash tests/test_report_tool_argv.sh` exits 0; Results: 19 passed, 0 failed |
| `tests/stub-revenium.sh`          | Extended with `tools --help`, `meter tool-event --help`, `tools create` branches | VERIFIED | `tools --help` line 162, `meter tool-event --help` line 173, `tools create` line 210; `STUB_REVENIUM_NO_TOOLS` and `STUB_REVENIUM_TOOLS_FAIL` switches documented in header |

### Key Link Verification

| From                                    | To                                     | Via                                                          | Status   | Details                                                                            |
|-----------------------------------------|----------------------------------------|--------------------------------------------------------------|----------|------------------------------------------------------------------------------------|
| `report.sh _register_tool`              | `TOOL_REGISTRY_LEDGER_FILE`            | anchored `grep -q "^TOOL:${tool_id}:"` dedup + append on success/409 | WIRED    | Line 254 (dedup); line 275 (append `TOOL:<id>:<ts>`); anchored — CR-01 BLOCKER fixed |
| `report.sh TOOLS_CLI_CAPABLE probe`     | `revenium tools / meter tool-event`    | dual `--help` probe at startup before `main`                 | WIRED    | Lines 1472-1474; probe checks `tools --help` exit code AND `meter tool-event --help` output for `--tool-id` |
| `report.sh process_session`             | `_register_tool` + `_meter_tool_event` | toolCall scan loop AFTER completion while-read loop, gated on `TOOLS_CLI_CAPABLE` | WIRED    | Lines 1125-1202; loop positioned after `done < <(tail ...)` at line 1111, before `set_offset` at line 1210 |
| `report.sh _meter_tool_event`           | `TOOL_EVENTS_LEDGER_FILE`              | anchored `grep -q "^${ledger_key}$"` dedup + append on success | WIRED    | Line 303 (dedup); line 327 (append `TOOLEV:<id>`); anchored — CR-02 BLOCKER fixed |
| `tests/test_report_tool_argv.sh`        | `scripts/report.sh`                    | `run_report` invokes report.sh with `OPENCLAW_HOME` pointing at tmp home | WIRED    | `bash .*report.sh` confirmed in run_report helper |
| `tests/test_report_tool_argv.sh`        | `tests/stub-revenium.sh`               | symlink `revenium` -> stub on PATH; argv captured to `STUB_REVENIUM_ARGV_FILE` | WIRED    | `STUB_REVENIUM_ARGV_FILE` confirmed in test helper; symlink created via `TMP_FAKE_HOME` |

### Behavioral Spot-Checks

| Behavior                                          | Command                                           | Result                         | Status  |
|---------------------------------------------------|---------------------------------------------------|--------------------------------|---------|
| Full TOOLEV-01..04 integration test suite (19 checks) | `bash tests/test_report_tool_argv.sh`         | Results: 19 passed, 0 failed   | PASS    |
| Completion path regression (10 checks)            | `bash tests/test_report_argv.sh`                  | Results: 10 passed, 0 failed   | PASS    |
| Jobs regression (71 checks)                       | `bash tests/test_report_jobs_argv.sh`             | Results: 71 passed, 0 failed   | PASS    |
| Guardrail regression (18 checks)                  | `bash tests/test_guardrail_argv.sh`               | Results: 18 passed, 0 failed   | PASS    |
| report.sh syntax                                  | `bash -n scripts/report.sh`                       | exit 0                         | PASS    |
| common.sh syntax                                  | `bash -n scripts/common.sh`                       | exit 0                         | PASS    |
| stub-revenium.sh syntax                           | `bash -n tests/stub-revenium.sh`                  | exit 0                         | PASS    |
| test_report_tool_argv.sh syntax                   | `bash -n tests/test_report_tool_argv.sh`          | exit 0                         | PASS    |
| CR-01 fix — anchored registry grep                | `grep -n 'grep -q.*TOOL:' scripts/report.sh`      | `^TOOL:${tool_id}:` found at line 254 | PASS    |
| CR-02 fix — anchored event grep                   | `grep -n 'grep -q.*ledger_key' scripts/report.sh` | `^${ledger_key}$` found at line 303   | PASS    |
| Prefix-collision regression test                  | Inside `test_report_tool_argv.sh` GROUP X         | 2 PASS (prefix-safe assertions) | PASS    |

### Requirements Coverage

| Requirement | Source Plans      | Description                                                                           | Status    | Evidence                                                                 |
|-------------|-------------------|---------------------------------------------------------------------------------------|-----------|--------------------------------------------------------------------------|
| TOOLEV-01   | 10-00, 10-01      | Tools registered in Revenium via `revenium tools create`                              | SATISFIED | `_register_tool()` wired; test asserts `tools create --name read` in argv (PASS) |
| TOOLEV-02   | 10-00, 10-02      | Tool invocations metered via `revenium meter tool-event`                              | SATISFIED | `_meter_tool_event()` wired; test asserts `--tool-id`, `--duration-ms 250`, `--success` in argv (PASS) |
| TOOLEV-03   | 10-00, 10-02      | Tool-event metering does not double-count TOOL_CALL completions                       | SATISFIED | Test asserts TOOL_CALL + CHAT completions still emitted; no `--operation-type` contamination (PASS) |
| TOOLEV-04   | 10-00, 10-01, 10-02 | Tool registry + events are fail-open and idempotency-gated                           | SATISFIED | Both ledger dedup checks anchored (b3cef23 fix); TOOLS_CLI_CAPABLE probe; prefix-collision regression test PASS; fail-open `return 0` on all paths |

All 4 requirements mapped to Phase 10 are satisfied. No orphaned requirements.

### Anti-Patterns Found

| File                   | Line | Pattern      | Severity | Impact                                                                                                                         |
|------------------------|------|--------------|----------|--------------------------------------------------------------------------------------------------------------------------------|
| scripts/report.sh      | 1168 | WR-02 (open) | WARNING  | `err_text` not stripped of `\n`/`\t` before TSV emission — could corrupt scan-loop field alignment on multi-line error messages. No BLOCKER (only fires on `isError=true` tool results with embedded newlines; ledger dedup is still correct for tc_id; production test suite is green against the clean fixture). Review finding left open. |
| scripts/report.sh      | 1127 | WR-04 (open) | INFO     | `tool_scan_tmp=$(mktemp)` uses bare mktemp without labeled template — minor discoverability gap; no leak because block has no early return. |

No `TBD`, `FIXME`, or `XXX` markers found in any Phase 10-modified files. The two BLOCKER idempotency defects (CR-01, CR-02) found in the code review are confirmed fixed in commit b3cef23 with anchored grep patterns and covered by prefix-collision regression tests.

### Deviations from Plan Accepted as Correct

The following plan deviations were self-corrected by the executor and are verified correct:

1. **Plan 01 toolCall scan loop added early**: The plan deferred the scan loop to Plan 02 but the executor added it in Plan 01 to satisfy TOOLEV-01 test assertions. The loop calls only `_register_tool` in Plan 01 and gains `_meter_tool_event` in Plan 02 — correctly staged and consistent with the GREEN test evidence.

2. **`normalize_tool_id` uses `tr` not `python3`**: WR-05 (inconsistent fallback) was preemptively fixed by switching to `tr '[:upper:]' '[:lower:]'` (Bash 3.2-safe) instead of the `python3` env-passing heredoc the plan specified. This is strictly better — stable without python3 on cron PATH.

3. **Plan 02 idempotency assertion fix**: `count_adjacent "meter" "tool-event"` replaced with `count_grep "^--duration-ms$"` to exclude probe invocations — mirrors the jobs test pattern and is verified correct by the 19/0 test result.

### Human Verification Required

None — all observable behaviors are covered by the hermetic argv-capture test suite running against the stub. The stub replaces the real Revenium CLI end-to-end, so no human-in-the-loop verification is needed for this phase.

---

_Verified: 2026-06-04T04:40:00Z_
_Verifier: Claude (gsd-verifier)_
