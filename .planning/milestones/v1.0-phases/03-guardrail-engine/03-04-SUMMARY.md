---
phase: 03-guardrail-engine
plan: "04"
subsystem: wiring
tags: [cron, post-install, clear-halt, pipeline, guardrail-engine, cleanup]
dependency_graph:
  requires: ["03-02", "03-03"]
  provides: ["guardrail-status.json seeding", "cron pipeline wiring", "halt clear utility", "budget-check.sh removal"]
  affects: ["scripts/cron.sh", "scripts/post-install.sh", "scripts/clear-halt.sh"]
tech_stack:
  added: []
  patterns:
    - "atomic write via tempfile.mkstemp + os.replace"
    - "pipeline ordering: run_report then guardrail-check.sh"
    - "audit trail preservation: haltedRule/haltedAt not popped on halt clear"
key_files:
  created: []
  modified:
    - scripts/cron.sh
    - scripts/post-install.sh
    - scripts/clear-halt.sh
  deleted:
    - scripts/budget-check.sh
decisions:
  - "D-20: cron.sh pipeline is run_report then guardrail-check.sh (reversed from legacy budget-check.sh-first ordering)"
  - "D-21: no migration stage in cron.sh"
  - "Pitfall 8: clear-halt.sh targets guardrail-status.json; preserves haltedRule/haltedAt as audit trail"
  - "Pitfall 7: budget-check.sh deleted only after all references verified at zero"
metrics:
  duration: "~3 min"
  completed: "2026-05-31"
  tasks_completed: 2
  files_modified: 4
---

# Phase 03 Plan 04: Guardrail Engine Wiring Summary

Wired the new guardrail scripts into the install and cron pipeline, retargeted the halt-clear utility to guardrail-status.json with atomic write and audit trail preservation, and deleted the legacy budget-check.sh with zero remaining references.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Update cron.sh pipeline and clear-halt.sh target | 482b810 | scripts/cron.sh, scripts/clear-halt.sh |
| 2 | Update post-install.sh and delete budget-check.sh | a5daa4b | scripts/post-install.sh, (deleted) scripts/budget-check.sh |

## What Was Built

**cron.sh** — Pipeline updated from `budget-check.sh || true` then `run_report` to `run_report || true` then `guardrail-check.sh || true`. This is the D-20 ordering: report ships metering data first, then guardrail-check reads the updated enforcement state from Revenium. The old comment block explaining the reversed ordering was removed. `flock -n 9` guard retained.

**clear-halt.sh** — Fully rewritten to target `guardrail-status.json` instead of `budget-status.json`. Uses `tempfile.mkstemp + os.replace` for atomic write (T-03-14 mitigation). Key behavior difference from the legacy version: `haltedRule` and `haltedAt` fields are preserved after halt clear as an audit trail — the old version called `pop('haltedAt', None)` which destroyed the history.

**post-install.sh** — Four targeted changes:
1. chmod loop now includes `common.sh`, `setup-guardrails.sh`, `guardrail-check.sh` and excludes `budget-check.sh`
2. Seed step replaced: now seeds `guardrail-status.json` with `{"halted": false, "lastChecked": null, "rules": []}` via python3; no longer invokes `budget-check.sh` to seed (D-20)
3. AGENTS.md injection updated: now references `guardrail-status.json`, checks `halted` not `exceeded`, instructs the agent to emit the SKILL.md HALT CHECK message from `haltedRule` block
4. Verification section: now checks for `guardrail-check.sh` presence (not `report.sh`)

**budget-check.sh** — Deleted via `git rm` after confirming zero references across all scripts in `scripts/`. `grep -rl budget-check.sh scripts/` returns nothing (Pitfall 7).

## Final Pipeline

```
cron tick (every 1 min)
  └── cron.sh (flock -n 9)
        ├── run_report "$@" || true        # report.sh ships metering data
        └── guardrail-check.sh || true     # reads enforcement state, writes guardrail-status.json
```

## Deviations from Plan

None — plan executed exactly as written.

## Threat Model Coverage

| Threat ID | Mitigation Applied |
|-----------|--------------------|
| T-03-13 | cron.sh wraps guardrail-check.sh with `\|\| true`; flock guard on outer shell |
| T-03-14 | clear-halt.sh writes via tempfile.mkstemp + os.replace; haltedRule/haltedAt preserved |
| T-03-15 | post-install.sh chmods only named scripts under SKILL_DIR/scripts |
| T-03-16 | budget-check.sh deleted AFTER cron.sh/post-install.sh edits; grep gate confirms zero refs |

## Known Stubs

None that affect plan goals. The `guardrail-status.json` placeholder seeded by post-install.sh (`{"halted": false, "lastChecked": null, "rules": []}`) is intentional — it will be replaced by actual enforcement data on the first cron tick after setup.

## Threat Flags

None. No new network endpoints, auth paths, or trust boundary changes introduced by this plan.

## Self-Check: PASSED

- [x] scripts/cron.sh exists and modified
- [x] scripts/clear-halt.sh exists and modified
- [x] scripts/post-install.sh exists and modified
- [x] scripts/budget-check.sh deleted
- [x] Commit 482b810 exists (Task 1)
- [x] Commit a5daa4b exists (Task 2)
- [x] `grep -c budget-check.sh scripts/cron.sh` = 0
- [x] `grep -c budget-status.json scripts/post-install.sh` = 0
- [x] `grep -rl budget-check.sh scripts/` = (empty)
