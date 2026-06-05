---
phase: quick-260605-enh
plan: "01"
subsystem: setup-guardrails
tags: [idempotency, dedup, budget-rules, setup, bash]
dependency_graph:
  requires: []
  provides: [idempotent-budget-rule-creation, deployment-label-in-rule-names]
  affects: [scripts/setup-guardrails.sh, tests/test_setup_guardrails_argv.sh, README.md]
tech_stack:
  added: []
  patterns: [env-passing-python3-heredoc, fail-open-dedup, bash-3.2-compatible]
key_files:
  created: []
  modified:
    - scripts/setup-guardrails.sh
    - tests/test_setup_guardrails_argv.sh
    - README.md
decisions:
  - "Dedup branch uses echo (not warn) for user-visible delete commands so output is captured by 2>&1 in tests and visible without a TTY; warn() also called for log file"
  - "filter value comparison preserves original case (only DIM and OP are uppercased) — server stores the prefix value as-is"
  - "Pipe + heredoc conflict avoided: get JSON passed via GET_JSON env var to python3, not via pipe"
metrics:
  duration: ~25 min
  completed_date: 2026-06-05
  tasks_completed: 3
  files_changed: 3
---

# Quick Task 260605-enh: Idempotent Uniquely-Named Revenium Budget Rules Summary

**One-liner:** `find_existing_rules` + adopt/warn/create dedup branch in `create_rule()` using env-passing python3 heredoc (bash 3.2 safe); label-bearing rule names via `budget_label()` helper using `REVENIUM_BUDGET_LABEL` or `hostname -s`.

## What Was Built

### Task 1: find_existing_rules + dedup branch + label-bearing names (scripts/setup-guardrails.sh)

- **`short_host()`**: portable short hostname resolver — `hostname -s` / `uname -n` / `$HOSTNAME` / `"unknown"`, bash 3.2 safe.
- **`budget_label()`**: returns `REVENIUM_BUDGET_LABEL` if set, else `short_host()`.
- **`find_existing_rules <period> <group_by_arg> [extra_filter]`**: calls `revenium guardrails budget-rules list --output json`, passes result + desired scope via env to python3. Normalizes filter dimension and operator to uppercase, preserves value case. Checks `windowType`/`period` field (accepts either) and `groupBy`. Fail-open: non-JSON or non-zero exit → empty output → caller falls through to create.
- **Dedup branch in `create_rule()`** (runs before the SHADOW_MODE create block):
  - 1 match → adopt (set `RULE_ID`, `RULE_EXIT=0`), fetch current name via env-passed `GET_JSON`, best-effort `budget-rules update --name` if name differs, return without creating.
  - >1 match → `echo` warning + delete commands (one per id), adopt first id, return without creating.
  - 0 matches → fall through to existing create logic unchanged.
- **Label-bearing rule names** at `run_default` (~line 685) and `run_interactive` (~line 877): `"OpenClaw ${period_title} Budget — ${_label}"`. Per-task `task_rule_name` unchanged.
- **`usage()` heredoc**: added `IDEMPOTENCY` and `REVENIUM_BUDGET_LABEL` sections.
- Shadow-mode read-back assertion and all input validators untouched.

### Task 2: Suite C argv tests (tests/test_setup_guardrails_argv.sh)

Inline stub extended:
- `budget-rules list` branch: prints `${STUB_REVENIUM_BUDGET_RULES_JSON:-[]}` and appends `LIST` tag to `ORDER_FILE`.
- New `budget-rules update` case (above `create`): appends `UPDATE` + args to `UPDATE_FILE`, appends `UPDATE` tag to `ORDER_FILE`.
- `budget-rules create` branch: appends `CREATE` tag to `ORDER_FILE`.

`run_interactive()` extended to export `UPDATE_FILE`, `ORDER_FILE`, `STUB_REVENIUM_BUDGET_RULES_JSON`, and accept optional `extra_env` argument.

Suite C (4 tests, 11 assertions):
- **C1**: ORDER_FILE shows `LIST` before first `CREATE` — confirms list-before-create ordering.
- **C2** (a–d): single-match adopt — 0 create invocations, `ruleIds=["existing-1"]`, ≥1 update invocation, update carries `--name`.
- **C3** (a–e): multi-match warn+skip — 0 creates, output warns, both delete commands in stdout, `ruleIds=["existing-1"]`.
- **C4** (a): label in name — `REVENIUM_BUDGET_LABEL=myhost` present in create `--name` arg.

Suites A and B unchanged and green.

### Task 3: README idempotency note (README.md)

Added paragraph after "Setup is atomic" covering:
- Idempotent adopt on re-run / fresh VM
- Multi-duplicate warning + manual delete commands (no auto-delete)
- `REVENIUM_BUDGET_LABEL` override for human-distinguishable names
- Per-deployment budget scoping flagged as deferred future capability

## Test Results

**bash -n scripts/setup-guardrails.sh**: PASS (parse clean)

**bash tests/test_setup_guardrails_argv.sh**: PASS
- Suite A: 8/8 PASS
- Suite B: 3/3 PASS
- Suite C: 11/11 PASS (new)
- **Total: 22 PASS, 0 FAIL**

## Commits

| Hash | Message |
|------|---------|
| `c75e289` | test(quick-260605-enh-01): add Suite C failing tests for idempotent dedup (RED) |
| `49cc56d` | feat(quick-260605-enh-01): add find_existing_rules, dedup branch, label-bearing names (GREEN) |
| `7952272` | docs(quick-260605-enh-01): add idempotency + REVENIUM_BUDGET_LABEL note to README |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Filter value comparison was incorrectly uppercasing the value portion**
- **Found during:** Task 1 implementation + GREEN test run
- **Issue:** `desired_filters.add(desired_filter_base.upper())` uppercased `openclaw-` to `OPENCLAW-`, while `make_filter_set()` preserved value case, causing no matches ever.
- **Fix:** Added `normalize_filter()` helper that uppercases only DIM and OP, preserves value case.
- **Files modified:** `scripts/setup-guardrails.sh`
- **Commit:** `49cc56d`

**2. [Rule 1 - Bug] Pipe + heredoc conflict in name-fetch subshell**
- **Found during:** Task 1 implementation (C2c/C2d test failures)
- **Issue:** `log_existing_name=$(revenium ... | python3 - <<'PY' ...)` — the heredoc `<<'PY'` provides stdin to python3, winning over the pipe, so the rule get JSON was never read.
- **Fix:** Captured revenium output into `_get_json` var first, then passed it via `GET_JSON` env to python3 (existing codebase env-passing pattern).
- **Files modified:** `scripts/setup-guardrails.sh`
- **Commit:** `49cc56d`

**3. [Rule 1 - Bug] warn() writes to TTY stderr only — delete commands invisible in non-TTY output**
- **Found during:** Task 2 C3c/C3d test failures
- **Issue:** `warn()` in common.sh only writes to fd 2 when `[ -t 2 ]` (TTY check); in test context (no TTY) messages go only to LOG_FILE.
- **Fix:** Used `echo` for user-visible delete command lines (also calling `warn` for log file). This matches the intent that operators see the commands in their terminal output.
- **Files modified:** `scripts/setup-guardrails.sh`
- **Commit:** `49cc56d`

## Known Stubs

None.

## Threat Flags

None — no new network endpoints, auth paths, or trust-boundary schema changes introduced.

## Self-Check

- `scripts/setup-guardrails.sh` exists: FOUND
- `tests/test_setup_guardrails_argv.sh` exists: FOUND
- `README.md` updated: FOUND
- Commits exist: c75e289 (RED), 49cc56d (GREEN), 7952272 (docs) — FOUND
- Tests pass 22/22: CONFIRMED

## Self-Check: PASSED
