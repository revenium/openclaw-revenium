---
phase: 09-guardrail-event-metering
verified: 2026-06-03T00:00:00Z
status: human_needed
score: 6/6
overrides_applied: 0
human_verification:
  - test: "Force a guardrail halt on host 172.16.1.247 and confirm a GUARDRAIL transaction appears in Revenium"
    expected: "A transaction with operationType=GUARDRAIL, taskType=budget_guardrail_halt, agent=openclaw-<root_sid>, and the correct agentic-job-id lands in the Revenium dashboard; then clean up the forced state and ledger entry"
    why_human: "Requires the live Revenium API, the real revenium CLI, and the cron pipeline on the test host; cannot be asserted hermetically — explicitly deferred to UAT per 09-VALIDATION.md"
---

# Phase 9: Guardrail Event Metering — Verification Report

**Phase Goal:** Every guardrail enforcement event — a halt, a warn, or a shadow-mode would-have-halted — surfaces in Revenium as a discrete GUARDRAIL transaction, emitted once per event and never at the expense of enforcement.
**Verified:** 2026-06-03
**Status:** human_needed (all automated checks pass; live end-to-end on test host deferred to UAT per 09-VALIDATION.md)
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | A halt onset emits exactly one GUARDRAIL transaction (`--task-type budget_guardrail_halt --stop-reason COST_LIMIT`), deduped via revenium-guardrail.ledger so repeated ticks never re-emit (GRDEV-01) | VERIFIED | GROUP A + GROUP B in `tests/test_guardrail_argv.sh` pass (18/18 total); `_emit_guardrail_event` with `grep -qF` ledger dedup gate implemented in `scripts/guardrail-check.sh` lines 553-555; halt emit at lines 605-615 |
| 2 | A warn onset emits exactly one GUARDRAIL transaction (`--task-type budget_guardrail_warn`) per onset, re-firing only after warn→ok→warn (GRDEV-02) | VERIFIED | GROUP C + GROUP D pass; `warn_transitions` Python block in guardrail-check.sh lines 295-314 gated on `state=='warn'` (not 'block') and `not shadowMode`; warn emit loop at lines 617-638 |
| 3 | A shadow would-have-halted onset emits exactly one GUARDRAIL transaction (`--task-type budget_guardrail_shadow`) per breach (GRDEV-03) | VERIFIED | GROUP E passes; shadow emit loop at lines 640-661 using separate `SHADOW_METER_TMP` (no collision with Section L's `SHADOW_TMP`) |
| 4 | Every transaction carries `--agent openclaw-<root_sid>` and `--agentic-job-id` of the most-recently-opened open job when one exists, omitting it otherwise (GRDEV-04) | VERIFIED | GROUP F + GROUP G pass; root session attribution via `get_root_session_id` wrapper (lines 494-504); open-job attribution via env-passing Python heredoc (lines 510-531); `--agentic-job-id` conditional on non-empty `_guardrail_open_job_id` (lines 588-591) |
| 5 | A meter failure never changes guardrail-check.sh's exit-0 posture, status-file write, or notifications — Section M is the last bash section, after the durable status write (Section G) and all notifications (Sections I-L) (GRDEV-05) | VERIFIED | GROUP H + GROUP I pass; Section ordering confirmed: G (line 121) → L (line 449) → M (line 482); `_emit_guardrail_event` returns 0 on all paths (line 602); all callers use `|| true`; warn "fail-open, continuing" on non-zero exit (line 600) |
| 6 | report.sh no longer contains the dead GUARDRAIL heuristic — `operation_type` is only CHAT or TOOL_CALL (GRDEV-06) | VERIFIED | `grep 'operation_type.*GUARDRAIL' scripts/report.sh` returns no output; `grep 'budget-status.json' scripts/report.sh` returns no output; report.sh lines 845-849 show only CHAT/TOOL_CALL paths; GROUP I (test 10) in `tests/test_report_argv.sh` passes asserting no `--operation-type GUARDRAIL` in argv |

**Score:** 6/6 truths verified

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `scripts/common.sh` | GUARDRAIL_LEDGER_FILE and JOBS_LEDGER_FILE path constants | VERIFIED | Lines 63-64; JOBS_LEDGER_FILE byte-identical to report.sh line 34 (confirmed by grep comparison) |
| `scripts/guardrail-check.sh` | warn-onset detection, HALTED_AT/WARN_TRANSITIONS emit, Section M `_emit_guardrail_event` + halt/warn/shadow emit calls | VERIFIED | 661 lines; all required patterns present at confirmed line numbers |
| `tests/test_guardrail_argv.sh` | Hermetic argv-capture test harness for GRDEV-01..05 | VERIFIED | 591 lines; 18/18 assertions pass (GREEN) |
| `tests/stub-revenium.sh` | guardrails subcommand stub responses + STUB_REVENIUM_GUARDRAILS_FAIL failure switch | VERIFIED | 177 lines; branches for `guardrails enforcement-rules get`, `guardrails budget-rules list`, failure switch, `Team ID:` in config show |
| `scripts/report.sh` | operation_type detection limited to CHAT / TOOL_CALL | VERIFIED | 1252 lines; dead GUARDRAIL branch removed; BUDGET_STATUS_FILE dead constant removed |
| `tests/test_report_argv.sh` | Assertion that report.sh never emits --operation-type GUARDRAIL | VERIFIED | 321 lines; GRDEV-06 assertion at lines 302-310; test 10 of 10 passes |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `scripts/guardrail-check.sh` Section M | `revenium meter completion` | `_emit_guardrail_event cmd+=()` argv array | VERIFIED | `cmd=(revenium meter completion ...)` at lines 565-583; `--operation-type "GUARDRAIL"` at line 581 |
| `scripts/guardrail-check.sh` Section M | `GUARDRAIL_LEDGER_FILE` | `grep -qF` dedup gate + append | VERIFIED | Lines 553-555 (dedup), line 597 (append); `touch` at line 490 |
| `scripts/guardrail-check.sh` Section M | `JOBS_LEDGER_FILE` | read-only open-job scan (created minus outcome) | VERIFIED | `JOBS_LEDGER_FILE="${JOBS_LEDGER_FILE}"` env-passing Python heredoc at lines 510-531 |
| `scripts/guardrail-check.sh` Python block | WARN_TRANSITIONS / HALTED_AT emit lines | `print(KEY=value)` parsed by bash sed tail | VERIFIED | `print(f"WARN_TRANSITIONS=...")` line 358; `print(f"HALTED_AT=...")` line 352; sed extraction at lines 371-374 |
| `scripts/report.sh` operation_type detection | `revenium meter completion --operation-type` | only TOOL_CALL (toolUse) or CHAT branches | VERIFIED | Lines 845-849; only two code paths; no GUARDRAIL path |

---

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|-------------------|--------|
| `scripts/guardrail-check.sh` Section M | `_guardrail_agent_val` | `get_root_session_id` + `ls -t SESSIONS_DIR/*.jsonl` | Yes — reads live session files from OPENCLAW_HOME | FLOWING |
| `scripts/guardrail-check.sh` Section M | `_guardrail_open_job_id` | Python scan of `JOBS_LEDGER_FILE` (JOB:id:created: vs outcome: lines) | Yes — reads live jobs ledger written by report.sh | FLOWING |
| `scripts/guardrail-check.sh` Section M | `HALTED_AT`, `WARN_TRANSITIONS_JSON`, `SHADOW_TRANSITIONS_JSON` | sed extraction from `HALT_OUTPUT` (Python heredoc output) | Yes — derived from live enforcement-rules JSON from Revenium API | FLOWING |

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| `bash -n` syntax check — all 6 modified scripts | `bash -n scripts/common.sh scripts/guardrail-check.sh scripts/report.sh tests/test_guardrail_argv.sh tests/stub-revenium.sh tests/test_report_argv.sh` | All 6 exit 0 | PASS |
| GRDEV-01..05 test suite (18 assertions) | `bash tests/test_guardrail_argv.sh` | 18 passed, 0 failed | PASS |
| GRDEV-06 + report.sh regression (10 assertions) | `bash tests/test_report_argv.sh` | 10 passed, 0 failed | PASS |
| report.sh jobs regression (71 assertions) | `bash tests/test_report_jobs_argv.sh` | 71 passed, 0 failed | PASS |
| GUARDRAIL heuristic absent from report.sh | `grep 'operation_type.*GUARDRAIL' scripts/report.sh` | no output | PASS |
| `budget-status.json` absent from report.sh | `grep 'budget-status.json' scripts/report.sh` | no output | PASS |
| Section M is last section (after Section L) | Line numbers: Section L=449, Section M=482, EOF=661 | M > L, M is last | PASS |
| warn_transitions uses state=='warn' not 'block' | `grep 'state.*warn' scripts/guardrail-check.sh` | Line 298: `nr.get('state') == 'warn'` | PASS |
| shadowMode excluded from warn_transitions | `grep 'shadowMode' scripts/guardrail-check.sh` | Line 298: `not nr.get('shadowMode', False)` | PASS |
| JOBS_LEDGER_FILE byte-identical in common.sh and report.sh | grep comparison | Both: `"${REVENIUM_JOBS_LEDGER_FILE:-${OPENCLAW_HOME}/revenium-jobs.ledger}"` | PASS |
| RESEARCH.md Open Questions marked RESOLVED | `grep '## Open Questions' 09-RESEARCH.md` | `## Open Questions (RESOLVED)` | PASS |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| GRDEV-01 | 09-01 | Halt onset emits exactly one GUARDRAIL transaction, deduped | SATISFIED | GROUP A+B pass; `_emit_guardrail_event budget_guardrail_halt` at lines 609-614; ledger dedup gate at lines 553-555 |
| GRDEV-02 | 09-01 | Warn onset emits exactly one GUARDRAIL transaction per onset, re-fires after warn→ok→warn | SATISFIED | GROUP C+D pass; warn_transitions Python block (lines 295-314); warn emit loop (lines 617-638) |
| GRDEV-03 | 09-01 | Shadow onset emits exactly one GUARDRAIL transaction per breach | SATISFIED | GROUP E passes; shadow emit loop (lines 640-661) |
| GRDEV-04 | 09-01 | Transaction carries --agent openclaw-<root_sid> and open --agentic-job-id when available | SATISFIED | GROUP F+G pass; attribution at lines 494-531; conditional job_id at lines 588-591 |
| GRDEV-05 | 09-01 | Metering is fail-open — meter failure never blocks enforcement or cron exit | SATISFIED | GROUP H+I pass; Section M last (line 482); `return 0` on all paths (line 602); callers use `|| true` |
| GRDEV-06 | 09-02 | Dead GUARDRAIL heuristic removed from report.sh; completions only CHAT or TOOL_CALL | SATISFIED | Test 10 in test_report_argv.sh passes; no `operation_type="GUARDRAIL"` or `budget-status.json` in report.sh |

All 6 GRDEV requirements for Phase 9 are satisfied. No orphaned requirements (REQUIREMENTS.md traceability table maps all 6 to Phase 9).

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| No blockers found | — | — | — | — |

No TBD, FIXME, or XXX debt markers in any of the 6 modified files. `TMPDIR` references in test files are legitimate `mktemp` usage patterns, not stubs.

---

### Human Verification Required

#### 1. Live End-to-End GUARDRAIL Transaction on Test Host

**Test:** On host `172.16.1.247`, force a guardrail halt/warn via the cron pipeline (e.g., temporarily lower a rule threshold below current spend). Let the cron job fire. Then check the Revenium dashboard for a new GUARDRAIL transaction.
**Expected:** A transaction with `operationType=GUARDRAIL`, the correct `taskType` (budget_guardrail_halt or budget_guardrail_warn), `agent=openclaw-<root_session_id>`, and (if a job is open) the `agenticJobId` set. Clean up the forced state, restore the rule threshold, and remove the ledger entry (`revenium-guardrail.ledger`) to reset for production.
**Why human:** Requires the live Revenium API, the real `revenium` CLI, and the full cron pipeline on the test host (172.16.1.247). Cannot be asserted hermetically. Explicitly deferred to UAT in 09-VALIDATION.md.

---

### Advisory Findings (Non-Blocking)

The following findings are from 09-REVIEW.md (code review advisory). None block the phase goal per the phase context note.

- **WR-01 (Advisory):** Metering-completeness edge case — if the `revenium meter completion` call fails on the exact onset tick, the ledger key is not written, so a subsequent tick could re-attempt the meter call. This is an edge case in the fail-open/retry semantics. Noted as advisory in 09-REVIEW.md; does not contradict any GRDEV must-have (GRDEV-05 requires fail-open, not exactly-once on failure).

---

### Gaps Summary

No gaps. All 6 must-have truths are VERIFIED. All 3 test suites are GREEN (18/18, 10/10, 71/71). All 6 GRDEV requirements are satisfied. The only outstanding item is the live UAT verification, which is a human item explicitly deferred in 09-VALIDATION.md — not a blocker.

---

_Verified: 2026-06-03_
_Verifier: Claude (gsd-verifier)_
