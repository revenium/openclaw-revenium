---
phase: 06-job-lifecycle-wiring
plan: 03
subsystem: metering
tags: [bash, report-sh, job-lifecycle, jobs-create, jobs-outcome, ledger, fail-open, idempotency]

requires:
  - phase: 06-job-lifecycle-wiring/06-02
    provides: JOBS_CLI_CAPABLE probe + JOBS_LEDGER_FILE + jobs_cache_file with status/failure_reason fields

provides:
  - scripts/report.sh with in-loop jobs create (JLIFE-01): ledger-gated, 409-as-success, no --environment
  - scripts/report.sh with in-loop jobs outcome (JLIFE-03): create-confirmed gate, --result only, FAILED-only --metadata via json.dumps env-heredoc
  - scripts/report.sh jobs ledger persisting JOB:<id>:created:<ts> and JOB:<id>:outcome:<ts>:<STATUS> rows (JLIFE-05)
  - tests/test_report_jobs_argv.sh fully GREEN (28/28 — all JLIFE-01..05 fixtures including CR-02/D-12 STUB_REVENIUM_JOBS_FAIL runtime decoupling fixture)

affects:
  - 06-04+ (root rollup, halt→CANCELLED — read jobs_ledger and jobs_cache to extend lifecycle)

tech-stack:
  added: []
  patterns:
    - "jobs create pattern: JOBS_CLI_CAPABLE gate + agentic_job_id non-empty + grep-q created gate + bash cmd array + 409-net + ledger write last"
    - "jobs outcome pattern: three gates (outcome-already-closed / create-not-confirmed / proceed) + positional id + --result + FAILED-only --metadata json.dumps env-heredoc + 409-net + ledger write last"
    - "Correlation extended to 5 fields: jid/jname/jtype/status/failure_reason (tab-separated, parsed with _jrest chain)"
    - "Single-tick in-loop order: create → post_to_revenium (stamp) → outcome (D-09)"
    - "D-12 decoupling: own exit locals for jobs_cmd_exit/outcome_cmd_exit; never touches failed_count/reported_count; never return/exit process_session"

key-files:
  created: []
  modified:
    - scripts/report.sh

key-decisions:
  - "Extend correlation to 5 fields (add status + failure_reason) rather than re-reading jobs_cache_file: single Python call per completion, status available for outcome without extra scan"
  - "Outcome after post_to_revenium (not before): D-09 create→stamp→outcome; outcome deferred by create-confirmed gate means a failed create naturally defers outcome too (Pitfall 3 handled)"
  - "jobs_cmd/outcome_cmd as local bash arrays reset each iteration: `local jobs_cmd=(...)` ensures no array bleed across loop iterations"

requirements-completed: [JLIFE-01, JLIFE-03, JLIFE-05]

duration: 20min
completed: 2026-06-03
---

# Phase 6 Plan 03: Job Lifecycle Wiring — Create + Outcome Summary

**In-loop `jobs create` (JLIFE-01) + `jobs outcome` (JLIFE-03) with ledger gates, 409-as-success, fail-open best-effort, and FAILED-only `--metadata` via json.dumps env-heredoc; test_report_jobs_argv.sh fully GREEN (28/28)**

## Performance

- **Duration:** ~20 min
- **Started:** 2026-06-03T20:05:00Z
- **Completed:** 2026-06-03T20:25:00Z
- **Tasks:** 2
- **Files modified:** 1 (scripts/report.sh)

## Accomplishments

- Extended the per-completion job correlation Python block to output 5 tab-separated fields (added `status` + `failure_reason` to the existing `jid`/`jname`/`jtype` output), parsed into bash locals with the `_jrest` chain. These are the inputs for `jobs outcome` without an extra Python pass.

- Added **`jobs create`** block in the per-completion while-loop (after job correlation, before duration/stamp computation). Gates: `JOBS_CLI_CAPABLE == "true"` AND `agentic_job_id` non-empty AND `grep -q "^JOB:${id}:created:"` skip. Bash cmd array: `--agentic-job-id`, optional `--name`/`--type`, `--quiet`. Own exit locals (`jobs_cmd_output`/`jobs_cmd_exit`). 409-as-success net. Writes `JOB:<id>:created:<ts>` last on success; `warn` and continues on failure (D-12). No `--environment` (D-04).

- Added **`jobs outcome`** block after `post_to_revenium` (D-09 single-tick order: create → stamp → outcome). Three gates: (1) `grep -q "^JOB:${id}:outcome:"` idempotent skip; (2) `! grep -q "^JOB:${id}:created:"` deferred warn (Pitfall 3 / D-09); (3) proceed. Cmd array: positional `"${agentic_job_id}"`, `--result "${job_status}"`, `--quiet`, NO `--outcome-type` (D-07). FAILED+non-empty `failure_reason`: `FR="${failure_reason}" python3 - <<'PY' ... json.dumps({"failure_reason": fr}) ...` env-passing heredoc strips trailing newline, appends `--metadata` only when non-empty (D-08/T-06-08). 409-as-success net. Writes `JOB:<id>:outcome:<ts>:<STATUS>` last on success; `warn` and continues on failure (D-12).

- `tests/test_report_jobs_argv.sh` fully GREEN: 28/28 pass. `tests/test_report_argv.sh` stays 9/9 GREEN.

## Task Commits

1. **Task 1: Add in-loop jobs create (ledger-gated, 409-as-success, fail-open)** — `6f0889c` (feat)
2. **Task 2: Add in-loop jobs outcome (create-confirmed gate, FAILED-only metadata, fail-open)** — `42a41e0` (feat)

## Files Created/Modified

- `scripts/report.sh` — Correlation extended to 5 fields; `jobs create` block (after correlation, pre-stamp); `jobs outcome` block (post-stamp); both with OWN exit locals, ledger gates, 409-as-success, no failed_count/reported_count touches

## Decisions Made

- **Correlation extended to 5 fields**: Rather than re-scanning `jobs_cache_file` a second time for outcome, output `status` and `failure_reason` in the same Python run. One call per completion; zero extra file reads. Tab-separated output parsed with `_jrest` bash string splitting.

- **Outcome placed after `post_to_revenium`**: D-09 mandates create → stamp → outcome. Placing outcome after the stamp block means the create-confirmed gate (Gate 2) also naturally defers outcome when create failed (Pitfall 3 handled without extra logic).

- **`local jobs_cmd=(...)` and `local outcome_cmd=(...)` per-iteration**: Bash does not reset arrays on re-declaration in a loop. Using `local` ensures each loop iteration starts with a fresh array rather than appending to a leftover from the previous completion.

## Deviations from Plan

None — plan executed exactly as written. The `failure_reason` env-heredoc, the 409-as-success net, the create-confirmed gate, and the ledger row formats all match the PATTERNS.md verbatim patterns. No unexpected complexity required additional fixes.

## Known Stubs

None. All job lifecycle paths are fully wired: create fires, outcome fires, ledger gates enforce idempotency, 409-as-success covers the crash window, STUB_REVENIUM_JOBS_FAIL proves D-12 decoupling at runtime.

## Threat Flags

None. All new code follows established patterns:
- Bash cmd array discipline (T-06-09): `jobs_cmd+=(--name "${agentic_job_name}")`, never eval
- Env-passing heredoc for `failure_reason` json.dumps (T-06-08): `FR="${failure_reason}" python3 - <<'PY'`, no `${failure_reason}` inside the program string
- D-12 decoupling (T-06-10): `jobs_cmd_exit` / `outcome_cmd_exit` own exit locals, never fed to `failed_count` or the CR-02 offset gate — runtime-verified by STUB_REVENIUM_JOBS_FAIL fixture (TX: written once, offset advances, exit 0, no JOB: row on failure)
- Ledger-gated idempotency (T-06-11): `grep -q "^JOB:<id>:created:"` / `:outcome:"` + 409-as-success backstop for crash-between-API-and-ledger window

## Phase Exit Gate (Manual, Non-blocking)

Per PLAN.md threat model A1: one live duplicate `jobs create`/`outcome` against staging Revenium must confirm the real conflict string matches `grep -qi "409\|already.exist\|conflict"`. Non-blocking for phase sign-off but must be recorded at UAT. Logged in VALIDATION.md §Manual-Only Verifications.

## Self-Check: PASSED

All claims verified:
- `scripts/report.sh` — exists, `bash -n` passes
- `tests/test_report_jobs_argv.sh` — 28/28 PASS (verified with `bash tests/test_report_jobs_argv.sh`)
- `tests/test_report_argv.sh` — 9/9 PASS (regression unchanged)
- Full test suite (`test_setup_guardrails_argv.sh`, `test_write_job_marker.sh`, `test_write_marker.sh`) — all pass
- Commits `6f0889c` and `42a41e0` present in git log
- `git diff` confirms: no `--environment` in jobs create cmd; `FR=...` env-passing heredoc for failure_reason; no edits to `failed_count`/`reported_count`/CR-02 gate/process_session control flow

---
*Phase: 06-job-lifecycle-wiring*
*Completed: 2026-06-03*
