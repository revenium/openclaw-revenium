---
phase: 11-structural-marker-enforcement-via-before-agent-finalize-plug
plan: "01"
subsystem: plugin
tags: [plugin, typescript, openclaw, marker-gate, before_agent_finalize, node-test]
dependency_graph:
  requires: []
  provides: [plugin/package.json, plugin/openclaw.plugin.json, plugin/tsconfig.json, plugin/src/index.ts, plugin/src/gate.js, plugin/dist/index.js, plugin/dist/gate.js, plugin/src/index.test.js]
  affects: []
tech_stack:
  added: [TypeScript, node:test, definePluginEntry (openclaw/plugin-sdk/plugin-entry), @types/node, @types/ws]
  patterns: [before_tool_call tracking, before_agent_finalize gate, agent_end cleanup, pure-logic module pattern (gate.js), pre-built ESM artifact]
key_files:
  created:
    - plugin/src/gate.js
    - plugin/src/index.ts
    - plugin/src/index.test.js
    - plugin/dist/index.js
    - plugin/dist/gate.js
    - plugin/package.json
    - plugin/package-lock.json
    - plugin/openclaw.plugin.json
    - plugin/tsconfig.json
    - plugin/.gitignore
  modified: []
decisions:
  - "gate.js / index.ts split: pure gate logic in src/gate.js (plain ESM, no openclaw dep) so node:test can import directly without tsc; index.ts is the thin definePluginEntry wiring layer"
  - "skipLibCheck: true added to tsconfig — openclaw peer type declarations reference @types/node + @types/ws; skipLibCheck prevents noise from third-party declaration files"
  - "test file excluded from dist/ compile via tsconfig exclude: [src/**/*.test.js]; dist/ contains only gate.js and index.js"
  - "resetState() exported from gate.js to allow isolated test state between node:test cases"
  - "REBUILD REQUIRED: any change to plugin/src/index.ts or plugin/src/gate.js requires npm run build in plugin/ + re-commit of dist/"
metrics:
  duration: "~5m"
  completed: "2026-06-05"
  tasks_completed: 3
  tasks_total: 3
  files_created: 10
  files_modified: 0
  commits: 3
---

# Phase 11 Plan 01: Revenium Marker Gate Plugin Summary

Built the `revenium-marker-gate` TypeScript OpenClaw plugin package — a `before_agent_finalize` gate that forces `write-marker.sh` on substantive turns, bounded (maxAttempts: 1) and fail-open, with a committed `dist/index.js` artifact so a host without `tsc` can load the plugin directly.

## What Was Built

### Plugin Package Structure

```
plugin/
  package.json          — ESM package, openclaw.extensions -> ./dist/index.js
  openclaw.plugin.json  — Manifest: id revenium-marker-gate, activation.onStartup: false
  tsconfig.json         — ES2022/ESNext/bundler target, skipLibCheck, allowJs (for gate.js)
  package-lock.json     — Lock file (committed)
  .gitignore            — Ignores node_modules/ only; dist/ is NOT ignored
  src/
    gate.js             — Pure ESM gate logic (no openclaw dep, directly testable)
    index.ts            — definePluginEntry wiring layer importing gate.js
    index.test.js       — 21 node:test cases covering all behavior bullets
  dist/
    gate.js             — Compiled output (tsc --allowJs passthrough)
    index.js            — Compiled TypeScript entry, contains before_agent_finalize
```

### gate.js / index.ts Split

The plan suggested splitting pure logic into a testable module. I implemented:

- `plugin/src/gate.js` — plain ESM, no openclaw dependency. Exports `handleBeforeToolCall`, `handleBeforeAgentFinalize`, `handleAgentEnd`, `resetState`, `execRuns`, `markedTaskRuns`. Tests import this directly without `tsc` or the peer package.
- `plugin/src/index.ts` — thin `definePluginEntry` wiring: `api.on(...)` registrations delegating to gate.js handlers.

This avoids brittle `dist/` imports in tests and keeps the test suite runnable from source at any time.

### Hook Behavior Implemented

**before_tool_call** (NOT a conversation hook — no `allowConversationAccess` needed):
- Checks `toolName === "exec"` OR `toolName === "bash"` (Pitfall 5)
- Coalesces command string: `params.command` first, fallback to `params.code` (A1 open question)
- Guards `typeof cmd === "string"` before `.includes()` (T-11-cmd-read)
- One-time diagnostic log: logs observed `toolName` + `Object.keys(params)` on first exec hit per process (resolves open question A1 from host logs in 11-03)
- Adds `runId` to `execRuns`; adds to `markedTaskRuns` if command includes `write-marker.sh`

**before_agent_finalize** (IS a conversation hook — requires `allowConversationAccess: true`):
- Returns `undefined` when: no runId (fail-open), no exec ran (non-substantive), already in `markedTaskRuns` (already classified)
- Returns `{ action: "revise", reason, retry: { instruction, idempotencyKey: "marker-gate:<runId>", maxAttempts: 1 } }` when exec ran but marker was not written (SC-1)
- Instruction is a STATIC string with no event/conversation data interpolated (T-11-injection mitigation)

**agent_end** (IS a conversation hook — requires `allowConversationAccess: true`):
- Deletes both `runId` entries from both sets (Pitfall 3 leak prevention, T-11-state-leak mitigation)

### Test Suite (21 cases, all passing)

`cd plugin && node --test` exits 0 covering:
- SC-1: revise action returned when exec ran without write-marker.sh
- SC-2: maxAttempts: 1 enforced; undefined on no-runId, non-substantive, already-marked turns
- A1 coalesce: `params.code` fallback correctly adds runId to `markedTaskRuns`
- Pitfall 5: `toolName === "bash"` treated same as `"exec"`
- Non-string params guard: no throw when both `params.command` and `params.code` are non-string
- idempotencyKey format: `marker-gate:<runId>`
- Static instruction: not interpolated with event data
- agent_end cleanup: both sets cleared; other runIds unaffected

### Pre-built dist/ Artifact

`plugin/dist/index.js` is committed to the repo (not gitignored). The host has no `tsc` — the plugin is loaded by openclaw via the `extensions` array pointing to the compiled JS.

**REBUILD REQUIRED**: Any change to `plugin/src/index.ts` or `plugin/src/gate.js` requires:
```bash
cd plugin && npm run build
# then commit dist/gate.js and dist/index.js
```

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Missing @types/node caused tsc build failure**
- **Found during:** Task 3 (npm run build)
- **Issue:** openclaw peer package's own `.d.ts` files reference `NodeJS`, `Buffer`, and `BufferEncoding` namespaces — these require `@types/node` to resolve. The initial build failed with ~100+ TS errors.
- **Fix:** Added `@types/node` (and `@types/ws` — also referenced by openclaw) to `devDependencies`; `package.json` was auto-updated by `npm install --save-dev`.
- **Files modified:** `plugin/package.json`, `plugin/package-lock.json`

**2. [Rule 3 - Blocking] tsconfig needed skipLibCheck + allowJs + test exclusion**
- **Found during:** Task 3 (npm run build)
- **Issue (a):** Even with `@types/node`, third-party declaration files in `node_modules/openclaw/` and `node_modules/openclaw/node_modules/` had further type errors; `skipLibCheck: true` suppresses them (standard practice for plugin consumers).
- **Issue (b):** `gate.js` is a JS file imported by `index.ts`; without `allowJs: true` tsc rejected it with TS7016.
- **Issue (c):** With `allowJs: true` and `include: ["src/**/*.js"]`, the test file was compiled into `dist/`. Fixed by using `include: ["src/**/*.ts"]` only (tsc follows the transitive import to `gate.js`) and adding `exclude: ["src/**/*.test.js"]`.
- **Fix:** Added `skipLibCheck: true`, `allowJs: true`, `checkJs: false` to `compilerOptions`; updated `include`/`exclude` in `plugin/tsconfig.json`.
- **Files modified:** `plugin/tsconfig.json`

## Known Stubs

None. All gate logic is wired through `gate.js` → `index.ts` → `dist/index.js`. The plugin is complete and installable.

The one open question remaining (A1: whether the real exec command arrives as `params.command` or `params.code`) is addressed by the coalesce logic and the one-time diagnostic log — confirmation will come from 11-03 Task 2 E2E host logs.

## Threat Flags

No new threat surface introduced beyond what is in the plan's threat model. All four threats mitigated as designed:
- T-11-injection: instruction is a static string (verified by test case)
- T-11-cmd-read: `typeof cmd === "string"` guard before `.includes()` (verified)
- T-11-state-leak: `agent_end` cleanup tested (verified)
- T-11-fail-open: `undefined` returned on all fail-open paths (verified)

## Self-Check: PASSED

- `plugin/src/gate.js` exists: YES
- `plugin/src/index.ts` exists: YES
- `plugin/src/index.test.js` exists: YES
- `plugin/dist/index.js` exists: YES
- `plugin/dist/gate.js` exists: YES
- `plugin/package.json` exists: YES
- `plugin/openclaw.plugin.json` exists: YES
- Commits exist: f10b638 (scaffold), 7fe429e (source+tests), 9217216 (dist artifact)
- `cd plugin && node --test`: 21 pass, 0 fail
- `git ls-files plugin/dist/index.js`: tracked
- `node --check plugin/dist/index.js`: PASS
- `grep before_agent_finalize plugin/dist/index.js`: found
