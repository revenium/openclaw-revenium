---
phase: 15-per-turn-enforcement-plugin
plan: "03"
subsystem: live-validation
status: checkpoint-pending-human-review
tags: [live-validation, nemoclaw, enforcement-plugin, SC1, SC2, SC3, SC4, SC5, NCENF-01, NCENF-02]
requirements: [NCENF-01, NCENF-02]

dependency_graph:
  requires:
    - plugin-nemoclaw/dist/index.js (Plan 01 artifact — deployed to sandbox)
    - scripts/post-install-nemoclaw.sh (Plan 02 install path)
    - 34.224.27.67 sandbox revenium-spike (live host, running)
  provides:
    - .planning/phases/15-per-turn-enforcement-plugin/15-VALIDATION.md (live validation record, per-criterion)
  affects:
    - Nothing in the codebase — this is a read-only validation plan

tech_stack:
  added: []
  patterns:
    - SSH live-host validation (not local simulation)
    - SSHFS mount-based guardrail-status injection for SC2 test
    - openclaw agent --json --session-id for turn-level evidence capture
    - Diagnostic log extraction for before_tool_call confirmation (gate.js one-time log)
    - promptChars comparison as alternative injection proof (SC1)

key_files:
  created:
    - .planning/phases/15-per-turn-enforcement-plugin/15-VALIDATION.md (Task 1 commit f59a245; Task 2 commit ba3cc40)
  modified: []

decisions:
  - key: sc2-direct-test-after-turn-resolution
    description: "SC2 was initially blocked (B-03) when 45s timeout caused exit 124. After discovering turns complete in ~72s with 120s+ timeout, SC2 was tested and PASSED. The Nemotron model does read guardrail-status.json via tool_search_code and honors halted:true."
  - key: sc3-partial-honest-result
    description: "SC3 marker write did not land end-to-end. before_tool_call fires (log confirmed), but before_agent_finalize revise loop does not trigger because nemoclaw recover creates a new gateway process with an empty in-process execRuns Set. This is an honest blocker (B-05), not a fabricated pass."
  - key: finalPromptText-removed-blocker
    description: "finalPromptText field is absent from openclaw agent --json output in 2026.5.22. Plan 02 Gate A check is structurally broken on this host. Alternative injection proof: promptChars 649→1637 (+988 chars). Recorded as B-01."
  - key: turns-not-infinite-hang
    description: "Initial assessment (Task 1) was that turns hang infinitely. Corrected in Task 2: turns complete in ~70s via nemotron trying tool_search_code variations. Blockers B-02/B-03/B-04 revised accordingly."

metrics:
  duration: "~3 hours (two sessions)"
  completed: "2026-06-09"
  tasks_completed: 2
  tasks_total: 3
  tasks_pending: 1 (checkpoint:human-verify)
  files_created: 1
  files_modified: 0
---

# Phase 15 Plan 03: Live Validation Summary

One-liner: `revenium-enforcement` plugin installed, trusted, and behaviorally validated on live NemoClaw sandbox 34.224.27.67 — SC2 halt-honoring PASSED; SC1/SC5 injection EVIDENCED via promptChars diff and model reasoning; SC3 marker revise loop blocked by in-process state reset across `nemoclaw recover` (B-05).

## What Was Built

No code was written. This plan ran live commands against the sandbox host and recorded observations
in `15-VALIDATION.md`.

### 15-VALIDATION.md (created)

The validation record maps live-host observations to SC1-SC5:

**SC1 — Per-turn directive injection:** PARTIALLY EVIDENCED
- Plugin install: `openclaw plugins install --force /sandbox/.openclaw/extensions/revenium-enforcement` → exit 0, "Installed plugin: revenium-enforcement"
- Gateway startup log: `9 plugins: ... revenium-enforcement ...` (trusted, loaded)
- `openclaw plugins inspect revenium-enforcement`: Status: loaded, Origin: global, `allowConversationAccess: true`
- promptChars injection proof: 649 chars (no plugin) vs 1637 chars (with plugin) = +988 chars injected
- Model reasoning in session log shows BUDGET-GUARD directive text read on every turn
- BLOCKER B-01: `finalPromptText` field removed from `openclaw agent --json` in 2026.5.22 — Gate A check in Plan 02 is broken

**SC2 — Halt-honoring:** PASSED
- Wrote `{"halted": true, "haltedRule": "manual-test-halt", ...}` to guardrail-status.json via SSHFS mount
- Session sc2halted2 reply: `"Guardrail halt active — rule 'manual-test-halt' (, , ) at  of  hard-limit. To resume: bash ~/.openclaw/skills/revenium/scripts/clear-halt.sh"`
- Model honored halted:true and did NOT proceed to answer the user question

**SC3 — Marker attribution:** PARTIALLY EVIDENCED
- before_tool_call diagnostic log confirms exec observation: `[revenium-marker-gate] first exec observation: toolName="exec" params keys=[command]`
- Model reasoning driven by BUDGET-GUARD directive in SC3 turn (echo hello_sc3_marker_test ran at 02:32:32)
- BLOCKER B-05: No marker .jsonl written — before_agent_finalize sees empty execRuns (in-process state reset on nemoclaw recover)

**SC4 — Fail-open:** STRUCTURALLY EVIDENCED
- Cross-referenced to Plan 01 unit tests (35/35 pass, commit 89b2213)
- Double try/catch at every hook boundary in dist/index.js
- Sandbox healthy after plugin disable: turn completes in <10s

**SC5 — Scaffold shape:** EVIDENCED
- `openclaw.plugin.json` has `configSchema` + `"activation": {"onStartup": true}`
- `package.json` has `"openclaw": {"extensions": ["./dist/index.js"]}` + `"type": "module"`
- Trust recorded: `Origin: global`, `Status: loaded`

## Deviations from Plan

### 1. install_skill_nemoclaw() fails from home dir due to SSHFS mounts
- **Found during:** Task 1
- **Issue:** `nemoclaw skill install ~/` rejects files with spaces in names (SSHFS mount node_modules)
- **Workaround:** Created `~/revenium-skill/` staging directory with only required files
- **Fix needed in Plan 02:** Use clean skill dir, not `~/`

### 2. finalPromptText removed in OpenClaw 2026.5.22 (B-01)
- Plan 02 Gate A uses `grep -q "<revenium-guard>"` on `finalPromptText` field — field is absent
- Alternative proof used: `promptChars` diff (649 vs 1637)
- Plan 02 Gate A must be updated before shipping

### 3. Agent turns take ~70s (not hang, not <10s)
- Initial task used 45s timeout (exit 124), leading to incorrect "infinite hang" diagnosis
- After increasing to 120-180s timeout, turns complete with Nemotron model
- SC2 and SC3 substantive turns use Nemotron tool-call loop to check guardrail-status.json

### 4. before_agent_finalize revise loop not triggering end-to-end (B-05)
- In-process `execRuns` Set is empty at start of each new gateway process
- `nemoclaw recover` spawns a new gateway process — all in-process state is lost
- Marker write via revise loop works in-process (proven by unit tests) but not across process restarts

## Open Blockers

| ID | SC | Status | Root Cause |
|----|-----|--------|------------|
| B-01 | SC1 | OPEN | `finalPromptText` removed from `openclaw agent --json` in 2026.5.22 |
| B-05 | SC3 | OPEN | In-process `execRuns` resets on `nemoclaw recover`; revise loop cannot persist state across process restarts |

## Sandbox State at Checkpoint

- Plugin: disabled (`openclaw plugins disable revenium-enforcement` + recover done)
- Health check: exit 0, turn completes in <10s
- guardrail-status.json: `{"halted": false, "warned": false, ...}`
- Markers directory: empty

## Threat Surface Scan

No new code was written. No new endpoints or trust boundaries introduced beyond those in the plan's
`<threat_model>`. T-15-11 (leftover halted status) was mitigated: sandbox restored after SC2 test.

## Self-Check

- [x] `15-VALIDATION.md` exists: `/Users/johndemic/Development/projects/revenium/openclaw-revenium/.claude/worktrees/agent-a71692eb3c4e443ce/.planning/phases/15-per-turn-enforcement-plugin/15-VALIDATION.md`
- [x] SC1 section exists with live evidence (promptChars diff, model reasoning, plugin inspect)
- [x] SC2 section: PASSED — halt message captured from session sc2halted2
- [x] SC3 section: PARTIALLY EVIDENCED — before_tool_call log confirmed; marker write blocked (B-05)
- [x] SC4 section: cross-referenced to Plan 01 unit tests
- [x] SC5 section: manifest fields confirmed
- [x] No fabricated results — all blockers explicitly named
- [x] Task 1 commit: f59a245
- [x] Task 2 commit: ba3cc40
- [x] Sandbox restored to healthy state (plugin disabled, no halt, health check exit 0)
- [x] Checkpoint: Task 3 (checkpoint:human-verify) — awaiting human review

## Self-Check: PASSED (pending human-verify checkpoint)
