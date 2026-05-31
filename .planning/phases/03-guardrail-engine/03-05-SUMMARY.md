---
phase: 03-guardrail-engine
plan: "05"
subsystem: skill-enforcement
tags: [skill, openclaw, guardrails, halt-check, setup-flow, revenium]

# Dependency graph
requires:
  - scripts/guardrail-check.sh (from 03-02 — writes guardrail-status.json)
  - scripts/setup-guardrails.sh (from 03-03 — Setup Flow delegation target)
provides:
  - SKILL.md: guardrail-native halt check, setup gate, delegated Setup Flow, /revenium command
  - BUDGET-GUARD.md: minimal bootstrap directive referencing guardrail-status.json
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "D-16: HALT CHECK reads guardrail-status.json/haltedRule (not budget-status.json)"
    - "Pattern 7 halt template: Guardrail halt active — rule '[name]' (metricType, windowType) at currentValue of hardLimit hard-limit"
    - "D-17: setup gate on ruleIds non-empty; legacy alertId-only triggers Setup Flow"
    - "D-18: Setup Flow delegates entirely to setup-guardrails.sh --interactive (exit-code contract)"
    - "D-19: /revenium shows per-rule state from guardrail-status.json, offers reconfigure/done"
    - "D-07: BUDGET-GUARD.md minimal directive redirects to SKILL.md for halt string"
    - "SKAF-03: metadata remains single-line JSON in frontmatter"

key-files:
  created: []
  modified:
    - SKILL.md
    - BUDGET-GUARD.md

key-decisions:
  - "HALT CHECK is the primary enforcement gate (OpenClaw hooks unconfirmed — not a backstop)"
  - "Setup gate sole signal is ruleIds non-empty; alertId-only config triggers Setup Flow (D-17)"
  - "Setup Flow delegates entirely to setup-guardrails.sh --interactive — SKILL.md never prompts for budget details"
  - "/revenium offers reconfigure/done only (no reset-budget flow — that is script-owned)"
  - "BUDGET-GUARD.md redirects to SKILL.md HALT CHECK section; no inline halt template (D-07)"

requirements-completed: [GUARD-01, GUARD-02, GUARD-03, GUARD-04, GUARD-05]

# Metrics
duration: ~2min
completed: 2026-05-31
---

# Phase 3 Plan 05: SKILL.md and BUDGET-GUARD.md Guardrail-Native Rewrite Summary

**SKILL.md and BUDGET-GUARD.md rewritten guardrail-native: HALT CHECK reads guardrail-status.json/haltedRule with Pattern 7 halt template, setup gate keys on ruleIds with legacy-alertId note, Setup Flow delegates entirely to setup-guardrails.sh --interactive, /revenium shows per-rule state, and all budget-status.json/alertId enforcement remnants removed**

## Performance

- **Duration:** ~2 min
- **Started:** 2026-05-31T19:37:55Z
- **Completed:** 2026-05-31T19:39:52Z
- **Tasks:** 2/2
- **Files modified:** 2 (SKILL.md, BUDGET-GUARD.md)

## Accomplishments

### Task 1: SKILL.md Rewrite (D-16/D-17/D-18/D-19)

- Rewrote SKILL.md keeping OpenClaw frontmatter with single-line metadata JSON (SKAF-03 compliant) and `name: revenium` preserved
- Updated description to reference guardrail-status.json / guardrail rules
- **HALT CHECK (D-16):** reads `~/.openclaw/skills/revenium/guardrail-status.json`, checks `halted` field, reads `haltedRule` block on halt. Primary enforcement gate (not backstop — OpenClaw hooks unconfirmed). Uses exact Pattern 7 halt template with haltedRule field substitution. Ends with `clear-halt.sh` resume path.
- **Guardrail Check Procedure (GUARD-02):** single path `~/.openclaw/skills/revenium/`; proceeds silently when not halted
- **Setup gate (D-17):** ruleIds non-empty as sole signal; explicit note that legacy alertId-only config also triggers Setup Flow; alertId is deprecated and ignored
- **Setup Flow (D-18):** 4 steps — verify CLI, configure credentials on host if needed, run `setup-guardrails.sh --interactive`, install cron. Documents exit-code contract: exit 0 + `Created N rule(s). config.json updated. ruleIds=[...]` → success; exit 0 + `Cancelled.` → user cancelled; non-zero → failure verbatim
- **`/revenium` command (D-19):** shows ruleIds from config.json and per-rule state (state, currentValue, hardLimit, shadowMode) from guardrail-status.json; shows autonomous mode and halt state; offers `reconfigure` (→ setup-guardrails.sh --interactive) or `done`
- Removed: old 14-step Setup Flow (budget alert API calls / alertId writing), Reset Budget Flow, manual alertId-stripping reconfiguration flow, ALL references to budget-status.json, exceeded, percentUsed, and alertId enforcement

### Task 2: BUDGET-GUARD.md Rewrite (D-05/D-07)

- Kept filename `BUDGET-GUARD.md` (D-05 — no rename)
- Replaced body with minimal D-07 directive: single `## Guardrail Enforcement (Mandatory)` section
- Reads `guardrail-status.json`; handles file missing (proceed with caution), halted false (proceed silently), halted true (redirect to SKILL.md HALT CHECK section for halt string)
- Does NOT inline the halt-string template — redirects to SKILL.md (D-07)
- Removed all budget-status.json and exceeded references

## Task Commits

Each task was committed atomically:

1. **Task 1: Rewrite SKILL.md HALT CHECK, setup gate, Setup Flow, and /revenium command** — `a076e2e` (feat)
2. **Task 2: Rewrite BUDGET-GUARD.md as minimal guardrail bootstrap directive** — `07c41fe` (feat)

## Files Created/Modified

- `SKILL.md` — Rewritten (165 lines, down from 341). Guardrail-native enforcement: reads guardrail-status.json/haltedRule, ruleIds-gated setup flow, delegated Setup Flow, /revenium per-rule display.
- `BUDGET-GUARD.md` — Rewritten (9 lines, down from 10). Minimal bootstrap directive: read guardrail-status.json, redirect to SKILL.md for halt string.

## Decisions Made

- HALT CHECK framed as primary enforcement gate (not defense-in-depth backstop) because OpenClaw hooks are unconfirmed per D-16 and the research notes
- /revenium offers `reconfigure`/`done` only — the Reset Budget flow from Phase 2 is not carried forward, since the Phase 3 approach (delete-and-recreate via the script) is owned entirely by `setup-guardrails.sh --interactive`
- Setup Flow step count reduced from 14 (Phase 2) to 4 (Phase 3) per Open Question 3 resolution: full interactive script delegation collapses API-call steps
- BUDGET-GUARD.md `halted is false` case uses bullet point (not merged with missing case) to match the canonical Pattern from PATTERNS.md

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None — all behavioral instructions are fully specified; no placeholder content or TODO items in SKILL.md or BUDGET-GUARD.md.

## Threat Surface Scan

No new network endpoints introduced. SKILL.md instructs agents to read a local file (`guardrail-status.json`) and delegate to existing scripts. Threat register items from the PLAN.md:

- **T-03-17 (Tampering via guardrail-status.json):** accepted — user has write access to their own HOME; cron rewrites true state every tick
- **T-03-18 (Spoofing via rule name in halt message):** mitigated — SKILL.md instructs verbatim substitution of named fields only (`haltedRule.name`, `haltedRule.metricType`, etc.), no instruction-following from field content; rule name is bounded by 64-char truncation in guardrail-check.sh (T-03-04)
- **T-03-19 (Information disclosure of spend values):** accepted — user's own budget figures; surfacing them is the intended GUARD-05 behavior

## Self-Check

- [x] `SKILL.md` exists at WT_ROOT/SKILL.md
- [x] `BUDGET-GUARD.md` exists at WT_ROOT/BUDGET-GUARD.md
- [x] `grep -q 'guardrail-status.json' SKILL.md` passes
- [x] `grep -q 'setup-guardrails.sh --interactive' SKILL.md` passes
- [x] `grep -q 'haltedRule' SKILL.md` passes
- [x] `grep -q 'ruleIds' SKILL.md` passes
- [x] `grep -c 'budget-status.json|percentUsed' SKILL.md` = 0
- [x] `grep -q 'clear-halt.sh' SKILL.md` passes
- [x] `grep -q 'guardrail-status.json' BUDGET-GUARD.md` passes
- [x] `grep -q 'halted' BUDGET-GUARD.md` passes
- [x] `grep -q 'SKILL.md' BUDGET-GUARD.md` passes
- [x] `grep -c 'budget-status.json|exceeded' BUDGET-GUARD.md` = 0
- [x] SKILL.md metadata is single-line JSON (SKAF-03)
- [x] `name: revenium` preserved in frontmatter
- [x] Commit `a076e2e` exists (Task 1)
- [x] Commit `07c41fe` exists (Task 2)
- [x] SKILL.md min_lines: 60 — actual: 165 lines

## Self-Check: PASSED
