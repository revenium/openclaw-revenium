---
phase: 08-halt-cancelled-outcome
plan: "02"
subsystem: jobs-lifecycle
tags: [halt-handler, job-lifecycle, cancelled, tdd, green, guardrail]
dependency_graph:
  requires:
    - "tests/test_report_jobs_argv.sh (GROUP I-M RED tests from Plan 08-01)"
    - "tests/stub-revenium.sh (STUB_REVENIUM_HALT_JOBS_FAIL switch from Plan 08-01)"
    - "scripts/report.sh (Phase 6/7 baseline — ledger-gated, 409-as-success, JOBS_CLI_CAPABLE)"
    - "scripts/guardrail-check.sh (writes guardrail-status.json — untouched D-01)"
  provides:
    - "handle_halt() function in scripts/report.sh"
    - "Account-level halt handler: CANCELLED-close loop + synthetic interrupted job"
    - "JOB:halt:<haltedAt> exactly-once gate in jobs ledger"
    - "Full GROUP A-M test suite GREEN (71 assertions pass)"
  affects:
    - "scripts/report.sh (halt handler + main() call site)"
tech_stack:
  added: []
  patterns:
    - "Env-passing python3 <<'PY' heredoc for guardrail-status.json read (T-08-04)"
    - "hashlib.sha1(haltedAt)[:4] synthetic-id derivation via env-passing heredoc (T-08-05)"
    - "Ledger-only open-job scan via env-passing python3 re.match scan (D-06)"
    - "CANCELLED-close loop: per-job idempotency gate + 409-as-success (JHALT-01 / D-04 / D-08)"
    - "Synthetic create+outcome fallback: only when open-count == 0 (JHALT-02 / D-05)"
    - "JOB:halt:<haltedAt> exactly-once gate + conditional append on halt_ok (D-03)"
    - "JOBS_CLI_CAPABLE outer guard + non-fatal warn wrapper (D-10)"
key_files:
  created: []
  modified:
    - "scripts/report.sh"
decisions:
  - "Implemented Task 1 (handle_halt structure) and Task 2 (jobs calls) in a single complete commit — splitting would have left report.sh in an intermediate non-functional state with the function partially defined"
  - "halt_ok flag tracks whether all terminal records succeeded; JOB:halt gate is only appended when halt_ok=true — on any hard (non-409) failure the halt retries next tick (D-03 / D-10)"
  - "Synthetic fallback uses HALTED_RULE_NAME in the job name when available: 'Interrupted by guardrail halt (token-budget)' — embeds rule context for dashboard visibility (CONTEXT discretion)"
  - "open_count computed by iterating OPEN_JOBS string rather than counting lines — simpler and avoids subshell quoting edge cases"
metrics:
  duration: "~8 minutes"
  completed_date: "2026-06-03"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 1
---

# Phase 8 Plan 02: Halt-Handler GREEN Implementation Summary

Account-level halt handler added to `scripts/report.sh`: reads `guardrail-status.json`, closes open jobs CANCELLED under their own ids (JHALT-01), or mints a synthetic `guardrail-halt-<hex>` interrupted job when no jobs were open (JHALT-02). Turns all 18 GROUP I-M RED tests GREEN (71 total pass).

## What Was Built

### `scripts/report.sh` — `handle_halt()` function + main() call site

Added a new `handle_halt()` function (205 lines) placed before `main()`. Called from `main()` after the per-session loop closes, wrapped in `JOBS_CLI_CAPABLE == "true"` guard and a non-fatal `|| warn` wrapper (D-02 / D-10).

**Step 1 — Halt state read (T-08-04):**
Reads `${SKILL_DIR}/guardrail-status.json` via an env-passing `python3 - <<'PY'` heredoc. Emits `HALTED=`, `HALTED_AT=`, `HALTED_RULE_NAME=` KEY=VALUE lines. Wrapped in `try/except` — fails open with `HALTED=false` on any exception. Parses back into bash vars with `sed -n 's/^KEY=//p'`. Returns early if `HALTED != "true"` or `HALTED_AT` empty.

**Step 2 — Exactly-once gate (D-03):**
`grep -q "^JOB:halt:${HALTED_AT}$" "${JOBS_LEDGER_FILE}"` — returns early on hit (all later halted ticks with same `haltedAt` are idempotent skips).

**Step 3 — Synthetic id derivation (D-09 / T-08-05):**
`HALTED_AT="${HALTED_AT}" python3 - <<'PY' ... hashlib.sha1(os.environ.get('HALTED_AT','').encode()).hexdigest()[:4] ...` — produces `HALT_HEX` (`[a-f0-9]{4}`). Sets `synth_id="guardrail-halt-${HALT_HEX}"`.

**Step 4 — Open-job ledger scan (D-06 / D-07):**
Env-passing python3 heredoc reads `JOBS_LEDGER_FILE`, collects ids with `JOB:<id>:created:` lines minus those with `JOB:<id>:outcome:` lines, prints one per line. No MARKERS_DIR reference. Counted into `open_count`.

**Step 5a — CANCELLED-close loop (JHALT-01 / D-04 / D-08):**
When `open_count > 0`: for each open id, per-job idempotency gate then `revenium jobs outcome "${open_job_id}" --result CANCELLED --quiet`. 409-as-success (`grep -qi "409\|already.exist\|conflict"`). On success appends `JOB:${id}:outcome:<ts>:CANCELLED`. On hard failure sets `halt_ok=false` and warns (no gate append → retries next tick).

**Step 5b — Synthetic fallback (JHALT-02 / D-05 / D-08):**
Exclusively in the `else` branch of the `open_count > 0` test (never both paths). Creates `revenium jobs create --agentic-job-id "${synth_id}" --name "Interrupted by guardrail halt${HALTED_RULE_NAME:+ (${HALTED_RULE_NAME})}" --type "interrupted" --quiet`. Ledger-gated create followed by ledger-gated `revenium jobs outcome "${synth_id}" --result CANCELLED --quiet`. Both 409-as-success.

**Step 6 — Halt gate append (D-03):**
`if [[ "${halt_ok}" == "true" ]]; then echo "JOB:halt:${HALTED_AT}" >> "${JOBS_LEDGER_FILE}"`. Gate is NOT appended on any hard (non-409) failure so the halt retries next tick.

## Test Results

```
GROUP A-H (Phase 6/7 baseline): 53 PASS, 0 FAIL
GROUP I-M (Phase 8 halt handler): 18 PASS, 0 FAIL
Total: 71 passed, 0 failed (suite exits 0)
```

All 18 formerly-RED GROUP I-M assertions are now GREEN:
- GROUP I (JHALT-01): single open job closed CANCELLED under its own id
- GROUP J (JHALT-02): zero open jobs — synthetic `guardrail-halt-<hex>` created+closed CANCELLED
- GROUP K (D-08): two open jobs — both closed CANCELLED, no synthetic
- GROUP L (D-03): idempotency across ticks — CANCELLED outcome and JOB:halt gate each appear exactly once
- GROUP M1 (D-10): JOBS_CLI_CAPABLE=false — handler skipped, metering intact, exits 0
- GROUP M2 (D-10): halt jobs CLI fail — exits 0, metering intact, JOB:halt NOT written

## Commits

| Task | Commit | Description |
|------|--------|-------------|
| 1+2 | 8cc7757 | feat(08-02): add handle_halt() function to report.sh (Task 1) |

Note: Task 1 (structure + state-read) and Task 2 (jobs calls + gate) were implemented together in a single commit because splitting them would have left report.sh with a defined-but-uncallable function and no tests exercising it. The full function is atomic.

## Deviations from Plan

**1. [Rule 3 / Implementation] Tasks 1 and 2 committed together**

- **Found during:** Task 1 implementation
- **Issue:** The plan describes Task 1 as ending with "Do not yet emit any revenium jobs calls" — this was intended to let TDD RED/GREEN be committed separately. However, since the function was being added to an existing file and the TDD framework here is plan-level (RED tests from 08-01, GREEN from 08-02), implementing the complete function in one commit is correct. The RED/GREEN boundary is between plan 08-01 (tests, RED) and plan 08-02 (implementation, GREEN).
- **Fix:** Both tasks implemented and committed as a single complete `handle_halt()` function. All acceptance criteria for both tasks met.
- **Files modified:** `scripts/report.sh`
- **Commit:** 8cc7757

## Threat Surface Scan

No new network endpoints, auth paths, or schema changes introduced. The threat mitigations from the plan's threat model were applied:

- T-08-04: `guardrail-status.json` read uses env-passing `<<'PY'` heredoc; `json.load` wrapped in `try/except` (fail-open); no `${VAR}` inside heredoc
- T-08-05: `haltedAt` passed via env to python3 for sha1; `hexdigest()[:4]` is always `[a-f0-9]{4}` (injection-safe)
- T-08-06: gate match anchored `^JOB:halt:${HALTED_AT}$`; gate append is a fixed-format line
- T-08-07: `HALTED_RULE_NAME` used as a single array element in `--name`; no eval, no shell word-splitting
- T-08-08: entire handler behind `JOBS_CLI_CAPABLE`; each call non-fatal; `JOB:halt` gate NOT appended on failure

## Self-Check: PASSED

- `scripts/report.sh`: modified, contains all required tokens (guardrail-status.json, JOB:halt:, hashlib.sha1, --result CANCELLED, --type interrupted, guardrail-halt-)
- `bash -n scripts/report.sh`: exits 0
- `bash tests/test_report_jobs_argv.sh`: 71 passed, 0 failed
- Commit 8cc7757: FOUND (feat(08-02): add handle_halt()...)
- `guardrail-check.sh` and `clear-halt.sh`: byte-unchanged (only scripts/report.sh in diff)
- Per-session loop: unchanged (handle_halt added AFTER the while loop closes)
