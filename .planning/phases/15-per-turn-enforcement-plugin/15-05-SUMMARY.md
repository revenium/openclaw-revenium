---
phase: 15-per-turn-enforcement-plugin
plan: "05"
subsystem: live-validation
status: checkpoint-pending-human-review
tags: [live-validation, nemoclaw, enforcement-plugin, B-01, B-05, NCENF-01, NCENF-02, re-validation, gap-closure]
requirements: [NCENF-01, NCENF-02]

dependency_graph:
  requires:
    - plugin-nemoclaw/dist/gate.js (Plan 15-04 persistence fix — deployed to live host)
    - scripts/post-install-nemoclaw.sh (Plan 15-04 Gate A rewrite — promptChars threshold)
    - 34.224.27.67 sandbox revenium-spike (live host)
  provides:
    - .planning/phases/15-per-turn-enforcement-plugin/15-VALIDATION.md (RE-VALIDATION addendum)
  affects:
    - Nothing in the codebase — this is a read-only live validation plan

tech_stack:
  added: []
  patterns:
    - SSH live-host validation with background nohup job (model turns take 160-240s)
    - SSHFS mount-based evidence capture from sandbox
    - openclaw agent --json with gateway log correlation
    - Session JSONL forensics to determine tool invocation path

key_files:
  created:
    - .planning/phases/15-per-turn-enforcement-plugin/15-05-SUMMARY.md
  modified:
    - .planning/phases/15-per-turn-enforcement-plugin/15-VALIDATION.md (RE-VALIDATION addendum added)

decisions:
  - key: b01-resolved-promptchars-1645
    description: "Gate A (promptChars >= 1500) passes on live host: session rv-gatea-fresh-1780977923 returned promptChars=1645. The 15-04 fix works correctly. Gate B (plugins inspect) confirms: Status: loaded, Origin: global, allowConversationAccess: true."
  - key: b05-root-cause-deepened
    description: "B-05 still failing end-to-end. Re-validation reveals a deeper root cause: the Nemotron model consistently routes all shell execution through tool_search_code + openclaw.tools.call('openclaw:core:exec', ...), which does NOT trigger the plugin's before_tool_call hook. Plan 15-04's disk persistence fix is correct code (42/42 unit tests pass) but the prerequisite (direct exec tool call) never occurs on this host."
  - key: turn-duration-increase
    description: "Turn duration increased from ~72s (Plan 03, Jun 9 02:xx UTC) to 160-240s (Plan 05, Jun 9 04:xx UTC). Inference endpoint appears under higher load. Gate A session timed out at 180s and required 300s+ timeout. Sessions started as background nohup jobs to avoid timeout failures."

metrics:
  duration: "~29 minutes"
  completed: "2026-06-09"
  tasks_completed: 1
  tasks_total: 2
  tasks_pending: 1 (checkpoint:human-verify)
  files_created: 1
  files_modified: 1
---

# Phase 15 Plan 05: Live Re-Validation Summary

One-liner: Re-validation of Plan 15-04 fixes on live sandbox revenium-spike — B-01 (Gate A promptChars) RESOLVED with live evidence (promptChars=1645 >= 1500); B-05 (marker end-to-end) still failing because Nemotron routes exec through tool_search_code indirect calls that bypass the plugin's before_tool_call hook.

## What Was Built

No code was written. This plan ran live commands against the sandbox host 34.224.27.67 and recorded honest observations in `15-VALIDATION.md ## RE-VALIDATION`.

### Deploy Steps

The updated `plugin-nemoclaw/` (dist/gate.js with 15-04 persistence code) was rsync'd to the live host and deployed via the SSHFS mount:

```
rsync → /home/ubuntu/plugin-nemoclaw-15-04/
cp -r → ~/sbx-openclaw-revenium-spike/extensions/revenium-enforcement
openclaw plugins install --force /sandbox/.openclaw/extensions/revenium-enforcement → exit 0
openclaw config patch → Applied 2 config updates
nemoclaw revenium-spike recover → Probe complete
Plugin state: enabled, Status: loaded, Origin: global, allowConversationAccess: true
```

### B-01 Evidence (Gate A)

Session `rv-gatea-fresh-1780977923` ran `openclaw agent --json --message "What is 2+2?"` with the plugin enabled. The turn completed (exit 0, ~238s) and returned:

```
status: ok
model_response: "4"
systemPromptReport.currentTurn.promptChars: 1645
```

Gate A check: `1645 >= 1500` → **PASS**. The plugin's `before_prompt_build` hook injected +996 chars of the guardrail directive (baseline without plugin: 649 chars).

This resolves **B-01** — the 15-04 Gate A rewrite works on OpenClaw 2026.5.22.

### B-05 Evidence (Marker end-to-end)

Session `rv-b05-1780978277` ran `openclaw agent --json --message "Please run the shell command echo revenium_b05_test and tell me the output"`. Turn completed (exit 0, ~162s) and returned:

```
status: ok
model_response: "revenium_b05_test"
promptChars: 1707
```

The model DID run `echo revenium_b05_test`. However:
- No `[revenium-marker-gate] first exec observation` in gateway log
- No `~/.openclaw/run-state/` directory written
- No `~/sbx-openclaw-revenium-spike/markers/*.jsonl` files

Session JSONL forensics confirm: the model used `tool_search_code` + `openclaw.tools.call('openclaw:core:exec', ...)` (toolName=tool_search_code, NOT toolName=exec). The plugin's `before_tool_call` hook fires only on direct tool calls, not on sub-calls inside `tool_search_code`.

**B-05 STILL FAILING** — same fundamental root cause: Nemotron model routes all exec through indirect tool_search_code calls that bypass `before_tool_call`. The disk persistence fix cannot help because the hook never fires to write the state.

### Sandbox Restore

```
openclaw plugins disable revenium-enforcement → exit 0
nemoclaw revenium-spike recover → exit 0
Plugin state: disabled
guardrail-status.json: {"halted": false, "warned": false, ...}
markers/: directory does not exist
```

## Deviations from Plan

### 1. [Rule 1 - Finding] Gate A session required 300s+ timeout (not 120-180s)

- **Found during:** Task 1, Gate A run
- **Issue:** First Gate A attempt with 180s timeout → exit 124. Sessions started at ~04:03 UTC;
  model inference took 238s for the successful session.
- **Workaround:** Used `nohup` background job with 600s timeout on the remote host, polled for
  output file. Gate A session completed successfully in 238s.
- **Root cause:** Inference queue load increased since Plan 03 (Jun 9 02:xx UTC). Inference
  endpoint now serves requests in 160-240s vs. ~72s earlier.

### 2. [Rule 1 - Bug] Multiple stuck sessions from timeout cascades

- **Found during:** Task 1 attempts
- **Issue:** First two Gate A attempts (rv-gatea-1780977110, rv-gatea-b01-1780977302) hit the
  gateway's 600s internal timeout before the nemoclaw exec process's own timeout. Sessions
  remained stalled in the gateway as active_work_without_progress. Required `nemoclaw recover`
  to kill them.
- **Fix:** Used `nemoclaw recover` between attempts. Subsequent sessions ran cleanly.

### 3. [Rule 2 - Deeper root cause] B-05 root cause is deeper than Plan 15-04 addressed

- **Found during:** Task 1, B-05 test
- **Issue:** Plan 15-04 identified B-05 as "in-process execRuns resets on recover". Re-validation
  reveals the actual root cause: `before_tool_call` never fires at all for Nemotron's exec
  invocations (model routes through tool_search_code indirect calls). Disk persistence is
  correct but moot — the issue is upstream of the fix.
- **No code change:** This is a live-validation finding only. Honest record required per CRITICAL
  HONESTY RULE.

## Open Blockers

| ID | SC | Status | Root Cause |
|----|-----|--------|------------|
| B-01 | SC1 | **RESOLVED** | Gate A rewritten to use promptChars >= 1500 (Plan 15-04) |
| B-05 | SC3 | **STILL OPEN** | Nemotron model routes exec through tool_search_code indirect calls; before_tool_call never fires; disk persistence fix is moot for this host |

## Threat Surface Scan

No new code written. No new endpoints or trust boundaries introduced. The live session runs were
contained within the existing sandbox boundary (T-15-RV-01: run-state observations, T-15-RV-02:
evidence accuracy enforced by CRITICAL HONESTY RULE, T-15-RV-03: sandbox restored after validation).

## Known Stubs

None — this is a validation-only plan.

## Self-Check

- [x] `.planning/phases/15-per-turn-enforcement-plugin/15-VALIDATION.md` exists with RE-VALIDATION section
- [x] B-01 block: promptChars=1645, exit 0, session rv-gatea-fresh-1780977923 — RESOLVED
- [x] B-05 block: honest failure evidence — session JSONL confirms tool_search_code indirect exec — STILL FAILING
- [x] Deploy steps recorded with exit codes
- [x] Sandbox restore commands recorded (plugin disabled, gateway recovered, guardrail-status.json clean)
- [x] No fabricated results — all evidence is from live sessions
- [x] Task 1 commit: b845b5e
- [x] Checkpoint: Task 2 (checkpoint:human-verify) — awaiting human review

## Self-Check: PASSED (pending human-verify checkpoint)
