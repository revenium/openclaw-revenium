---
phase: 09-guardrail-event-metering
plan: "01"
subsystem: enforcement-metering
tags: [bash, python, revenium, guardrails, metering, ledger, fail-open]

requires:
  - phase: 09-guardrail-event-metering
    plan: "00"
    provides: test harness (tests/test_guardrail_argv.sh), resolved CLI questions A1/A2/A3

provides:
  - "warn-onset transition detection in guardrail-check.sh Python block (state=='warn', not shadowMode)"
  - "HALTED_AT and WARN_TRANSITIONS KEY=value emit lines from Python block"
  - "GUARDRAIL_LEDGER_FILE and JOBS_LEDGER_FILE path constants in common.sh"
  - "Section M: _emit_guardrail_event function + halt/warn/shadow emit calls — fail-open, last section"
  - "tests/test_guardrail_argv.sh GREEN: 18/18 assertions pass (GRDEV-01..05)"

affects: [09-guardrail-event-metering]

tech-stack:
  added: []
  patterns:
    - "env-passing heredoc (Bash 3.2 safe): all new Python blocks use VAR=${VAR} python3 - <<'PY' + os.environ['VAR'] inside"
    - "bash-array argv discipline: cmd=(revenium meter completion ...) + cmd+=(--flag val) — never eval/string-join"
    - "fail-open function: _emit_guardrail_event returns 0 on all paths; callers use || true under set -euo pipefail"
    - "ledger dedup gate: grep -qF fixed-string on GUARDRAIL:type:ruleId:marker key; append only on success"
    - "pipe-delimited mktemp loop: mktemp + TRANSITIONS_JSON env-passing heredoc + while IFS= read — no <<< in subshells"

key-files:
  created:
    - .planning/phases/09-guardrail-event-metering/09-01-SUMMARY.md
  modified:
    - scripts/common.sh
    - scripts/guardrail-check.sh

decisions:
  - "A1 (from Wave 0): --transaction-id MUST NOT be added — implementation follows exactly, no synthetic id"
  - "A2 (from Wave 0): zero token values used as designed — --input-tokens 0 --output-tokens 0 --total-tokens 0"
  - "A3 (from Wave 0): --stop-reason COST_LIMIT used directly — no alternate enum needed"
  - "Section M is the last bash section, strictly after Section L shadow notifications — D-11 ordering preserved"
  - "warn_transitions uses state=='warn' (not 'block') — Pitfall 1 avoided"
  - "warn_transitions excludes shadowMode rules — Pitfall 6 avoided"
  - "JOBS_LEDGER_FILE in common.sh is byte-identical to report.sh line 34 — single physical file"
  - "Shadow emit in Section M uses a separate SHADOW_METER_TMP to not interfere with Section L's SHADOW_TMP"

metrics:
  duration: ~4min
  completed: 2026-06-04
  tasks_completed: 2
  files_modified: 2
---

# Phase 09 Plan 01: Guardrail Event Metering Implementation Summary

**Guardrail event metering via revenium meter completion --operation-type GUARDRAIL: warn-onset detection (state=='warn'), HALTED_AT/WARN_TRANSITIONS emit, Section M _emit_guardrail_event with ledger dedup and fail-open posture — turns Wave 0 RED test GREEN (18/18)**

## Performance

- **Duration:** ~4 min
- **Started:** 2026-06-04T02:45:00Z (approx)
- **Completed:** 2026-06-04T02:49:00Z (approx)
- **Tasks:** 2 completed
- **Files modified:** 2

## Accomplishments

### Task 1 — common.sh + Python block (commit e23cfe6)

- Added `GUARDRAIL_LEDGER_FILE="${OPENCLAW_HOME}/revenium-guardrail.ledger"` and `JOBS_LEDGER_FILE="${REVENIUM_JOBS_LEDGER_FILE:-${OPENCLAW_HOME}/revenium-jobs.ledger}"` to common.sh Phase 9 path constants block (byte-identical to report.sh line 34)
- Added `ORG_NAME=$(read_config_field organizationName)` to Section D config reads in guardrail-check.sh
- Added `warn_transitions` detection loop in the Python heredoc after `shadow_transitions` block — gated on `state == 'warn'` (Pitfall 1: not `'block'`) and `not nr.get('shadowMode', False)` (Pitfall 6), onset guard `(pr is None) or (pr.get('state') != 'warn')`, reuses `prev_rules_by_id` already built
- Added `print(f"HALTED_AT={halted_at}")` inside the `if halt_transition and halted_rule:` block
- Added `print(f"WARN_TRANSITIONS={json.dumps(warn_transitions)}")` always (after SHADOW_TRANSITIONS)

### Task 2 — bash extraction + Section M (commit b6e1cbb)

- Added `WARN_TRANSITIONS_JSON` and `HALTED_AT` sed extraction after `SHADOW_TRANSITIONS_JSON` extraction
- Appended Section M as the last bash section (after Section L `fi` at original line 479)
- `touch "${GUARDRAIL_LEDGER_FILE}" 2>/dev/null || true` at Section M start
- Root session attribution via macOS-portable `ls -t "${SESSIONS_DIR}"/*.jsonl | head -1 | xargs basename | sed 's/\.jsonl$//'` + `get_root_session_id` wrapper
- Open job attribution via env-passing Python heredoc adapting handle_halt's open-job scan (report.sh ~1086–1105): `created = {}` dict (id → line index), `sorted(open_jobs)[-1][1]` returns highest line index (most recently created)
- `_emit_guardrail_event()` function: ledger key `GUARDRAIL:${event_type}:${rule_id}:${onset_marker}`, `grep -qF` dedup gate, bash-array argv with all five token flags 0, `--stop-reason COST_LIMIT`, `--operation-type GUARDRAIL`, conditional `--organization-name` and `--agentic-job-id`, `return 0` on all paths
- Halt emit: `if HALT_TRANSITION=true` in HALT_OUTPUT — uses HALTED_AT as onset marker
- Warn emit: mktemp + env-passing Python loop over WARN_TRANSITIONS_JSON → `while IFS= read -r WARN_RULE_ID` — uses per-tick `now` as onset marker
- Shadow emit: separate SHADOW_METER_TMP to not interfere with Section L's SHADOW_TMP — same pattern as warn

## Task Commits

1. **Task 1: Add ledger constants + warn-onset detection + HALTED_AT/WARN_TRANSITIONS emit** - `e23cfe6`
2. **Task 2: Add bash extraction + Section M _emit_guardrail_event** - `b6e1cbb`

## Test Results

| Test file | Before | After |
|-----------|--------|-------|
| `tests/test_guardrail_argv.sh` | RED (18 failures — no Section M) | **GREEN (18/18)** |
| `tests/test_report_argv.sh` | 10/10 | 10/10 (no regression) |
| `tests/test_report_jobs_argv.sh` | 71/71 | 71/71 (no regression) |

## Files Created/Modified

- `scripts/common.sh` (modified) — Phase 9 path constants block: GUARDRAIL_LEDGER_FILE + JOBS_LEDGER_FILE (2 lines + comments)
- `scripts/guardrail-check.sh` (modified) — ORG_NAME config read, warn_transitions Python block, HALTED_AT/WARN_TRANSITIONS emit, WARN_TRANSITIONS_JSON/HALTED_AT sed extraction, Section M (188 lines)

## Decisions Made

- `--transaction-id` absent per A1 resolution — no synthetic id added
- Zero token values (`--input-tokens 0 --output-tokens 0 --total-tokens 0 --cache-read-tokens 0 --cache-creation-tokens 0`) per A2 resolution
- `--stop-reason COST_LIMIT` per A3 resolution
- Shadow emit in Section M uses a separate `SHADOW_METER_TMP` (not `SHADOW_TMP`) to avoid collision with Section L's temp file variable
- `_guardrail_warn_now` and `_guardrail_shadow_now` captured once before the loop (consistent onset marker for all rules in the same transition batch)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Shadow Section M uses separate temp file variable**
- **Found during:** Task 2 implementation
- **Issue:** Section L already uses `SHADOW_TMP` variable; reusing it in Section M would shadow the existing variable and could cause incorrect cleanup
- **Fix:** Used `SHADOW_METER_TMP` for Section M's shadow loop temp file
- **Files modified:** `scripts/guardrail-check.sh`
- **Impact:** Cosmetic — no behavioral change; both sections were already complete by the time Section M runs

All other implementation followed the plan exactly as written.

## Known Stubs

None — all three emit paths (halt, warn, shadow) are fully wired with real function calls.

## Threat Flags

None — no new network endpoints, auth paths, file access patterns outside the planned scope, or schema changes at trust boundaries. All boundary protections implemented per T-09-01-01 through T-09-01-04 in the plan threat model.

## Self-Check: PASSED

- scripts/common.sh: FOUND
- scripts/guardrail-check.sh: FOUND
- Commit e23cfe6: FOUND
- Commit b6e1cbb: FOUND
