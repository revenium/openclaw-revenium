---
phase: 09-guardrail-event-metering
plan: "00"
subsystem: testing
tags: [bash, revenium, guardrails, metering, stub, test-harness]

requires:
  - phase: 08-halt-cancelled-outcome
    provides: stub-revenium.sh patterns and test fixture infrastructure

provides:
  - "Hermetic argv-capture test harness for guardrail event metering (tests/test_guardrail_argv.sh)"
  - "Extended stub-revenium.sh with guardrails subcommand responses and STUB_REVENIUM_GUARDRAILS_FAIL failure switch"
  - "Resolved three open Wave-0 CLI questions (A1/A2/A3) recorded in RESEARCH.md"

affects: [09-guardrail-event-metering]

tech-stack:
  added: []
  patterns:
    - "export-before-run pattern: exported STUB_REVENIUM_ENFORCEMENT_JSON / STUB_REVENIUM_BUDGET_RULES_JSON before run_guardrail_check to avoid shell word-splitting on JSON values with whitespace"
    - "count_grep helper: avoids double-output from grep -c || echo 0 on macOS (test_report_jobs_argv.sh pattern)"

key-files:
  created:
    - tests/test_guardrail_argv.sh
    - .planning/phases/09-guardrail-event-metering/09-00-SUMMARY.md
  modified:
    - tests/stub-revenium.sh
    - .planning/phases/09-guardrail-event-metering/09-RESEARCH.md

key-decisions:
  - "A1: --transaction-id is OPTIONAL (confirmed live) — implementation MUST NOT add it; no synthetic id needed"
  - "A2: Zero token values accepted by Revenium API — no --total-tokens 1 sentinel needed"
  - "A3: COST_LIMIT is a valid --stop-reason enum — no alternate stop-reason fallback needed"
  - "BONUS: --operation-type GUARDRAIL accepted by live API despite undocumented enum — phase design confirmed"
  - "Use export-before-run for JSON fixture env vars rather than passing via run_guardrail_check extra_env args"

patterns-established:
  - "export-before-run: export STUB_REVENIUM_ENFORCEMENT_JSON before run_guardrail_check to avoid word-splitting"
  - "count_grep helper: `grep -c; exit 0` idiom prevents double-output on no-match"

requirements-completed: [GRDEV-01, GRDEV-02, GRDEV-03, GRDEV-04, GRDEV-05]

duration: 25min
completed: 2026-06-04
---

# Phase 09 Plan 00: Wave 0 Test Scaffolding and CLI Question Resolution

**Hermetic argv-capture test harness (tests/test_guardrail_argv.sh) for GRDEV-01..05 plus extended stub-revenium.sh with guardrails CLI responses and failure switch — all three live CLI questions resolved (no fallbacks needed)**

## Performance

- **Duration:** ~25 min
- **Started:** 2026-06-04T02:27:58Z
- **Completed:** 2026-06-04T02:53:00Z
- **Tasks:** 3 completed
- **Files modified:** 3

## Resolved CLI Questions (Wave 0)

These answers were obtained by running `revenium meter completion --help` and a live trial event on host 172.16.1.247 (Team DZxzEl / api.revenium.ai). Recorded here so Wave 1 implementors use the correct flag set.

| Question | Answer | Implementation Impact |
|----------|--------|----------------------|
| **A1: Is `--transaction-id` required?** | **OPTIONAL** — listed in `--help` WITHOUT `(required)`; live call omitting it returned EXIT=0 and created event id `81f8cc86` | **MUST NOT add `--transaction-id`**. No synthetic id needed. |
| **A2: Are zero token values accepted?** | **YES** — `--input-tokens 0 --output-tokens 0 --total-tokens 0` accepted by both dry-run and live API (event created, EXIT=0) | **No `--total-tokens 1` sentinel** needed. Use zero values as designed (D-05). |
| **A3: Is `COST_LIMIT` a valid `--stop-reason` enum?** | **YES** — `--help` lists `(END, END_SEQUENCE, TIMEOUT, TOKEN_LIMIT, COST_LIMIT, COMPLETION_LIMIT, ERROR, CANCELLED)`; live call returned EXIT=0 | **No alternate stop-reason fallback** needed. Use `--stop-reason COST_LIMIT` as designed (D-05). |

**BONUS finding:** `--operation-type GUARDRAIL` is accepted by the live API even though `--help` does NOT list it in the documented enum `(CHAT, GENERATE, EMBED, CLASSIFY, SUMMARIZE, TRANSLATE, OTHER)`. The dry-run body showed `operationType:GUARDRAIL` and the real API created the event with EXIT=0. The phase's `--operation-type GUARDRAIL` design is fully confirmed.

**CLEANUP NOTE:** A trial event (id `81f8cc86-a1d3-4c51-92f8-92105ed7e9bf`, created `2026-06-04T02:25:56Z`) was created during verification — zero-token/zero-cost on test tenant Team DZxzEl. `revenium meter` has NO delete subcommand (events are immutable usage records). The trial event is benign and was left in place.

## Accomplishments

- Resolved all three open Wave-0 CLI questions (A1/A2/A3) — no fallbacks needed, implementation can proceed with the originally designed flag set
- Extended `tests/stub-revenium.sh` with `guardrails --help`, `budget-rules --help`, `enforcement-events --help`, `guardrails enforcement-rules get`, and `guardrails budget-rules list` responses; added `STUB_REVENIUM_GUARDRAILS_FAIL` failure switch; updated `config show` to emit `Team ID:    test-team-id`
- Created `tests/test_guardrail_argv.sh` (591 lines) covering all GRDEV-01..05 assertions across 10 test groups; runs to summary footer without crash; expected RED pre-implementation

## Task Commits

1. **Task 1: Annotate RESEARCH.md Open Questions as RESOLVED** - `325af67` (docs)
2. **Task 2: Extend stub-revenium.sh with guardrails responses + failure switch** - `533860f` (feat)
3. **Task 3: Create test_guardrail_argv.sh covering GRDEV-01..05** - `6a93f0b` (test)

## Files Created/Modified

- `tests/test_guardrail_argv.sh` (created, 591 lines) — 10 test groups covering GRDEV-01..05; hermetic with make_openclaw_home factory, run_guardrail_check helper, argv_vals assertion helper; RED until Wave 1 implements Section M
- `tests/stub-revenium.sh` (modified) — added guardrails subcommand responses, updated config show to emit Team ID, added STUB_REVENIUM_GUARDRAILS_FAIL / STUB_REVENIUM_ENFORCEMENT_JSON / STUB_REVENIUM_BUDGET_RULES_JSON env switches
- `.planning/phases/09-guardrail-event-metering/09-RESEARCH.md` (modified) — `## Open Questions` renamed to `## Open Questions (RESOLVED)`, three entries annotated with definitive answers and cleanup note

## Decisions Made

- `--transaction-id` MUST NOT be added to `_emit_guardrail_event` (A1: optional, confirmed live)
- Zero token values are correct for GUARDRAIL events (A2: accepted by live API)
- `COST_LIMIT` is the correct `--stop-reason` (A3: valid enum, confirmed live)
- Use `export`-before-`run_guardrail_check` for JSON fixture env vars (avoids shell word-splitting on multi-token JSON values when passed as positional `VAR=val` args)
- Use `count_grep` helper with `grep -c; exit 0` idiom (prevents double-output bug from `grep -c || echo 0` on macOS)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed shell word-splitting of JSON fixture values in run_guardrail_check**
- **Found during:** Task 3 (test execution)
- **Issue:** Multi-line JSON passed as `"STUB_REVENIUM_ENFORCEMENT_JSON=${JSON}"` positional arg to `run_guardrail_check` caused shell word-splitting on newlines, triggering `command not found` errors
- **Fix:** Made all fixture JSON single-line; refactored `run_guardrail_check` to use `export STUB_REVENIUM_ENFORCEMENT_JSON` before calling instead of extra_env positional args
- **Files modified:** `tests/test_guardrail_argv.sh`
- **Verification:** Test runs to summary footer without syntax/setup crash

**2. [Rule 1 - Bug] Fixed count_grep double-output from `grep -c || echo 0`**
- **Found during:** Task 3 (GROUP B and D idempotency assertions)
- **Issue:** On macOS, `grep -c` exits 1 (no match) but still prints `0`; `|| echo 0` then produces `0\n0`, causing `[[ 0\n0 -eq 1 ]]` syntax error
- **Fix:** Added `count_grep` helper using `grep -c; exit 0` idiom (mirrors `test_report_jobs_argv.sh` pattern)
- **Files modified:** `tests/test_guardrail_argv.sh`
- **Verification:** GROUP B and D assertions complete without syntax errors

---

**Total deviations:** 2 auto-fixed (both Rule 1 bugs, both in test file)
**Impact on plan:** Both auto-fixes necessary for correctness. No scope creep.

## Issues Encountered

None beyond the two auto-fixed bugs above.

## Known Stubs

None — this plan creates test scaffolding only; no production code was added.

## Threat Flags

None — this plan adds test files only (no new network endpoints, auth paths, or schema changes).

## Next Phase Readiness

- Wave 1 (plan 09-01) can proceed: test harness is ready, all three CLI questions resolved, stub is extended
- `tests/test_guardrail_argv.sh` is the target that Wave 1 must turn GREEN
- The three open questions in RESEARCH.md are now RESOLVED — no mid-implementation flag-set rework needed
- Existing tests (test_report_argv.sh, test_report_jobs_argv.sh) confirmed passing after stub changes

---
*Phase: 09-guardrail-event-metering*
*Completed: 2026-06-04*
