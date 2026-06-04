---
phase: 06-job-lifecycle-wiring
verified: 2026-06-03T20:25:00Z
status: human_needed
score: 5/5 must-haves verified
overrides_applied: 0
human_verification:
  - test: "Force a duplicate `revenium jobs create` against staging Revenium — submit the same agentic_job_id twice — and capture the raw error response from the live CLI."
    expected: "The response text matches `grep -qi '409|already.exist|conflict'` so the 409-as-success branch in report.sh correctly treats it as idempotent."
    why_human: "The hermetic test uses a fabricated stub error string (`Error: 409 Conflict: job already exists`). The LIVE server conflict text is unknown. If it differs from the regex, the 409 branch silently degrades to a warn-and-continue (local ledger still gates the common path, so no double-bill, but the ledger row is skipped). Requires staging access."
  - test: "Run `report.sh` in a scenario where `jobs create` fails with a transient non-409 error for a session whose completion succeeds, then run it again after the jobs CLI is healthy."
    expected: "The second run retries `jobs create` (and then `jobs outcome`) for the job that failed on the first run, eventually producing a `:created:` and `:outcome:` ledger row."
    why_human: "CR-01 (confirmed in code): when `jobs_success=false`, the warn fires but `failed_count` is not incremented. On the next tick the offset equals `total_lines` so the session is skipped at the early-return gate (line 416) before the read loop runs. The 'retry next tick' warning at line 724 is misleading — no retry actually occurs. This is a correctness gap in the idempotency/durability guarantee, not testable hermetically with the current test harness because the harness's GROUP D fixture intentionally keeps STUB_REVENIUM_JOBS_FAIL set across both runs (it verifies decoupling, not retry recovery). Requires a two-run scenario where run-1 has a failing jobs CLI and run-2 has a healthy one."
---

# Phase 6: Job Lifecycle Wiring — Verification Report

**Phase Goal:** Each declared job runs the full Revenium lifecycle — created once, every belonging completion stamped to it, and closed once with a terminal outcome — driven idempotently by `report.sh` and a jobs ledger, without endangering existing metering.
**Verified:** 2026-06-03T20:25:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

All 5 roadmap Success Criteria (SC-1 through SC-5) map to REQUIREMENTS.md entries JLIFE-01 through JLIFE-05.

| #  | Truth (Roadmap SC)                                                                                                      | Status     | Evidence                                                                                                                                                      |
|----|-------------------------------------------------------------------------------------------------------------------------|------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1  | A declared job appears via `jobs create` exactly once even across multiple cron ticks (JLIFE-01)                         | VERIFIED   | GROUP A: 3 `^create$` tokens for 3 jobs; GROUP E idempotency: exactly 1 `^create$` across two runs; `:created:` ledger lines one-per-job — test 28/28 PASS   |
| 2  | Every completion belonging to a job ships `--agentic-job-id`, `--agentic-job-name`, `--agentic-job-type` (JLIFE-02)     | VERIFIED   | GROUP A: `--agentic-job-id add-feature-1ab2` found in argv; `--agentic-job-name` and `--agentic-job-type` present — test PASS                                 |
| 3  | A job is closed exactly once with `jobs outcome <id> --result SUCCESS\|FAILED\|CANCELLED` from the marker status (JLIFE-03) | VERIFIED   | GROUP A: 3 `^outcome$` tokens; `--result SUCCESS/FAILED/CANCELLED` correct per marker; `--metadata` only for FAILED; no `--outcome-type` ever — test PASS     |
| 4  | A `jobs` CLI error or absent subcommand is caught and logged without blocking metering or guardrail checks (JLIFE-04)    | VERIFIED   | GROUP B (probe fail): `STUB_REVENIUM_NO_JOBS=1` → zero `create`/`outcome`/`agentic-job` tokens, `--task-type`/`--agent` present; GROUP D (JOBS_FAIL): TX written once, offset advances, exit 0 — test PASS. **NOTE: CR-01 partial gap — see Human Verification #2** |
| 5  | The jobs ledger persists created/closed IDs so re-runs never re-issue `create` or `outcome` (JLIFE-05)                  | VERIFIED   | GROUP E: two consecutive runs → 1 `:created:` and 1 `:outcome:` ledger line; no second `^create$`/`^outcome$` in run-2 argv — test PASS                      |

**Score:** 5/5 truths verified (automated assertions pass)

---

### Deferred Items

None — all 5 phase requirements are verified at the automated level. Human verification items relate to durability semantics and live API confirmation, not to scope deferred to a later phase.

---

### Required Artifacts

| Artifact                               | Expected                                                                  | Status       | Details                                                                                  |
|----------------------------------------|---------------------------------------------------------------------------|--------------|------------------------------------------------------------------------------------------|
| `scripts/report.sh`                    | JOBS_LEDGER_FILE, JOBS_CLI_CAPABLE probe, in-loop create/outcome, stamping | VERIFIED     | All constructs present, `bash -n` passes, 28/28 integration assertions pass              |
| `tests/stub-revenium.sh`               | Argv capture + 409/JOBS_FAIL/NO_JOBS switches + --help probe responses    | VERIFIED     | `stub-meta-check.sh` 10/10 PASS; all switches behave per contract                       |
| `tests/stub-meta-check.sh`             | Self-check for all 10 stub behaviors                                      | VERIFIED     | Exits 0; 10/10 PASS confirmed by direct run                                              |
| `tests/test_report_jobs_argv.sh`       | JLIFE-01..05 integration fixtures, 28 assertions, <30s                    | VERIFIED     | 28/28 PASS; runtime ~4s; includes CR-02/D-12 decoupling fixture                         |

---

### Key Link Verification

| From                                  | To                           | Via                                              | Status   | Details                                                                      |
|---------------------------------------|------------------------------|--------------------------------------------------|----------|------------------------------------------------------------------------------|
| `report.sh` jobs create               | `revenium-jobs.ledger`       | `grep -q` gate + `echo JOB:<id>:created:<ts>`    | WIRED    | Lines 700-726; GROUP A ledger assertions confirm                              |
| `report.sh` jobs outcome              | `revenium-jobs.ledger`       | three-gate + `echo JOB:<id>:outcome:<ts>:<STATUS>` | WIRED  | Lines 864-905; GROUP A ledger assertions confirm                              |
| `report.sh` correlation               | `post_to_revenium`           | positional params 22/23/24 `agentic_job_id/name/type` | WIRED | Lines 298-302; `--agentic-job-id` found in GROUP A argv                     |
| `test_report_jobs_argv.sh`            | `stub-revenium.sh`           | `ln -sf` onto `TMP_FAKE_HOME/.local/bin/revenium` | WIRED   | Lines 66; confirmed by 28/28 test pass                                       |
| `test_report_jobs_argv.sh`            | `scripts/report.sh`          | `bash "${REPORT_SH}"` under `OPENCLAW_HOME=...`  | WIRED    | `run_report` helper at line 92                                               |

---

### Data-Flow Trace (Level 4)

| Artifact                  | Data Variable         | Source                                  | Produces Real Data | Status    |
|---------------------------|-----------------------|-----------------------------------------|--------------------|-----------|
| `post_to_revenium`        | `agentic_job_id`      | job correlation Python block (line 607) | Yes — reads jobs_cache_file built from marker JSONL | FLOWING |
| `JOBS_LEDGER_FILE`        | `:created:` rows      | `echo` after `jobs create` success (line 721) | Yes — written and gated | FLOWING |
| `JOBS_LEDGER_FILE`        | `:outcome:` rows      | `echo` after `jobs outcome` success (line 899) | Yes — written and gated | FLOWING |

---

### Behavioral Spot-Checks

| Behavior                                           | Command                                        | Result                        | Status  |
|----------------------------------------------------|------------------------------------------------|-------------------------------|---------|
| Stub self-check (all 10 switch behaviors)          | `bash tests/stub-meta-check.sh`                | 10/10 PASS                    | PASS    |
| Jobs integration test (28 assertions)              | `bash tests/test_report_jobs_argv.sh`          | 28/28 PASS, exit 0, ~4s       | PASS    |
| Regression test (task-type metering unchanged)     | `bash tests/test_report_argv.sh`               | 9/9 PASS, exit 0              | PASS    |
| report.sh syntax validity                          | `bash -n scripts/report.sh`                    | exit 0                        | PASS    |

---

### Probe Execution

No probe scripts declared for this phase. The plans specify integration tests (see Behavioral Spot-Checks above).

---

### Requirements Coverage

| Requirement | Source Plan(s)    | Description                                                                      | Status       | Evidence                                           |
|-------------|-------------------|----------------------------------------------------------------------------------|--------------|----------------------------------------------------|
| JLIFE-01    | 06-01, 06-02, 06-03 | `jobs create` once per job, ledger-gated, idempotent across ticks              | SATISFIED    | GROUP A + GROUP E: exactly 1 `^create$` per job across two runs |
| JLIFE-02    | 06-01, 06-02      | Every metered completion for a job ships `--agentic-job-id/-name/-type`          | SATISFIED    | GROUP A: all three job completion stamps verified  |
| JLIFE-03    | 06-01, 06-03      | `jobs outcome <id> --result STATUS` once per job; FAILED carries `--metadata`   | SATISFIED    | GROUP A: SUCCESS/FAILED/CANCELLED results correct; 1 `--metadata` (FAILED only) |
| JLIFE-04    | 06-01, 06-02, 06-03 | Jobs CLI errors caught, logged, and do not block task-type metering             | SATISFIED (automated) + UNCERTAIN (durability) | GROUP B probe-fail + GROUP D JOBS_FAIL pass; CR-01 gap in retry durability — see Human Verification #2 |
| JLIFE-05    | 06-01, 06-02, 06-03 | Jobs ledger persists created/closed IDs so re-runs never duplicate              | SATISFIED    | GROUP E: second run issues 0 `create`/`outcome` calls |

---

### Anti-Patterns Found

| File                    | Line  | Pattern                        | Severity | Impact                                                                                                    |
|-------------------------|-------|--------------------------------|----------|-----------------------------------------------------------------------------------------------------------|
| `scripts/report.sh`     | 724   | "metering continues" / "retry next tick" misleading warn | WARNING | When `jobs_success=false` on a transient non-409 failure, `failed_count` is not incremented so the offset advances to `total_lines` on line 919. On the next tick the session is skipped by the early-return gate (line 416) — the "retry next tick" in the warn is not actuated. Covered in Human Verification #2. |
| `scripts/report.sh`     | 399-400 | TSV write without newline/tab escaping in `fr` (failure_reason) | WARNING  | If a marker file bypasses `write-job-marker.sh`'s `sanitize()` (which strips `\n`/`\r`), a literal newline in `failure_reason` would split the TSV row and create a phantom job row in `jobs_cache_file`. In practice, all markers written by `write-job-marker.sh` are sanitized at write time, so this requires a hand-crafted or corrupted marker. Not a blocker but the cache serialization is not independently hardened. |
| `scripts/report.sh`     | 700, 865 | `grep -q "^JOB:${agentic_job_id}:created:"` — ID interpolated as BRE | INFO     | A crafted ID with BRE metacharacters could match the wrong ledger row (WR-01 from review). Markers are sanitized at write time (`:` → `_`), reducing practical exploitability; no current test exercises this. |
| `scripts/report.sh`     | 870   | `--result "${job_status}"` with no status-enum guard | INFO     | An empty or non-enum `job_status` ships `--result ""` (WR-02 from review). The marker writer validates the status allowlist at write time; an empty value would produce a CLI error which is caught by the fail-open path. |

No `TBD`, `FIXME`, or `XXX` debt markers found in phase-modified files.

---

### Human Verification Required

#### 1. Live Revenium 409 Conflict String Confirmation

**Test:** Against staging Revenium, issue `revenium jobs create --agentic-job-id <id> --quiet` twice with the same ID. Capture stderr from the second (duplicate) invocation.

**Expected:** The stderr output matches `grep -qi "409|already.exist|conflict"` so `report.sh`'s 409-as-success branch (lines 714, 892) correctly classifies the duplicate as idempotent and writes the ledger row.

**Why human:** The hermetic test uses a fabricated stub string (`Error: 409 Conflict: job already exists`). The live Revenium server's actual conflict text is unknown. If it doesn't match the regex, the 409 branch degrades to warn-and-continue (non-blocking — the local ledger still gates the common duplicate path — but the `:created:` row won't be written on a genuine 409 response). This is the phase exit gate declared in 06-03-PLAN.md and 06-03-SUMMARY.md.

---

#### 2. Transient-Failure Job Retry Recovery

**Test:** Simulate a scenario where `jobs create` fails with a transient non-409 error on run-1 (completion succeeds), then run `report.sh` again on run-2 with the jobs CLI healthy. Inspect whether the job is created and closed on run-2.

**Expected:** Because `failed_count` was 0 on run-1 (completion succeeded), the offset advances to `total_lines`. On run-2 the session is skipped by the early-return gate (line 416: `offset >= total_lines`). The `jobs create` is **never retried**. The test should confirm whether this matches the intended durability contract. If retry-on-jobs-failure is required, a `job_work_pending` flag (or equivalent mechanism) must be introduced to hold the offset when jobs work is outstanding.

**Why human:** The GROUP D fixture (`STUB_REVENIUM_JOBS_FAIL`) verifies decoupling — that a jobs failure does not break metering — but it does not assert the job is eventually created on a later healthy run. Automated verification of the "retry" path requires a two-run scenario with a state transition (failing → healthy jobs CLI) that the current test harness does not model. This is CR-01 from `06-REVIEW.md`: the "retry next tick" warning at line 724 is misleading — no retry occurs when the completion succeeded. The phase goal claims "created once … driven idempotently" but the retry durability path is unverified.

---

### Gaps Summary

All automated must-haves pass. Two items require human verification before phase sign-off can be unqualified:

1. **Live 409 string** — Non-blocking, declared phase exit gate. If the live server's conflict response differs from the regex, the 409-as-success branch is dead code in production (harmless because the local ledger deduplicates, but the diagnostic guarantee is false). Record at UAT.

2. **CR-01 retry durability** — Requires a design decision. The code accurately decouples jobs failures from metering (JLIFE-04 verified) but the "retry next tick" language in the warn at line 724 is incorrect: when a completion succeeds and `jobs create` fails, the offset advances and no retry ever fires. The phase goal's "idempotently … created once" claim is met for the happy path and the 409 path, but a transient-failure recovery path does not exist. This is either a known limitation to document (acceptable for v1.1, retries implicit in the 409-as-success safety net) or a gap requiring `job_work_pending` tracking. Phase 6 Success Criterion 1 says "appears in Revenium exactly once" — if the jobs CLI is transiently down, the job does not appear at all, which may be acceptable under v1.1's observability-only scope.

No BLOCKER-class gaps — the 28/28 automated test suite passes, and both open items are either the declared phase exit gate (item 1) or a documented known limitation from the code review (item 2).

---

_Verified: 2026-06-03T20:25:00Z_
_Verifier: Claude (gsd-verifier)_
