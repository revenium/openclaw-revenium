---
phase: 03-guardrail-engine
plan: "03"
subsystem: guardrail-setup
tags: [bash, openclaw, guardrails, revenium, shell]

# Dependency graph
requires:
  - scripts/common.sh (authored in 03-01)
provides:
  - scripts/setup-guardrails.sh: interactive rule creation; writes ruleIds + autonomousMode to config.json
affects: [03-05]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Two-mode dispatch: default | interactive (no migration mode, D-02)"
    - "Python fcntl.flock LOCK_EX|LOCK_NB for RULES_LOCK_FILE (T-03-11)"
    - "Atomic config.json write via tempfile+os.rename (T-03-10)"
    - "Env-passing heredoc pattern for all python3 calls (bash 3.2 compat, Pitfall 5)"

key-files:
  created:
    - scripts/setup-guardrails.sh
  modified: []

key-decisions:
  - "Migration mode (--from-alert --auto) dropped per D-02/D-03; two-mode dispatch only"
  - "Rule name convention: OpenClaw {Period} Budget (D-23)"
  - "autonomousMode: true=hard-stop, false=warn-and-ask (default); persisted to config.json (GUARD-06)"
  - "Shadow prompt order: after autonomous, before create_rule (D-08)"
  - "D-04: alertId left as orphan — never removed from config.json by write_rule_ids_to_config or write_rule_ids_and_config"
  - "Success output contract: 'Created N rule(s). config.json updated. ruleIds=[...]' (D-18)"
  - "Cancel output contract: 'Cancelled.' (D-18)"

requirements-completed: [GUARD-04, GUARD-06]

# Metrics
duration: ~4min
completed: 2026-05-31
---

# Phase 3 Plan 03: setup-guardrails.sh Summary

**setup-guardrails.sh authored with two-mode dispatch (default|interactive), ASVS V5 input validation, OpenClaw-named rule creation via budget-rules create, and atomic config.json write preserving alertId**

## Performance

- **Duration:** ~4 min
- **Started:** 2026-05-31T19:30:18Z
- **Completed:** 2026-05-31T19:34:00Z
- **Tasks:** 2/2
- **Files modified:** 1

## Accomplishments

- Authored `scripts/setup-guardrails.sh` (619 lines) with two-mode dispatch per D-02: `default` (CLI args) and `interactive` (operator prompts)
- Migration mode (`--from-alert --auto`, `run_migration`, `MIGRATION_NOTIFY`) intentionally absent per D-02/D-03 — zero occurrences
- `validate_hard_limit()` enforces numeric regex `^[0-9]+(\.[0-9]+)?$`; `validate_period()` enforces DAILY/WEEKLY/MONTHLY/QUARTERLY allowlist (T-03-09 ASVS V5)
- `create_rule()` uses verified flag form: `revenium guardrails budget-rules create --output json --filter "AGENT:IS:${REVENIUM_AGENT_NAME}"` — appends `--shadow-mode` when SHADOW_MODE=true
- Rule name convention: `"OpenClaw ${period_title} Budget"` (D-23); zero Hermes references
- `compute_warn_threshold()` computes 80% via python3 float, strips trailing zeros
- `write_rule_ids_to_config()`: atomic tempfile+os.rename; never pops or removes alertId (D-04, T-03-10)
- `write_rule_ids_and_config()`: atomic write of ruleIds + autonomousMode; alertId preserved as orphan
- RULES_LOCK_FILE flock via Python fcntl LOCK_EX|LOCK_NB; warns + exits 0 on contention (T-03-11)
- `run_interactive()`: prompts for hard limit, period, autonomous mode (GUARD-06), shadow mode (D-08) in order per plan spec
- Shadow prompt wording matches D-08 exactly: "Run in shadow mode (observe-only rules, no blocking)?"
- `--shadow-mode` CLI flag accepted for non-interactive invocations (D-08)
- `autonomousMode` written to config.json: true=hard-stop, false=warn-and-ask (GUARD-06)
- Cancellation exits 0 and prints exactly `Cancelled.` (D-18 contract)
- No task-type picker, no TAXONOMY_FILE references (deferred to Phase 4)
- All python3 calls use env-passing heredoc pattern (bash 3.2 compat, Pitfall 5)
- Config.json bootstrapped from empty `{}` on fresh host (no pre-existing file required)

## Contract Lines (for Plan 05 SKILL.md reference)

**Success:** `Created N rule(s). config.json updated. ruleIds=[<id>]`  
**Cancel:** `Cancelled.`  
**Config keys written:** `ruleIds` (string array), `autonomousMode` (boolean)  
**alertId:** preserved as orphan — never removed

## Task Commits

Each task was committed atomically:

1. **Task 1: Core (mode dispatch, validation, rule creation, config write)** — `4b009ce`
2. **Task 2: run_interactive prompts (autonomous, shadow mode)** — `df53a91`

## Files Created/Modified

- `scripts/setup-guardrails.sh` — interactive rule-creation entry point (619 lines)

## Decisions Made

- Migration mode dropped entirely (D-02/D-03): no `run_migration`, no MIGRATION_NOTIFY_FILE, two-mode dispatch only
- `autonomousMode` semantics: `true` → hard-stop on halt (no warn-and-ask); `false` → warn-and-ask (default) — GUARD-06
- alertId left as orphan in config.json on every write path (D-04) — SKILL.md ignores it for setup gate

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None — all prompts are wired to real Revenium API calls; no placeholder data flows to output.

## Threat Flags

None — no new network endpoints or auth paths beyond those in the plan's threat model. All CLI invocations go through the pre-existing `revenium guardrails budget-rules create` command as documented.

## Self-Check: PASSED

- `scripts/setup-guardrails.sh` exists at expected path
- `bash -n scripts/setup-guardrails.sh` exits 0
- Commits `4b009ce` and `df53a91` verified in git log
- All acceptance criteria for Tasks 1 and 2 pass

---
*Phase: 03-guardrail-engine*
*Completed: 2026-05-31*
