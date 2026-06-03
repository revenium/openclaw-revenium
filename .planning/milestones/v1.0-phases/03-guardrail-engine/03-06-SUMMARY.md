---
phase: 03-guardrail-engine
plan: "06"
subsystem: guardrail-engine
tags: [gap-closure, guard-03, guard-04, cr-02, warn-and-ask, fail-open]
dependency_graph:
  requires: []
  provides: [warned-signal, warnedRules-signal, fail-open-guard]
  affects: [scripts/guardrail-check.sh, guardrail-status.json]
tech_stack:
  added: []
  patterns: [env-passing-heredoc, fail-open-posture, independent-boolean-signal]
key_files:
  created: []
  modified:
    - scripts/guardrail-check.sh
decisions:
  - "warned is an independent signal from halted — a block breach in autonomousMode=false yields halted:false/warned:true; in autonomousMode=true yields halted:true/warned:false"
  - "warnedRules includes ALL non-shadow blocked rules (not just first) so SKILL.md consumer can surface every breached rule"
  - "fail-open guard uses existing warn() helper and exits 0 per the documented contract, not silent swallow"
metrics:
  duration_minutes: 2
  completed: "2026-05-31T20:32:34Z"
  tasks_completed: 2
  files_modified: 1
---

# Phase 03 Plan 06: GUARD-03/04 Producer Signal + CR-02 Fail-Open Guard Summary

Restored the broken warn-and-ask data flow for `autonomousMode=false` by adding `warned` and `warnedRules` to `guardrail-status.json`, and hardened the status-write subshell against failure per the file's documented fail-open posture.

## Tasks Completed

| Task | Commit | Description |
|------|--------|-------------|
| 1: Add warned/warnedRules signal (GUARD-03, GUARD-04) | b5b67f6 | New_warned + warned_rules added to Python heredoc; data document gains 'warned'/'warnedRules' keys |
| 2: Fail-open guard for HALT_OUTPUT subshell (CR-02) | b04079e | `|| { warn "...stale..."; exit 0; }` guard appended after closing `)` |

## What Was Built

**Task 1 — GUARD-03/04 producer signal:**

In the `(G)` Python heredoc inside `guardrail-check.sh`, after `new_halted = autonomous and any_blocked` is derived (line 212), a separate and independent warn signal is computed:

```python
new_warned = (not autonomous) and any_blocked
```

A `warned_rules` list is built containing all non-shadow blocked rules, using the same field set as `halted_rule` (`ruleId`, `name`, `metricType`, `windowType`, `currentValue`, `hardLimit`). When `new_warned` is false, `warned_rules` is an empty list.

Two new keys are added to the `data` document written to `guardrail-status.json`:
- `'warned': new_warned` — true only when `autonomousMode=false` and at least one non-shadow rule is in block state
- `'warnedRules': warned_rules` — all non-shadow blocked rules for the SKILL.md consumer (plan 03-07)

The existing `halted`/`haltedAt`/`haltedRule` derivation is untouched.

**Task 2 — CR-02 fail-open guard:**

The closing `)` of the `HALT_OUTPUT=$( ... PY )` command substitution now has:

```bash
) || { warn "guardrail status update failed — status file may be stale"; exit 0; }
```

Under `set -euo pipefail`, a Python write failure (disk-full, permissions error) previously caused the script to exit non-zero, violating the file's documented fail-open contract. The guard produces a warn log line (observable by cron operators) and exits 0.

## Verification

All acceptance criteria met:

- `bash -n scripts/guardrail-check.sh` exits 0
- `grep -c "new_warned" scripts/guardrail-check.sh` = 3 (>= 2 required)
- `grep -c "'warnedRules'" scripts/guardrail-check.sh` = 1
- `grep -c "'warned'" scripts/guardrail-check.sh` = 1
- `grep -cE '\)\s*\|\| \{ *warn' scripts/guardrail-check.sh` = 1
- `exit 0` count increased from 10 to 11 (new fail-open path)
- Guard line (333) > HALT_OUTPUT line (123) — guard is outside heredoc body
- Behavioral staging: `autonomousMode=false` + block rule → `halted:false, warned:true, warnedRules[0].name=OpenClaw Daily Budget`
- Behavioral staging: `autonomousMode=true` + block rule → `halted:true, warned:false, warnedRules:[]`

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None. The `warned` and `warnedRules` fields are computed from live API data (enforcement-rules response) and written to `guardrail-status.json` on every cron tick.

## Threat Flags

None. This plan modifies an existing file to add a new JSON field to an already-written status file. No new network endpoints, auth paths, or trust boundaries were introduced.

## Self-Check: PASSED

- `scripts/guardrail-check.sh` — file exists and syntax checks pass
- Commit `b5b67f6` — verified in git log
- Commit `b04079e` — verified in git log
- `warned` field in data document at line 292
- `warnedRules` field in data document at line 293
- `new_warned` computed at line 218, referenced at lines 223 and 292
- fail-open guard at line 333
