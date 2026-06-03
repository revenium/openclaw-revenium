---
status: partial
phase: 06-job-lifecycle-wiring
source: [06-VERIFICATION.md]
started: 2026-06-03T20:30:00Z
updated: 2026-06-03T20:30:00Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. Live Revenium 409 Conflict String Confirmation
expected: Against staging Revenium, issuing `revenium jobs create --agentic-job-id <id> --quiet` twice with the same ID produces stderr on the second call that matches `grep -qi "409|already.exist|conflict"`, so `report.sh`'s 409-as-success branch (lines 714, 892) classifies the duplicate as idempotent and writes the ledger row.
result: [pending]

### 2. Transient-Failure Job Retry Recovery (CR-01)
expected: A design decision on the durability contract. When a completion succeeds but `jobs create` fails with a transient non-409 error, `failed_count` stays 0, the offset advances to `total_lines`, and the session is skipped on the next tick — so the job is never retried (the "retry next tick" warn at report.sh:724 is misleading). Confirm whether this is an acceptable v1.1 limitation (no double-bill; 409-as-success is the implicit safety net) or whether a `job_work_pending` flag must hold the offset until jobs work succeeds.
result: [pending]

## Summary

total: 2
passed: 0
issues: 0
pending: 2
skipped: 0
blocked: 0

## Gaps
