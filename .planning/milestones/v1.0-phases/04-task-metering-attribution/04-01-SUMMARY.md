---
phase: 04-task-metering-attribution
plan: "01"
subsystem: foundation-contracts
tags: [taxonomy, resolver, test-harness, common-sh, jsonl, trace-01, meter-01]
dependency_graph:
  requires: []
  provides:
    - task-taxonomy.json (8-label vocabulary METER-01)
    - scripts/common.sh Phase-4 constants (TAXONOMY_FILE, MARKERS_DIR, SESSIONS_DIR, REVENIUM_AGENT_PREFIX)
    - scripts/common.sh get_root_session_id() wrapper
    - scripts/get-root-session-id.py JSONL resolver sidecar (TRACE-01)
    - tests/stub-revenium.sh argv-capturing revenium stub
    - tests/fixtures/sessions/*.jsonl session fixtures
    - tests/test_get_root_session_id.py resolver unit tests
  affects:
    - plans 04-02 to 04-04 (consume constants, resolver, and test harness)
tech_stack:
  added:
    - Python stdlib unittest (resolver tests — no install required)
  patterns:
    - NP-2: JSONL childSessionKey reverse-map resolver (PATTERNS.md)
    - Fail-open cron posture (D-05/D-06): never raises, echoes sid on failure
    - max_depth=10 cycle guard (T-04-02)
    - Per-line try/except around json.loads (T-04-01)
    - Cheap raw-line pre-filter before json.loads (NP-2 performance)
    - bash wrapper delegates to Python sidecar (common.sh pattern)
key_files:
  created:
    - task-taxonomy.json (repo root — 8-label task vocabulary, METER-01)
    - scripts/get-root-session-id.py (JSONL resolver sidecar, TRACE-01)
    - tests/stub-revenium.sh (argv-capturing revenium stub, executable)
    - tests/fixtures/sessions/a1b2c3d4-0001-0001-0001-000000000001.jsonl (parent fixture with sessions_spawn)
    - tests/fixtures/sessions/c3d4e5f6-0003-0003-0003-000000000003.jsonl (plain session fixture)
    - tests/test_get_root_session_id.py (7 resolver unit tests, all passing)
  modified:
    - scripts/common.sh (Phase-4 constants + get_root_session_id wrapper)
    - .gitignore (__pycache__ entries added)
decisions:
  - "Fixture files named by UUID (not human-readable) so resolver's basename-as-parent-sid contract resolves correctly (auto-fix during GREEN phase)"
  - "REVENIUM_AGENT_NAME retained alongside REVENIUM_AGENT_PREFIX (backward reference)"
  - "get_root_session_id() wrapper uses fail-open: echoes sid if python3 absent or sidecar fails (D-05/D-06)"
metrics:
  duration: "~4 minutes"
  completed: "2026-06-03"
  tasks_completed: 3
  files_created: 7
  files_modified: 2
---

# Phase 4 Plan 01: Foundation Contracts Summary

**One-liner:** Task taxonomy (8-label JSON), common.sh Phase-4 constants with JSONL resolver wrapper, and a pytest-free unit-tested resolver sidecar establishing the METER-01/TRACE-01 interface contracts for downstream plans.

## What Was Built

### Task 1: task-taxonomy.json + Wave-0 test harness

- `task-taxonomy.json` copied verbatim from the Hermes sibling skill with all 8 canonical labels: `research, analysis, generation, review, code_review, refactor, planning, debugging` (METER-01 satisfied).
- `tests/stub-revenium.sh`: executable argv-capturing stub; downstream integration tests symlink it as `revenium` on PATH and assert captured CLI arguments against `STUB_REVENIUM_ARGV_FILE`.
- `tests/fixtures/sessions/a1b2c3d4-0001-0001-0001-000000000001.jsonl`: parent session fixture with a `sessions_spawn` toolResult line carrying `details.childSessionKey = "agent:main:subagent:b1b2c3d4-0002-0002-0002-000000000002"`.
- `tests/fixtures/sessions/c3d4e5f6-0003-0003-0003-000000000003.jsonl`: plain session with no subagent linkage.

### Task 2: common.sh Phase-4 constants + resolver wrapper

Three additive edits to `scripts/common.sh` (all existing lines unchanged):

1. **Path constants** after `RULES_LOCK_FILE`: `TAXONOMY_FILE`, `MARKERS_DIR`, `SESSIONS_DIR`.
2. **`REVENIUM_AGENT_PREFIX`** beside `REVENIUM_AGENT_NAME` with D-07 comment (metering/filter scheme superseding static AGENT:IS model).
3. **`get_root_session_id()`** bash wrapper: empty-sid guard returns 0; python3-absent guard echoes sid; delegates to `${SKILL_DIR}/scripts/get-root-session-id.py` with `OPENCLAW_HOME` pass-through; fail-open on any error.

### Task 3: get-root-session-id.py JSONL resolver + unit tests (TDD)

**RED commit:** 7 unit tests covering all 5 specified behaviors written first (tests fail — module not yet created).

**GREEN commit:** `scripts/get-root-session-id.py` implemented:
- Builds `child_to_parent` reverse map by scanning all `*.jsonl` in `sessions_dir`
- Cheap raw-line pre-filter (`'"sessions_spawn"' not in line`) before `json.loads`
- Per-line `try/except Exception: continue` (T-04-01 malformed JSONL defense)
- `for _ in range(max_depth)` walk with `child_to_parent.get(current)` (T-04-02 cycle guard)
- Blanket `except Exception: return sid` (fail-open invariant D-05/D-06)
- `__main__` block: exits 0 silently on empty/missing arg; prints resolved sid

**All 7 tests pass:**
1. `test_no_parent_returns_self` — plain session resolves to itself
2. `test_one_hop_child_returns_parent` — child UUID in fixture resolves to parent UUID
3. `test_cycle_terminates_at_max_depth` — A↔B cycle terminates without exception
4. `test_missing_sessions_dir_fails_open` — nonexistent dir returns input sid
5. `test_malformed_jsonl_line_fails_open` — broken JSON lines skipped, returns sid
6. `test_empty_sid_exits_zero` — subprocess exits 0 with no stdout
7. `test_empty_sid_function_returns_empty` — function returns empty string

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixture files renamed to UUID-based names**
- **Found during:** Task 3 GREEN phase (one-hop test failure)
- **Issue:** The plan named fixtures `parent-with-spawn.jsonl` and `plain-session.jsonl`. The resolver uses the JSONL filename basename as the parent session id (per NP-2: `parent_sid = fname[:-len(".jsonl")]`). With human-readable filenames, the resolver returned `"parent-with-spawn"` instead of the UUID `"a1b2c3d4-0001-0001-0001-000000000001"`, causing `test_one_hop_child_returns_parent` to fail.
- **Fix:** Renamed fixtures to `a1b2c3d4-0001-0001-0001-000000000001.jsonl` and `c3d4e5f6-0003-0003-0003-000000000003.jsonl` to match their session id UUIDs.
- **Files modified:** `tests/fixtures/sessions/` (rename only)
- **Commits:** ed651f7

**Note:** The plan's Task 1 automated verify command (`grep -q sessions_spawn tests/fixtures/sessions/parent-with-spawn.jsonl`) references the old filename. The renamed fixture at `tests/fixtures/sessions/a1b2c3d4-0001-0001-0001-000000000001.jsonl` contains the same `sessions_spawn` line; the verify passes against the new path.

## TDD Gate Compliance

- RED gate: `test(04-01)` commit `b793b60` — 7 tests written before implementation, all fail (FileNotFoundError on missing module).
- GREEN gate: `feat(04-01)` commit `ed651f7` — resolver created, all 7 tests pass.
- REFACTOR: not needed (implementation was clean from the start).

## Known Stubs

None. All files deliver their full intended behavior.

## Threat Flags

No new security-relevant surface beyond what the plan's threat model covers. The resolver implementation addresses all STRIDE threats in the plan's register:
- T-04-01: per-line try/except + blanket except (implemented)
- T-04-02: max_depth=10 cycle guard (implemented)
- T-04-03: resolver emits only the UUID suffix — path-traversal guard deferred to 04-02 as planned

## Self-Check: PASSED

All created files exist on disk. All commits verified in git log.

| Item | Status |
|------|--------|
| task-taxonomy.json | FOUND |
| scripts/common.sh (modified) | FOUND |
| scripts/get-root-session-id.py | FOUND |
| tests/stub-revenium.sh | FOUND |
| tests/fixtures/sessions/a1b2c3d4-*.jsonl | FOUND |
| tests/fixtures/sessions/c3d4e5f6-*.jsonl | FOUND |
| tests/test_get_root_session_id.py | FOUND |
| 04-01-SUMMARY.md | FOUND |
| commit a3d1b89 | FOUND |
| commit f1d5199 | FOUND |
| commit b793b60 | FOUND |
| commit ed651f7 | FOUND |
| commit 3c725f8 | FOUND |
