---
quick_id: 260604-qo0
slug: job-outcome-converted
description: Job "Outcome Type" stuck at PENDING — map SUCCESS arcs to CONVERTED
date: 2026-06-04
status: complete
commit: 532e3b7
---

# Quick Task 260604-qo0 — Summary

**One-liner:** A successful agentic job now closes with `--outcome-type CONVERTED`, so its Revenium "Outcome Type" reflects CONVERTED instead of being stuck at the PENDING default — ported from the Hermes plugin's SUCCESS→CONVERTED mapping.

## Root cause

`scripts/report.sh`'s in-loop `jobs outcome` call passed only `--result <SUCCESS|FAILED|CANCELLED> --quiet` and never `--outcome-type` (decision **D-07**, "execution-result-only", which deferred business-outcome reporting to **JOUT-01**). Revenium's two axes are independent: `--result` is the execution result; `--outcome-type` is the business outcome. With no `--outcome-type` sent, the job's Outcome Type stayed at its `PENDING` default forever. The Hermes reference (`hermes-revenium/.../hermes-report.sh:1212-1224`) sets `--outcome-type CONVERTED` on SUCCESS only.

## Changes

- **`scripts/report.sh`** (in-loop outcome block, ~line 1077): append `--outcome-type CONVERTED` to `outcome_cmd` when `job_status == "SUCCESS"`. FAILED/CANCELLED unchanged; halt-path CANCELLED outcomes (lines ~1348, ~1400) untouched. Updated the stale "D-07: NO --outcome-type ever" comments to describe the SUCCESS→CONVERTED mapping.
- **`tests/test_report_jobs_argv.sh`** (GROUP A, J1 SUCCESS + J2 FAILED + J3 CANCELLED): replaced the old "no `--outcome-type` token EVER" assertion with two assertions — exactly **1** `--outcome-type` token (SUCCESS arc only) and its value is `CONVERTED`.

## Verification

Full bash test suite green after the change:
- `test_report_jobs_argv.sh`: **72 passed, 0 failed** (incl. 2 new JOUT-01 assertions)
- `test_report_argv.sh` 10/10, `test_report_tool_argv.sh` 23/23, `test_guardrail_argv.sh` 18/18, `test_write_job_marker.sh` 18/18, `test_write_marker.sh` 12/12, `test_setup_guardrails_argv.sh` 11/11.

The added SUCCESS-only token broke no count-based assertions elsewhere.

## Notes / decision change

- This pulls the SUCCESS→CONVERTED slice of **JOUT-01** forward and reverses **D-07** for SUCCESS arcs. The rest of JOUT-01 (`--outcome-value`, `--outcome-currency`, ROI/conversion metrics) remains deferred and out of scope.
- Executed inline (no planner/executor subagents) — the fix was fully scoped by upfront investigation against the Hermes reference and the live `revenium jobs outcome --help`.
- Live confirmation that a SUCCESS job renders "Converted" in the Revenium dashboard (host 172.16.1.247) is the remaining manual check.
