---
phase: 03-guardrail-engine
plan: "07"
subsystem: guardrail-engine
tags: [guardrail, warn-and-ask, skill, setup, gap-closure, GUARD-03, GUARD-04, CR-01]
dependency_graph:
  requires: [03-06]
  provides: [GUARD-03, GUARD-04, GUARD-05, CR-01]
  affects: [SKILL.md, scripts/setup-guardrails.sh]
tech_stack:
  added: []
  patterns: [warn-and-ask, three-way evaluate branch, fail-safe config clear]
key_files:
  modified:
    - SKILL.md
    - scripts/setup-guardrails.sh
decisions:
  - "Warn branch placed between halted and silent-proceed cases; ordering is halted → warned → silent to preserve GUARD-02 regression safety"
  - "write_rule_ids_to_config '[]' called before deletion loop so that any create_rule failure leaves ruleIds empty, re-triggering Setup Flow"
  - "warnedRules entries mirror haltedRule field vocabulary (name/metricType/windowType/currentValue/hardLimit) for consistent user-facing messages"
metrics:
  duration: "~16 minutes"
  completed: "2026-05-31T20:32:23Z"
  tasks_completed: 2
  files_changed: 2
---

# Phase 03 Plan 07: GUARD-03/04 Warn-and-Ask Consumer + CR-01 ruleIds Clear Summary

SKILL.md gained a three-way evaluate branch that reads `warned`/`warnedRules` from guardrail-status.json and asks the user for permission before continuing when in warn-and-ask mode; setup-guardrails.sh now clears `ruleIds` before the deletion loop in the recreate path so a failed re-create cannot leave stale IDs in config.json.

## Tasks Completed

| Task | Description | Commit |
|------|-------------|--------|
| 1 | Add warn-and-ask branch to SKILL.md Guardrail Check Procedure (GUARD-03/04/05) | 3d2b1b4 |
| 2 | Clear ruleIds before rule deletion in recreate branch of setup-guardrails.sh (CR-01) | 6d4af6e |

## What Was Built

### Task 1 — SKILL.md warn-and-ask branch

The Guardrail Check Procedure in SKILL.md now has a three-way evaluate branch:

1. `halted is true` — existing HALT CHECK behavior unchanged (byte-for-byte)
2. `else if warned is true` — NEW: warn-and-ask branch
3. `else` — proceed silently (GUARD-02 behavior, unchanged)

The new warn-and-ask branch instructs the agent to:
- Read the `warnedRules` array from guardrail-status.json
- For each entry, emit a spend-context warning: "Budget warning — rule '[name]' ([metricType], [windowType]) at [currentValue] of [hardLimit] hard-limit."
- Ask the user for permission to continue before making any tool calls
- Wait for the user's answer; stop if declined, proceed only if granted

Step 2 ("Parse the status") was updated to extract `halted`, `warned`, and `warnedRules` from the JSON.

### Task 2 — setup-guardrails.sh CR-01 fix

In the `[r]ecreate` branch of `run_interactive()`, added a call to `write_rule_ids_to_config '[]'` immediately after `cur_rule_ids_raw` is captured and before the deletion loop. This ensures:
- If `create_rule` later fails and the script `exit 1`s, `config.json` already shows `ruleIds: []`
- The next SKILL.md setup gate check correctly sees an empty `ruleIds` and re-triggers the Setup Flow
- The `alertId` field is preserved (the helper reads existing config and only replaces `ruleIds`)
- An `info` log line was added for operator visibility

## Deviations from Plan

None — plan executed exactly as written.

## Success Criteria Verification

- GUARD-03 satisfied: `warnedRules` entries surface spend context (name, metricType, windowType, currentValue, hardLimit) in the warn message
- GUARD-04 satisfied: agent explicitly asks "Do you want me to proceed anyway, or stop?" and waits before continuing
- GUARD-05 satisfied: per-rule spend-context warning line with currentValue vs hardLimit framing
- GUARD-02 not regressed: `warned:false` + `halted:false` branch still says "Proceed silently" — unchanged
- CR-01 resolved: `write_rule_ids_to_config '[]'` called at line 493, before the deletion loop at line 498
- `bash -n scripts/setup-guardrails.sh` exits 0

## Known Stubs

None — all behavior wired to real data sources (guardrail-status.json warnedRules array).

## Threat Flags

None — no new network endpoints, auth paths, or schema changes introduced. Changes are prose instructions (SKILL.md) and an existing helper call (setup-guardrails.sh).

## Self-Check: PASSED

| Item | Result |
|------|--------|
| SKILL.md exists | FOUND |
| scripts/setup-guardrails.sh exists | FOUND |
| 03-07-SUMMARY.md exists | FOUND |
| commit 3d2b1b4 exists | FOUND |
| commit 6d4af6e exists | FOUND |
