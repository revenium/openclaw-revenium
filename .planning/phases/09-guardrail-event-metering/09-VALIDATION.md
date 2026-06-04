---
phase: 9
slug: guardrail-event-metering
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-06-03
---

# Phase 9 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash integration tests (existing pattern in `tests/`) |
| **Config file** | None — tests are standalone shell scripts |
| **Quick run command** | `bash tests/test_guardrail_argv.sh` |
| **Full suite command** | `bash tests/test_report_argv.sh && bash tests/test_report_jobs_argv.sh && bash tests/test_guardrail_argv.sh` |
| **Estimated runtime** | ~10 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test_guardrail_argv.sh`
- **After every plan wave:** Run the full suite command
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** ~15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| W0 | 00 | 0 | GRDEV-01..05 | — | N/A | infra | `bash tests/test_guardrail_argv.sh` | ❌ W0 | ⬜ pending |
| GRDEV-01a | — | — | GRDEV-01 | — | Halt onset emits `--operation-type GUARDRAIL --task-type budget_guardrail_halt --stop-reason COST_LIMIT` | integration | `bash tests/test_guardrail_argv.sh` | ❌ W0 | ⬜ pending |
| GRDEV-01b | — | — | GRDEV-01 | — | Halt dedup: a second cron tick during the same halt produces no additional meter call | integration | `bash tests/test_guardrail_argv.sh` | ❌ W0 | ⬜ pending |
| GRDEV-02a | — | — | GRDEV-02 | — | Warn onset emits `--task-type budget_guardrail_warn`, exactly once per onset (not per tick) | integration | `bash tests/test_guardrail_argv.sh` | ❌ W0 | ⬜ pending |
| GRDEV-02b | — | — | GRDEV-02 | — | warn→ok→warn re-fires (second onset after recovery) | integration | `bash tests/test_guardrail_argv.sh` | ❌ W0 | ⬜ pending |
| GRDEV-03 | — | — | GRDEV-03 | — | Shadow onset emits `--task-type budget_guardrail_shadow`, once per breach | integration | `bash tests/test_guardrail_argv.sh` | ❌ W0 | ⬜ pending |
| GRDEV-04a | — | — | GRDEV-04 | — | `--agent openclaw-<root_sid>` present in every meter call | integration | `bash tests/test_guardrail_argv.sh` | ❌ W0 | ⬜ pending |
| GRDEV-04b | — | — | GRDEV-04 | — | `--agentic-job-id` present when an open job exists; omitted when none | integration | `bash tests/test_guardrail_argv.sh` | ❌ W0 | ⬜ pending |
| GRDEV-05 | — | — | GRDEV-05 | — | Meter-call failure → guardrail-check.sh still exits 0 and status file is written | integration | `bash tests/test_guardrail_argv.sh` | ❌ W0 | ⬜ pending |
| GRDEV-06 | — | — | GRDEV-06 | — | report.sh `operation_type` is only CHAT or TOOL_CALL after D-12 removal | integration | `bash tests/test_report_argv.sh` | ✅ (extend) | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*
*Plan/Wave columns filled in once PLAN.md task IDs are assigned.*

---

## Wave 0 Requirements

- [ ] `tests/test_guardrail_argv.sh` — new file; covers GRDEV-01..05 (does not exist today)
- [ ] `tests/stub-revenium.sh` extension — add `guardrails enforcement-rules get` and `guardrails budget-rules list` stub responses, plus a `STUB_REVENIUM_GUARDRAILS_FAIL` switch to simulate meter-call failure
- [ ] `revenium meter completion --help` live verification — confirm `--transaction-id` optional, zero token values accepted, `COST_LIMIT` is a valid `--stop-reason` enum value

*GRDEV-06: existing `tests/test_report_argv.sh` is extended with an assertion that no `operation_type GUARDRAIL` token appears in argv after the D-12 removal.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| A real GUARDRAIL transaction lands in Revenium | GRDEV-01..04 | Requires the live Revenium API + cron pipeline; cannot be asserted hermetically | On host `172.16.1.247`: force a halt/warn via the cron pipeline, confirm a `GUARDRAIL` transaction appears in Revenium with the expected `--task-type` and `--agent`/`--agentic-job-id`, then clean up the forced state and ledger entry |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
