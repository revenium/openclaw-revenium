---
phase: 15-per-turn-enforcement-plugin
plan: "04"
subsystem: plugin
status: complete
tags: [persistence, gate-fix, b-05, b-01, ncenf-01, ncenf-02, gap-closure]
dependency_graph:
  requires: [15-01, 15-02, 15-03]
  provides: [B-05-closed-in-code, B-01-closed-in-code]
  affects: [15-05]
tech_stack:
  added: [node:fs (existsSync mkdirSync writeFileSync readFileSync rmSync readdirSync), node:path (join)]
  patterns: [disk-persisted-run-state, fail-open-double-try-catch, runId-sanitization, injectable-test-dir]
key_files:
  created: []
  modified:
    - plugin/src/gate.js
    - plugin/src/index.test.js
    - plugin-nemoclaw/src/gate.js
    - plugin-nemoclaw/src/index.test.js
    - plugin-nemoclaw/dist/gate.js
    - scripts/post-install-nemoclaw.sh
decisions:
  - "Disk persistence uses OPENCLAW_HOME/run-state/<runId>.json mirroring scripts/common.sh base-dir discovery"
  - "setRunStateDir() injectable + resetState() cleans test dir for hermetic isolation"
  - "Gate A threshold 1500 (live evidence 649→1637; margin for prompt drift)"
  - "grep -oE parser for promptChars (POSIX-guaranteed, no jq dependency)"
  - "dist/gate.js manually updated (no tsc in worktree; gate.js is plain ESM)"
metrics:
  duration_mins: 8
  completed_date: "2026-06-09"
  tasks_completed: 3
  files_changed: 6
---

# Phase 15 Plan 04: Gap-Closure (B-05 + B-01) Summary

Disk-persisted exec-run state in gate.js so before_agent_finalize survives nemoclaw recover; Gate A rewritten to assert promptChars (present in 2026.5.22) instead of removed finalPromptText.

## Tasks Completed

| # | Name | Commit | Files Changed |
|---|------|--------|---------------|
| 1 | Persist exec observations across process restarts in plugin/src/gate.js (B-05) | 183cf06 | plugin/src/gate.js, plugin/src/index.test.js |
| 2 | Add persistence tests to both index.test.js suites and regenerate nemoclaw copy | e070b6d | plugin-nemoclaw/src/gate.js, plugin-nemoclaw/src/index.test.js, plugin-nemoclaw/dist/gate.js |
| 3 | Rewrite Gate A to assert promptChars instead of removed finalPromptText (B-01) | 9c654a9 | scripts/post-install-nemoclaw.sh |

## What Was Built

### B-05: Disk-persisted exec-run state (plugin/src/gate.js)

- `setRunStateDir(dir)` — injectable test dir setter; `null` = env-derived default
- `resolveRunStateDir()` — mirrors `scripts/common.sh` OPENCLAW_HOME discovery (env override → `$HOME/.openclaw`)
- `sanitizeRunId(runId)` — strips everything outside `[A-Za-z0-9._-]`, rejects empty (T-15-RS-01 traversal guard)
- `runStatePath(runId)` — joins sanitized runId + `.json` to base dir
- `persistRunState(runId, marked)` — writes `{exec:true, marked, updatedAt}` with `mode:0o600` (T-15-RS-03), inner try/catch swallows all fs errors (fail-open)
- `handleBeforeToolCall`: after execRuns.add(), calls `persistRunState()` with current marked state
- `handleBeforeAgentFinalize`: in-process path unchanged; disk fallback added — when `!execRuns.has(runId)`, reads run-state file, if `exec:true && !marked` → returns revise action, `marked:true` → pass-through, any read/parse error → pass-through (fail-open)
- `handleAgentEnd`: clears Sets + deletes run-state file best-effort (T-15-RS-04)
- `resetState()`: clears Sets + if `_runStateDirOverride !== null`, cleans dir contents (test isolation only — never touches real OPENCLAW_HOME)

### TDD: New persistence tests (B-05 describe block)

Both `plugin/src/index.test.js` and `plugin-nemoclaw/src/index.test.js` received a `describe("persistence across process restart (B-05)")` block with 7 new tests each:

1. Exec observation writes a run-state file with `exec:true` and numeric `updatedAt`
2. After clearing in-process Sets (simulated restart), `handleBeforeAgentFinalize` reads disk fallback and returns revise action
3. Persisted `marked:true` run passes through after restart (already classified)
4. `handleAgentEnd` deletes the run-state file
5. Path-traversal runId (`../../etc/x`) does not escape the state dir
6. Fail-open: unwritable state dir — `handleBeforeToolCall` doesn't throw, in-process Set still updates
7. Fail-open: `safeBeforeAgentFinalize` doesn't throw when state dir is unwritable

Suite counts: plugin 37 (30 prior + 7 new), plugin-nemoclaw 42 (35 prior + 7 new). All pass.

### B-01: Gate A rewrite (scripts/post-install-nemoclaw.sh)

Replaced the broken Gate A (which grepped for `<revenium-guard>` in a `finalPromptText` field removed in OpenClaw 2026.5.22) with:

```bash
local _min_prompt_chars=1500  # conservative threshold; live evidence: 649 → 1637 (+988)
_prompt_json=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc "openclaw agent --json --message 'ping' 2>/dev/null" ...)
_prompt_chars=$(echo "${_prompt_json}" | grep -oE '"promptChars"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -1)
```

- Fails hard if `_prompt_chars` is empty (field missing) or below 1500
- Error message includes the measured value for diagnosis
- Parser: `grep -oE` (POSIX-guaranteed; no `jq` dependency)
- Gate B (`plugins inspect`) unchanged — remains the independent trust/active corroboration

## Verification Results

```
node --test plugin/src/index.test.js        → 37/37 pass
node --test plugin-nemoclaw/src/index.test.js → 42/42 pass
diff -q plugin/src/gate.js plugin-nemoclaw/src/gate.js → identical (D-06)
bash -n scripts/post-install-nemoclaw.sh → exit 0
grep -c finalPromptText scripts/post-install-nemoclaw.sh → 0
grep -c promptChars scripts/post-install-nemoclaw.sh → 8
```

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Test isolation: outer beforeEach needed shared tmpDir to prevent stale run-state files**

- **Found during:** Task 1 TDD GREEN run
- **Issue:** Non-persistence tests calling `handleBeforeToolCall` now write to `~/.openclaw/run-state/`. Without a tmpDir override, stale `run-aaa-001.json` files from one test leaked into the next test's `handleBeforeAgentFinalize` call, causing the "no exec ran" case to incorrectly return a revise action.
- **Fix:** Added a `SUITE_TMP_DIR` (mkdtempSync) set before all tests; the outer `beforeEach` keeps it active; `resetState()` cleans dir contents when override is set. No production behavior changed.
- **Files modified:** plugin/src/index.test.js (outer beforeEach + after)
- **Commit:** 183cf06

**2. [Rule 2 - Missing] dist/gate.js manually updated since tsc unavailable in worktree**

- **Found during:** Task 2 — bake-directive.js regenerated src/gate.js but dist/gate.js is loaded by the committed dist/index.js at runtime
- **Fix:** Copied src/gate.js to dist/gate.js manually (gate.js is plain ESM with no TypeScript syntax, so no compilation needed beyond the copy)
- **Files modified:** plugin-nemoclaw/dist/gate.js
- **Commit:** e070b6d

## Known Stubs

None — all persistence paths are fully implemented and unit-tested.

## Threat Surface Scan

No new network endpoints, auth paths, or schema changes at trust boundaries introduced. The run-state file is a local JSON file under OPENCLAW_HOME; all threat mitigations (T-15-RS-01 through T-15-RS-05) are applied and unit-tested.

## Self-Check: PASSED

| Item | Status |
|------|--------|
| plugin/src/gate.js | FOUND |
| plugin/src/index.test.js | FOUND |
| plugin-nemoclaw/src/gate.js | FOUND |
| plugin-nemoclaw/src/index.test.js | FOUND |
| plugin-nemoclaw/dist/gate.js | FOUND |
| scripts/post-install-nemoclaw.sh | FOUND |
| 15-04-SUMMARY.md | FOUND |
| commit 183cf06 | FOUND |
| commit e070b6d | FOUND |
| commit 9c654a9 | FOUND |
