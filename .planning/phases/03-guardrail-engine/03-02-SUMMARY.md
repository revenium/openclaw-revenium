---
phase: 03-guardrail-engine
plan: "02"
subsystem: infra
tags: [bash, python3, guardrails, cron, shell, guardrail-check.sh]

# Dependency graph
requires:
  - scripts/common.sh (from 03-01)
provides:
  - scripts/guardrail-check.sh implementing the full guardrail enforcement cron stage
  - guardrail-status.json schema (Pattern 6 fields documented below)
affects: [03-04, 03-05]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "D-13 silent-exit guard: bare exit 0 before all warn-logging code when ruleIds absent/empty"
    - "D-14 atomic write: tempfile.mkstemp + os.replace in same directory"
    - "D-15 name-join: integer ruleId (enforcement-rules) -> string-hash (budget-rules list) via rule name field"
    - "D-09 shadow exclusion: shadowMode:true rules tracked in rules[] but excluded from halt decision"
    - "D-11 transition-only halt notification: HALT_TRANSITION flag gates openclaw message send"
    - "D-12 transition-only shadow notification: Pitfall 4 guard (pr is None) or (pr.get('state') != 'block')"
    - "_PATH_HEAD save-and-restore pattern: preserves test-injected stub dirs after ensure_path"
    - "Python env-passing heredoc: all python3 calls via KEY=val python3 - <<'PY' (Bash 3.2 safe)"
    - "T-03-04 log-injection mitigation: rule name truncated to 64 chars before logging"

key-files:
  created:
    - scripts/guardrail-check.sh
  modified: []

key-decisions:
  - "guardrail-status.json written atomically via tempfile.mkstemp + os.replace (same-dir rename)"
  - "enforcement-events lookup included (graceful degradation to '(unavailable)' on API failure)"
  - "openclaw message send --channel --target -m used for both halt and shadow notifications"
  - "budget-status.json cleanup runs after atomic write, before notification dispatch"
  - "Full file authored in Task 1 commit; Task 2 commit adds executable bit (chmod +x)"

requirements-completed: [GUARD-01, GUARD-02, GUARD-03, GUARD-04, GUARD-05]

# Metrics
duration: ~4min
completed: 2026-05-31
---

# Phase 3 Plan 02: guardrail-check.sh Cron Enforcement Stage Summary

**guardrail-check.sh authored with full D-09/D-11/D-12/D-13/D-14/D-15 implementation: silent-exit guard, shadow exclusion, transition-only notifications, name-join reconciliation, and atomic guardrail-status.json write via tempfile.mkstemp + os.replace**

## Performance

- **Duration:** ~4 min
- **Started:** 2026-05-31T19:30:00Z
- **Completed:** 2026-05-31T19:33:57Z
- **Tasks:** 2/2
- **Files modified:** 1 (scripts/guardrail-check.sh — created)

## Accomplishments

- Created `scripts/guardrail-check.sh` (421 lines) porting the Hermes guardrail-check.sh with three substitution categories: OpenClaw paths, agent name, notification command
- Implemented D-13 silent-exit guard BEFORE all warn-logging code (Pitfall 6 prevention)
- Implemented D-14 atomic write: tempfile.mkstemp in same directory + os.replace
- Implemented D-15 name-join: builds `name_to_string_id` from budget-rules list to reconcile integer ruleId (enforcement-rules API) with string-hash ruleId (config.json/budget-rules)
- Implemented D-09 shadow exclusion: shadowMode:true rules appear in rules[] with their state but never set halted:true
- Implemented D-11 halt transition detection: halt notification fires only when prev_halted=false and new_halted=true
- Implemented D-12 shadow transition detection: Pitfall 4 guard `(pr is None) or (pr.get('state') != 'block')`
- Applied T-03-04 log-injection mitigation: `rule_name = (r.get('name') or '')[:64]`
- Added enforcement-events lookup with graceful degradation (EVENT_TS/EVENT_SUMMARY fallback to '(unavailable)')
- Added legacy budget-status.json cleanup after successful atomic write
- Notification dispatch via `openclaw message send --channel --target -m` (D-10, confirmed flags from 03-01-SUMMARY)

## Task Commits

Each task was committed atomically:

1. **Task 1: Preflight, fetch, silent-exit guard, and full state-derivation** - `9a514e3` (feat)
2. **Task 2: Executable bit + Task 2 criteria verification** - `bfa7ef5` (feat)

## guardrail-status.json Schema (Pattern 6 — canonical fields for Plan 03-05 reference)

```json
{
  "halted": false,
  "autonomousMode": true,
  "lastChecked": "2026-05-31T12:00:00.000000+00:00",
  "haltedAt": "2026-05-31T11:55:00.000000+00:00",
  "haltedRule": {
    "ruleId": "d5jng5",
    "name": "OpenClaw Daily Budget",
    "metricType": "TOTAL_COST",
    "windowType": "DAILY",
    "currentValue": 5.12,
    "hardLimit": 5.00
  },
  "rules": [
    {
      "ruleId": "d5jng5",
      "name": "OpenClaw Daily Budget",
      "metricType": "TOTAL_COST",
      "windowType": "DAILY",
      "groupBy": "AGENT",
      "currentValue": 5.12,
      "warnThreshold": 4.00,
      "hardLimit": 5.00,
      "state": "block",
      "shadowMode": false,
      "lastChecked": "2026-05-31T12:00:00.000000+00:00"
    }
  ]
}
```

**Field notes for Plan 03-05 (SKILL.md/BUDGET-GUARD.md):**
- `halted` — boolean, top-level halt gate
- `haltedRule.name` — use in halt message template
- `haltedRule.metricType` — e.g. TOTAL_COST
- `haltedRule.windowType` — e.g. DAILY
- `haltedRule.currentValue` — current spend
- `haltedRule.hardLimit` — the limit that was breached
- `haltedAt` — ISO timestamp only present when `halted: true`
- `rules[].shadowMode` — true means observe-only, never halts
- `rules[].state` — "block" | "warn" | "ok"

## Files Created/Modified

- `scripts/guardrail-check.sh` — Created (421 lines). Cron enforcement stage that polls revenium guardrails enforcement-rules get and writes guardrail-status.json atomically. Sources common.sh for all path constants.

## Decisions Made

- Authored full file atomically in Task 1 commit rather than splitting preflight from state-derivation; sections are tightly coupled (HALT_OUTPUT variable spans both logical halves). Task 2 commit adds executable bit.
- Included enforcement-events lookup (section J from Hermes) since the halt message template in PATTERNS.md includes `Event: [${EVENT_TS}] ${EVENT_SUMMARY}` — omitting it would produce an incomplete notification.
- `[:64]` truncation applied at Python assignment time (`rule_name = (r.get('name') or '')[:64]`), not at log-call time, ensuring the truncated name flows into `new_rules[]` (state file) and all downstream uses consistently.

## Deviations from Plan

### Minor: Full file authored in single Task 1 commit

**Found during:** Task 1
**Issue:** Tasks 1 and 2 both target `scripts/guardrail-check.sh`. The sections (preflight vs state-derivation) are tightly coupled — the Python heredoc captures HALT_OUTPUT which the bash sections below it parse. Writing them separately would require stub commits that could leave the script in a non-runnable state.
**Fix:** Authored the complete 421-line file in Task 1 commit. Task 2 commit applies `chmod +x` and verifies all Task 2 acceptance criteria pass.
**Impact:** Both tasks are satisfied; no functionality difference.

## Threat Surface Scan

No new network endpoints introduced. guardrail-check.sh uses pre-existing revenium and openclaw CLIs. The threat model from PLAN.md (T-03-04 through T-03-08) is fully addressed:
- T-03-04: `[:64]` truncation applied
- T-03-05: atomic write via tempfile.mkstemp + os.replace
- T-03-06: MSG constructed via quoted bash variable expansion, no eval
- T-03-07: all failure paths exit 0
- T-03-08: guardrail-status.json contains no secrets

## Self-Check

- [x] `scripts/guardrail-check.sh` exists at WT_ROOT/scripts/guardrail-check.sh
- [x] `bash -n scripts/guardrail-check.sh` exits 0
- [x] Commit `9a514e3` exists (Task 1)
- [x] Commit `bfa7ef5` exists (Task 2)
- [x] 421 lines (> min_lines: 120)
- [x] D-13 silent exit (line 51) precedes first warn call (line 59)
- [x] `source.*common.sh` pattern present
- [x] All guardrails commands use `--output json`
- [x] `os.replace` atomic write present
- [x] `[:64]` log-injection truncation present
- [x] `openclaw message send --channel --target -m` present
- [x] `HALT_TRANSITION` gate present (not bare halted check)

## Self-Check: PASSED
