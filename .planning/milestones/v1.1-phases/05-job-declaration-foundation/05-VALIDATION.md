---
phase: 5
slug: job-declaration-foundation
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-06-03
---

# Phase 5 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Plain bash (`#!/usr/bin/env bash`) — no external test runner |
| **Config file** | none — each test file is self-contained |
| **Quick run command** | `bash tests/test_write_job_marker.sh` |
| **Full suite command** | `bash tests/test_write_marker.sh && bash tests/test_write_job_marker.sh` |
| **Estimated runtime** | ~5 seconds |

Test result format: `PASS: <description>` / `FAIL: <description>` per assertion, exit 0/1. No `run_tests.sh` exists; test files are invoked individually with `bash`.

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test_write_job_marker.sh`
- **After every plan wave:** Run `bash tests/test_write_marker.sh && bash tests/test_write_job_marker.sh`
- **Before `/gsd-verify-work`:** Both test files must be green
- **Max feedback latency:** 5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 05-xx | taxonomy | 1 | JOBDEC-01 | — | 11 labels, all snake_case, correct shape, seeded to STATE_DIR | unit | `bash tests/test_write_job_marker.sh` | ❌ W0 | ⬜ pending |
| 05-xx | writer | 1 | JOBDEC-03 | — | exit 0 + "job marker written:" for valid call | integration | `bash tests/test_write_job_marker.sh` | ❌ W0 | ⬜ pending |
| 05-xx | writer | 1 | JOBDEC-03 | — | non-zero exit for unknown `job_type` | integration | `bash tests/test_write_job_marker.sh` | ❌ W0 | ⬜ pending |
| 05-xx | writer | 1 | JOBDEC-03 | — | non-zero exit for invalid `status` | integration | `bash tests/test_write_job_marker.sh` | ❌ W0 | ⬜ pending |
| 05-xx | writer | 1 | JOBDEC-03 | — | non-zero exit when mandatory flag missing | integration | `bash tests/test_write_job_marker.sh` | ❌ W0 | ⬜ pending |
| 05-xx | writer | 1 | JOBDEC-03 | — | record is valid JSONL: 7 mandatory fields, `kind:"job"`, ISO8601 ts | integration | `bash tests/test_write_job_marker.sh` | ❌ W0 | ⬜ pending |
| 05-xx | writer | 1 | JOBDEC-03 | T-05 (concurrent append) | two rapid invocations → two non-corrupt lines (flock + O_APPEND) | integration | `bash tests/test_write_job_marker.sh` | ❌ W0 | ⬜ pending |
| 05-xx | writer | 1 | JOBDEC-03 | — | `failure_reason` written for FAILED, absent for SUCCESS/CANCELLED | integration | `bash tests/test_write_job_marker.sh` | ❌ W0 | ⬜ pending |
| 05-xx | writer | 1 | JOBDEC-03 | T-05 (dir perms) | markers/ dir created mode 0700 | integration | `bash tests/test_write_job_marker.sh` | ❌ W0 | ⬜ pending |
| 05-xx | writer | 1 | JOBDEC-04 | T-05 (arg injection) | field with `:` / `\|` / newline sanitized to `_` in record | integration | `bash tests/test_write_job_marker.sh` | ❌ W0 | ⬜ pending |
| 05-xx | writer | 1 | JOBDEC-04 | T-05 (arg injection) | field longer than length cap is truncated in record | integration | `bash tests/test_write_job_marker.sh` | ❌ W0 | ⬜ pending |
| 05-xx | directive | 2 | JOBDEC-02 | — | SKILL.md contains `JOB DECLARATION` section | grep | `grep -c "JOB DECLARATION" SKILL.md` ≥ 1 | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky. Task IDs are placeholders — bind to real plan/task numbers during planning.*

---

## Wave 0 Requirements

- [ ] `tests/test_write_job_marker.sh` — new test file covering all JOBDEC-01/03/04 cases. Mirror `tests/test_write_marker.sh` structure: tmp `OPENCLAW_HOME` tree, seed `job-taxonomy.json`, PASS/FAIL counters, cleanup trap.

The existing `tests/test_write_marker.sh` covers `write-marker.sh` and does NOT need modification — the new test file is entirely additive.

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| JOB DECLARATION directive reads naturally / arc-boundary semantics are correct | JOBDEC-02 | Prose quality and agent-comprehension can't be unit-tested; the grep proves presence, not quality | Read SKILL.md §JOB DECLARATION; confirm it mirrors TASK CLASSIFICATION shape, includes SUCCESS/FAILED/CANCELLED status bar, pivot-cancel rule, and the `agentic_job_id` format example |

Presence of the section is automated (grep); semantic correctness is the only manual item.

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references (`tests/test_write_job_marker.sh`)
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
