---
phase: 15
plan: "06"
subsystem: plugin-gate
tags: [gate, transcript-scan, persistence, fail-open, tdd]
dependency_graph:
  requires: [15-05]
  provides: [B-05-transcript-scan, WR-01-fix, CR-01-fix]
  affects: [plugin/src/gate.js, plugin/src/index.ts, plugin-nemoclaw/src/gate.js, plugin-nemoclaw/src/index.ts, scripts/post-install-nemoclaw.sh]
tech_stack:
  added: []
  patterns: [transcript-scan, union-observation-sources, fail-open-boundary, TDD-RED-GREEN]
key_files:
  created:
    - .planning/phases/15-per-turn-enforcement-plugin/15-B05-SCHEMA-PROBE.md
  modified:
    - scripts/post-install-nemoclaw.sh
    - plugin/src/gate.js
    - plugin/src/index.ts
    - plugin-nemoclaw/src/gate.js
    - plugin-nemoclaw/src/index.ts
    - plugin-nemoclaw/dist/gate.js
    - plugin-nemoclaw/dist/index.js
    - plugin/src/index.test.js
    - plugin-nemoclaw/src/index.test.js
decisions:
  - "transcript in 2nd positional of safeBeforeAgentFinalize (not opts) to avoid collision with existing logger opts object"
  - "scanTranscriptForExec fails open with NO_EVIDENCE on any error — never throws"
  - "B-05 scan is Source 3 (only reached when in-process Sets and disk both empty) to preserve existing path priority"
  - "MARKER_INVOKE regex reused for transcript-scan marker detection (same discipline as before_tool_call path)"
  - "before_agent_finalize does NOT fire for openclaw agent --json CLI runs — tests must call handler directly"
metrics:
  duration: "~90 minutes (continuation from prior context)"
  completed: "2026-06-10T16:28:22Z"
  tasks_completed: 5
  files_modified: 9
---

# Phase 15 Plan 06: Gap-Closure (CR-01, WR-01, B-05) Summary

## One-liner

CR-01 `|| true` guard in post-install script, WR-01 `persistRunState(runId, markedTaskRuns.has(runId))` fix, and B-05 Nemotron transcript-scan via `scanTranscriptForExec()` unioning three observation sources in `handleBeforeAgentFinalize`.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | B-05 live schema probe | `903daac` | 15-B05-SCHEMA-PROBE.md (created) |
| 2 | CR-01 `|| true` guard | `e071085` | scripts/post-install-nemoclaw.sh |
| 3a RED | WR-04 failing tests | `8653eef` | plugin/src/index.test.js |
| 3b GREEN | WR-01 persist fix | `489f5ec` | plugin/src/gate.js |
| 4a RED | B-05 transcript-scan failing tests | `61d4d66` | plugin/src/index.test.js |
| 4b GREEN | B-05 transcript-scan implementation | `a587c7a` | plugin/src/gate.js, plugin/src/index.ts, plugin-nemoclaw/src/index.ts |
| 5 | D-06 sync + nemoclaw test ports | `25bbd95` | plugin-nemoclaw/src/gate.js, plugin-nemoclaw/src/index.ts, plugin-nemoclaw/dist/*, plugin-nemoclaw/src/index.test.js |

## Verification

- `plugin/src/index.test.js`: 52/52 tests pass
- `plugin-nemoclaw/src/index.test.js`: 57/57 tests pass
- `diff -q plugin/src/gate.js plugin-nemoclaw/src/gate.js`: IDENTICAL (D-06 invariant)

## Gaps Closed

### CR-01 — Gate A `_prompt_chars` pipeline fails under `set -euo pipefail`

**File:** `scripts/post-install-nemoclaw.sh` lines 230-231

**Before:**
```bash
_prompt_chars=$(echo "${_prompt_json}" | grep -oE '"promptChars"[^,}]*' | grep -oE '[0-9]+' | head -1)
```

**After:**
```bash
_prompt_chars=$(echo "${_prompt_json}" | grep -oE '"promptChars"[^,}]*' | grep -oE '[0-9]+' | head -1 || true)
```

When the agent JSON lacks a `promptChars` field, grep exits non-zero, causing an opaque subshell failure under `set -euo pipefail`. The `|| true` makes the pipeline's exit code always zero — the variable gets set to empty string, and the downstream skip-guard (`if [ -z "$_prompt_chars" ]`) handles the no-field case cleanly.

### WR-01 — `persistRunState(runId, false)` unconditionally downgrades marked:true

**File:** `plugin/src/gate.js` (non-string-command exec path)

**Before:**
```js
persistRunState(runId, false);
```

**After:**
```js
persistRunState(runId, markedTaskRuns.has(runId));
```

On the non-string-command guard branch, the old code always wrote `marked:false` to disk, overwriting a prior `marked:true` from a write-marker.sh invocation. After `nemoclaw recover` + `resetState()` clears in-process Sets, the disk read returned `marked:false` → spurious revise for an already-classified run (WR-04 regression). Fix: use the current in-process state to determine the marked value.

### B-05 — Nemotron routes exec via `tool_search_code`, bypassing `before_tool_call`

**Schema confirmed:** `event.messages[N].message.content[M].arguments.code` containing `"openclaw:core:exec"` where `content[M].name === "tool_search_code"` and `content[M].type === "toolCall"`. See 15-B05-SCHEMA-PROBE.md.

**New function:** `scanTranscriptForExec(transcript)` in `plugin/src/gate.js`
- Walks `event.messages` array
- Finds assistant toolCall entries with `name === "tool_search_code"`
- Checks `arguments.code` for `"openclaw:core:exec"` (exec evidence)
- Checks same field against `MARKER_INVOKE` regex (marker evidence)
- Returns `{ execFound, markerFound }` — fail-open: any error returns `{ false, false }`

**Extended:** `handleBeforeAgentFinalize(runId, transcript)` now has three observation sources (UNION semantics):
1. In-process Sets (`execRuns` / `markedTaskRuns`) — normal `before_tool_call` path
2. Disk fallback — survives `nemoclaw recover` 
3. Transcript scan (B-05) — Nemotron's `tool_search_code` exec pattern

**Extended:** `safeBeforeAgentFinalize(runId, transcript, opts, impl)` — transcript in 2nd positional (not opts) to avoid collision with the existing logger opts object. Both `index.ts` files updated to use `event?.messages` and pass to `safeBeforeAgentFinalize`.

**Critical finding from live probe:** `before_agent_finalize` does NOT fire for `openclaw agent --json` CLI runs (uses `agent/embedded` runner). The B-05 fix only activates for full messaging-gateway sessions. Tests call `handleBeforeAgentFinalize` directly with constructed transcripts.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Schema assumption in plan was wrong**
- **Found during:** Task 1 (live probe)
- **Issue:** Plan stated transcript was at `ctx.conversation.messages` (second argument). Live probe and type definitions confirmed it is at `event.messages` (first argument, previously `_event` in codebase).
- **Fix:** Updated schema probe document and test helper to use `event.messages` path. Wired `event?.messages` in both `index.ts` files.
- **Files modified:** 15-B05-SCHEMA-PROBE.md, plugin/src/index.test.js, plugin/src/index.ts, plugin-nemoclaw/src/index.ts

**2. [Rule 3 - Blocking] `before_agent_finalize` does not fire for CLI runs**
- **Found during:** Task 1 (live probe — 3 instrumented turns, zero hook firings)
- **Issue:** `openclaw agent --json` uses `agent/embedded` runner which skips gateway lifecycle hooks. Cannot capture live hook firing to validate schema.
- **Fix:** Used session JSONL files from the shared mount + OpenClaw SDK type definitions to confirm the exact schema. Tests call `handleBeforeAgentFinalize` directly with constructed transcripts (verified correct approach per confirmed schema).
- **Commit:** `903daac`

**3. [Rule 3 - Blocking] `tsc: command not found` during nemoclaw rebuild**
- **Found during:** Task 5
- **Issue:** `plugin-nemoclaw/node_modules/.bin/tsc` not installed (devDependencies not installed in worktree).
- **Fix:** Ran `npm --prefix plugin-nemoclaw install` to install devDependencies. Build succeeded on second attempt.
- **Files modified:** None (build-time fix)

## TDD Gate Compliance

RED/GREEN discipline followed for both WR-01 and B-05:

| Gate | Commit | Description |
|------|--------|-------------|
| RED (WR-04) | `8653eef` | Failing tests for non-string exec downgrade |
| GREEN (WR-01) | `489f5ec` | persistRunState fix — all tests pass |
| RED (B-05) | `61d4d66` | Failing tests for transcript-scan observation |
| GREEN (B-05) | `a587c7a` | scanTranscriptForExec + handler extensions |

## Known Stubs

None. All functionality fully wired; no placeholder data or TODO markers in modified files.

## Threat Flags

None. No new network endpoints, auth paths, file access patterns, or schema changes introduced. The `scanTranscriptForExec` helper only reads the transcript array that was already being passed to `before_agent_finalize` — no new data access surface. The T-11 injection mitigation (static instruction string, no transcript content interpolation) was verified by dedicated test.

## Self-Check: PASSED

- `scripts/post-install-nemoclaw.sh` exists and contains `|| true` guard: FOUND
- `plugin/src/gate.js` contains `scanTranscriptForExec`: FOUND
- `plugin/src/index.ts` contains `event?.messages`: FOUND
- `plugin-nemoclaw/src/index.ts` contains `event?.messages`: FOUND
- `plugin-nemoclaw/src/gate.js` byte-identical to `plugin/src/gate.js`: CONFIRMED
- Task commits exist: 903daac, e071085, 8653eef, 489f5ec, 61d4d66, a587c7a, 25bbd95 — all in git log
