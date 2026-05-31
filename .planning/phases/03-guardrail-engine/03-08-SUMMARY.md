---
phase: 03-guardrail-engine
plan: "08"
subsystem: guardrail-enforcement
tags: [gap-closure, warn-and-ask, per-turn, agents-md, budget-guard, doc-drift]
dependency_graph:
  requires: [03-06, 03-07]
  provides: [GUARD-03-per-turn, GUARD-04-per-turn]
  affects: [scripts/post-install.sh, BUDGET-GUARD.md, README.md]
tech_stack:
  added: []
  patterns: [warn-and-ask-branch, three-way-halted-warned-silent]
key_files:
  modified:
    - scripts/post-install.sh
    - BUDGET-GUARD.md
    - README.md
decisions:
  - "Warned bullet inserted BETWEEN silent and halt bullets (additive, not replacing) in both injection points"
  - "Warned bullet points at SKILL.md section rather than inlining template (D-07 compliance)"
  - "README budget-status.json → guardrail-status.json replacement was global (all 4 occurrences)"
metrics:
  duration: "~2 minutes"
  completed: "2026-05-31"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 3
---

# Phase 3 Plan 08: Per-turn warn-and-ask wiring + README doc drift Summary

Wired the `warned:true` enforcement branch into both always-on per-turn injection points (post-install.sh AGENTS.md section and BUDGET-GUARD.md), closing the gap where a `halted:false, warned:true` guardrail state caused agents to proceed silently instead of executing the warn-and-ask flow. Fixed README.md doc drift from the deleted `budget-status.json` filename.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add warned:true branch to both always-on injection points | 3801fb0 | scripts/post-install.sh, BUDGET-GUARD.md |
| 2 | Fix README.md doc drift — budget-status.json → guardrail-status.json | 617a21f | README.md |

## What Was Built

### Task 1: warned:true branch in always-on injection points

Both always-on per-turn enforcement surfaces now carry a three-way branch:

1. `halted:true` → emit HALT CHECK message (existing, unchanged)
2. `halted:false` + `warned:true` → execute SKILL.md warn-and-ask flow (NEW)
3. `halted:false` + `warned:false` → proceed silently (existing, unchanged)

**post-install.sh (AGENTS.md section):** The `section` Python string (injected into AGENTS.md at install time) gained a new bullet between the existing silent and halt bullets. The new bullet directs agents to read `warnedRules`, emit per-rule "Budget warning — rule '[name]' ([metricType], [windowType]) at [currentValue] of [hardLimit] hard-limit." lines, ask "Do you want me to proceed anyway, or stop?" and WAIT for the user's answer before any tool call.

**BUDGET-GUARD.md (per-session directive):** The matching warned-true bullet was added between the silent and halted-true bullets. It redirects to SKILL.md's warn-and-ask section (no inlined template, per D-07). The per-session bootstrap directive now mirrors the AGENTS.md injection.

Both edits are additive-only. The `GUARDRAIL_MARKER` string (`## Guardrail Check (Mandatory)`) was not modified; the idempotency guard in post-install.sh re-runs stays intact. The halted-true halt bullets are byte-for-byte unchanged.

### Task 2: README.md doc drift

Replaced all 4 stale `budget-status.json` references with `guardrail-status.json`:
- Line 36 (post-install step 6 description)
- Line 97 (How It Works: Token Metering — budget-check.sh sentence)
- Line 113 (How It Works: Budget Enforcement intro)
- Line 149 (Configuration section, cron write description)

## Deviations from Plan

None — plan executed exactly as written.

## Threat Flags

No new security-relevant surface introduced. Changes are prose/markdown edits to existing enforcement directives.

## Known Stubs

None.

## Self-Check: PASSED

- `scripts/post-install.sh` exists and passes `bash -n`
- `BUDGET-GUARD.md` contains `warned` branch
- `README.md` has 0 occurrences of `budget-status.json`
- Commits 3801fb0 and 617a21f present in git log
