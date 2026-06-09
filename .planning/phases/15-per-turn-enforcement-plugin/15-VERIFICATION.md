---
phase: 15-per-turn-enforcement-plugin
verified: 2026-06-09T00:00:00Z
status: gaps_found
score: 3/5 must-haves verified
overrides_applied: 0
re_verification:
  previous_status: gaps_found
  previous_score: 3/5
  gaps_closed:
    - "B-01 (Gate A finalPromptText): Gate A in post-install-nemoclaw.sh now asserts currentTurn.promptChars >= 1500 (plan 15-04); live evidence confirms promptChars=1645 on the live host (plan 15-05). The removed finalPromptText field reference is gone (grep -c finalPromptText = 0). RESOLVED in code."
  gaps_remaining:
    - "B-05 (NCENF-02 / SC3): end-to-end marker write does not happen on NemoClaw. The deeper root cause revealed by plan 15-05 live re-validation is that the Nemotron model routes ALL shell execution through tool_search_code + openclaw.tools.call('openclaw:core:exec', ...), so the plugin's before_tool_call hook never fires. The plan 15-04 disk-persistence fix (42/42 unit tests pass) is structurally correct but the prerequisite (a direct exec tool call triggering before_tool_call) never occurs on this host. No marker .jsonl was produced."
  regressions:
    - "CR-01 (BLOCKER): Gate A's _prompt_chars parse pipeline (lines 230-231) runs under set -euo pipefail with no || true guard. When _prompt_json lacks a promptChars field (the exact failure mode Gate A exists to detect), the first grep exits 1, pipefail aborts the script at line 230 before the -z check on line 232 is reached, and the intended diagnostic fail message never prints. Confirmed reproduced. The gate still fails closed but its actionable error message is dead code on the no-match path."
    - "WR-01 (WARNING): persistRunState called at line 189 with hardcoded marked=false on the non-string-command exec path, overwriting any prior disk marked:true record for the same runId. Confirmed reproduced: a marker exec followed by a non-string-command exec in the same run writes marked:false to disk, undermining the B-05 disk persistence guarantee after a nemoclaw recover."
gaps:
  - truth: "A substantive NemoClaw turn writes a marker file end-to-end into mount/markers/ (SC3 / NCENF-02)"
    status: failed
    reason: "B-05: The Nemotron model routes all shell execution through tool_search_code + openclaw.tools.call('openclaw:core:exec', ...). The plugin's before_tool_call hook fires only on direct top-level tool calls. Sub-calls inside tool_search_code bypass the hook entirely. No exec observation is recorded, no run-state file is written, and before_agent_finalize sees an empty run — pass-through, no revise, no write-marker.sh, no marker .jsonl. Live session rv-b05-1780978277 confirmed: turn completed (exit 0, model returned 'revenium_b05_test'), zero marker-gate log entries, NO_RUN_STATE on disk, NO_MARKERS in mount. The plan 15-04 disk-persistence fix is correct code but its prerequisite (direct exec tool call) never occurs on this NemoClaw host."
    artifacts:
      - path: "plugin-nemoclaw/src/index.ts"
        issue: "before_tool_call hook (line 53) receives only direct top-level tool dispatch events; tool_search_code inner openclaw.tools.call() invocations are sub-calls that do not surface at the plugin API layer. No code change in index.ts can fix this without a different observation point."
      - path: "plugin/src/gate.js"
        issue: "handleBeforeToolCall and persistRunState are correct and tested (42/42 pass) but the hook registration point (before_tool_call via api.on) cannot intercept Nemotron's indirect exec path through tool_search_code. The fix must either (a) intercept tool_search_code calls and inspect their openclaw.tools.call arguments, or (b) observe exec by a different mechanism (e.g. before_agent_finalize inspecting the conversation transcript for exec tool results, which requires allowConversationAccess)."
    missing:
      - "A new observation strategy that captures Nemotron exec calls routed through tool_search_code. Options: (a) register a before_tool_call handler for 'tool_search_code' and inspect params.code for openclaw.tools.call('openclaw:core:exec', ...) patterns — requires testing whether sub-call interception is exposed; (b) in before_agent_finalize (which has allowConversationAccess:true), scan the conversation messages for toolResult entries with toolName='tool_search_code' whose content contains openclaw:core:exec invocations — this is transcript-based rather than hook-based and is resilient to process restarts; (c) explicitly scope NCENF-02 to mean 'marker gate works within a single gateway process on non-Nemotron OpenClaw agents' and document the Nemotron limitation — but that requires renegotiating SC3."

  - truth: "Gate A assertion in scripts/post-install-nemoclaw.sh correctly validates directive injection and produces actionable diagnostics when injection fails (CR-01 regression)"
    status: failed
    reason: "CR-01: Gate A's _prompt_chars parse pipeline at lines 230-231 is missing || true. Under set -euo pipefail (line 30), when _prompt_json is empty or lacks a promptChars field (the exact no-plugin scenario Gate A exists to catch), grep exits 1, pipefail aborts the command substitution, set -e terminates the script at line 230, and the carefully-worded 'guard directive NOT injected — could not parse currentTurn.promptChars' fail message at line 233 is never reached. The operator sees a bare exit 1 with no context. Confirmed reproduced on a JSON with no promptChars field."
    artifacts:
      - path: "scripts/post-install-nemoclaw.sh"
        issue: "Lines 230-231: _prompt_chars=$(echo ... | grep ... | grep ... | head -1) has no || true guard. Under pipefail the first grep's non-zero exit aborts the script before -z check on line 232. The B-01 rewrite introduced this defect (the || true was intentionally placed only on the _prompt_json capture at line 229)."
    missing:
      - "Add || true to the _prompt_chars pipeline: change line 230-231 to: _prompt_chars=$(echo \"${_prompt_json}\" | grep -oE '\"promptChars\"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)"
      - "Optional (WR-02 from review): further scope the grep to the currentTurn object to prevent false positives from other promptChars fields that might appear earlier in the JSON."

  - truth: "Disk-persisted run-state remains monotonically marked:true once a run is classified as a marker run (WR-01 warning — affects B-05 guarantee)"
    status: failed
    reason: "WR-01: plugin/src/gate.js line 189 calls persistRunState(runId, false) unconditionally on the non-string-command exec path without checking whether markedTaskRuns already contains the runId. A marker exec followed by a non-string-command exec in the same run overwrites the disk record from marked:true to marked:false. After a nemoclaw recover (the exact recovery scenario disk persistence was designed for), handleBeforeAgentFinalize reads disk, sees marked:false, and issues a spurious revise action for a turn that was already classified. Confirmed reproduced: marker exec writes marked:true, non-string-command exec writes marked:false."
    artifacts:
      - path: "plugin/src/gate.js"
        issue: "Line 189: persistRunState(runId, false) — hardcodes false instead of checking markedTaskRuns.has(runId). The normal exec path at line 201 correctly ORs isMarked || markedTaskRuns.has(runId); the non-string guard at lines 186-191 does not."
      - path: "plugin-nemoclaw/src/gate.js"
        issue: "Same defect — identical file to plugin/src/gate.js (D-06 build copy; fix in plugin/src/gate.js propagates here)."
    missing:
      - "Change line 189 from: persistRunState(runId, false); to: persistRunState(runId, markedTaskRuns.has(runId)); to preserve the prior marked:true state on non-string-command exec calls."
      - "Add regression test per WR-04: 'non-string-command exec after a marker does NOT downgrade disk marked:true' — test sequence: marker exec → non-string-command exec → resetState() → handleBeforeAgentFinalize must return undefined (pass-through)."
deferred: []
---

# Phase 15: Per-Turn Enforcement Plugin — Verification Report (Re-Verification)

**Phase Goal:** Every agent turn inside the NemoClaw sandbox receives the mandatory guardrail directive via an OpenClaw `before_prompt_build` plugin (NCENF-01), and task/job marker writing is preserved via a deployed `before_agent_finalize` adapter (NCENF-02) — making halt/warn enforcement and Revenium attribution work under NemoClaw.

**Verified:** 2026-06-09
**Status:** GAPS FOUND
**Re-verification:** Yes — after gap-closure plans 15-04 (code fixes) and 15-05 (live re-validation)

---

## Goal Achievement

### Observable Truths (Roadmap Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| SC1 | A custom OpenClaw `before_prompt_build` plugin is installed via `openclaw plugins install`, authoritatively trusted, and the guardrail directive appears in agent context on every turn — verified on live sandbox 34.224.27.67 | VERIFIED (injection) / BLOCKER (Gate A CR-01) | Injection: promptChars 649→1645 (+996 chars) confirmed live in plan 15-05 session rv-gatea-fresh-1780977923. Plugin loaded (Status: loaded, Origin: global). Gate A rewrite (plan 15-04): finalPromptText gone (grep -c = 0), promptChars threshold present. BUT Gate A has CR-01 defect: _prompt_chars pipeline aborts under pipefail before the diagnostic fires. Gate A would produce a bare exit 1 with no message on real injection failure — making it undebuggable in the field. |
| SC2 | An agent turn that would be halted under the standalone path is also halted under NemoClaw | VERIFIED | Live session sc2halted2: guardrail-status.json set to halted:true, model returned halt message instead of answering. Confirmed in plan 15-03 live validation. |
| SC3 | The `before_agent_finalize` marker-gate plugin is deployed and task/job markers are written under NemoClaw — attribution flows to Revenium | FAILED | before_tool_call never fires for Nemotron exec calls (model routes through tool_search_code + openclaw.tools.call). No run-state file written, no marker .jsonl produced. Live session rv-b05-1780978277 (plan 15-05): turn completed (exit 0, model said 'revenium_b05_test'), NO_RUN_STATE on disk, NO_MARKERS in mount. Root cause: plan 15-04 disk-persistence fix is correct code but the observation hook point is wrong for Nemotron's indirect exec pattern. B-05 STILL OPEN. |
| SC4 | A plugin hook error or timeout is fail-open — never blocks the agent's reply | VERIFIED | Double try/catch on every handler (index.ts lines 43-75). 37/37 plugin tests pass, 42/42 plugin-nemoclaw tests pass (confirmed by local run). Live: turns complete normally when plugin is disabled. |
| SC5 | Plugin authored from official scaffold with `configSchema` and `openclaw.extensions` in package.json | VERIFIED | openclaw.plugin.json: activation.onStartup:true, configSchema present. package.json: openclaw.extensions: ["./dist/index.js"], type:module. Plugin inspect on live host: Status: loaded, Origin: global. |

**Score: 3/5 truths verified** (SC2, SC4, SC5 pass; SC1 has injection evidence but Gate A diagnostic path broken by CR-01; SC3 failed by B-05 deeper root cause)

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `plugin-nemoclaw/src/index.ts` | Combined plugin wiring: guard hook + gate.js marker hooks | VERIFIED | Registers before_prompt_build, before_tool_call, before_agent_finalize, agent_end; 10 hook/handler references confirmed |
| `plugin-nemoclaw/src/guard.js` | Build-time generated GUARD_DIRECTIVE constant | VERIFIED | Contains GUARD_DIRECTIVE with full BUDGET-GUARD.md text |
| `plugin/src/gate.js` | Disk-persisted exec-run state (plan 15-04 fix) | VERIFIED (code) / BLOCKER (WR-01) | writeFileSync, existsSync, readFileSync, sanitizeRunId, setRunStateDir all present. WR-01 defect: line 189 persistRunState(runId, false) unconditionally downgrades marked:true to false on non-string-command exec path. Confirmed reproduced. |
| `plugin-nemoclaw/src/gate.js` | Build-time copy of plugin/src/gate.js (D-06) | VERIFIED | diff -q confirms identical to plugin/src/gate.js. Inherits WR-01 defect by identity. |
| `plugin-nemoclaw/dist/index.js` | Committed compiled artifact with inlined directive | VERIFIED | Contains before_prompt_build, revenium-guard tag, 7 hits confirmed |
| `plugin-nemoclaw/openclaw.plugin.json` | onStartup:true + valid configSchema | VERIFIED | activation.onStartup:true; configSchema {type:object, additionalProperties:false} |
| `scripts/post-install-nemoclaw.sh` | Gate A using promptChars threshold (plan 15-04 B-01 fix) | PARTIAL — Gate A logic correct, diagnostic path broken by CR-01 | finalPromptText removed (grep -c = 0); promptChars threshold present (grep -c = 8); syntax valid (bash -n exits 0). But: _prompt_chars parse pipeline at lines 230-231 lacks || true — aborts under pipefail on no-match before the fail message fires. CR-01 BLOCKER. |
| `scripts/uninstall-enforcement-nemoclaw.sh` | Plugin + config teardown counterpart | VERIFIED | Present; plugins uninstall + enforcement-plugin-installed ledger clear |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `plugin-nemoclaw/src/index.ts` | `./gate.js` | import safeBeforeToolCall/safeBeforeAgentFinalize/safeAgentEnd | VERIFIED | Lines 23-27 import from ./gate.js |
| `plugin-nemoclaw/src/index.ts` | `./guard.js` | import { GUARD_DIRECTIVE } | VERIFIED | Line 22 |
| `plugin-nemoclaw/scripts/bake-directive.js` | `BUDGET-GUARD.md` | readFileSync at build time | VERIFIED | GUARD_DIRECTIVE in dist/index.js contains full directive text |
| `scripts/post-install-nemoclaw.sh` | `plugin-nemoclaw/` | cp to mount/extensions/revenium-enforcement | VERIFIED | Lines 169-174 |
| `scripts/post-install-nemoclaw.sh` | `openclaw plugins install` | nemoclaw exec clean install | VERIFIED | Lines 182-185 |
| `scripts/post-install-nemoclaw.sh` Gate A | `openclaw agent --json currentTurn.promptChars` | grep/parse promptChars | WIRED (code) / BROKEN (diagnostic) | promptChars grep logic present; threshold 1500 defined. But pipeline lacks || true — under pipefail aborts before diagnostic fires (CR-01). |
| `gate.js before_tool_call` | exec observation + run-state file | execRuns.add + persistRunState | WIRED (code) / NOT REACHABLE (Nemotron) | handler is registered and tested; Nemotron model never triggers it directly (routes through tool_search_code). B-05 deeper root cause. |
| `gate.js handleBeforeAgentFinalize` | run-state file fallback | existsSync + readFileSync on disk | WIRED (code) / NOT FLOWING (Nemotron) | disk fallback implemented and tested; moot because run-state file is never written under Nemotron's tool-calling pattern. |

---

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|--------------|--------|--------------------|--------|
| `plugin-nemoclaw/src/index.ts` before_prompt_build | GUARD_DIRECTIVE | Baked from BUDGET-GUARD.md into guard.js at build | Yes — inlined constant, +996 chars confirmed live (promptChars 649→1645) | FLOWING |
| `gate.js` execRuns + run-state file | before_tool_call → persistRunState | Direct exec tool call dispatched to plugin layer | No on NemoClaw/Nemotron: before_tool_call never fires for tool_search_code sub-calls | DISCONNECTED — hook never fires for Nemotron exec |
| `gate.js` handleBeforeAgentFinalize | execRuns.has / disk fallback | before_tool_call + persistRunState | No: run-state file never written, disk fallback finds nothing | DISCONNECTED — no state to read |
| `gate.js` persistRunState (non-string path) | marked flag on disk | markedTaskRuns.has(runId) at write time | Incorrect — hardcoded false overwrites prior marked:true (WR-01) | STATIC / INCORRECT |

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Plugin installs and loads | `openclaw plugins inspect revenium-enforcement` on live host (plan 15-05) | Status: loaded, Origin: global, allowConversationAccess: true | PASS (live evidence) |
| before_prompt_build injects directive | promptChars comparison (plan 15-05 session rv-gatea-fresh-1780977923) | 649 → 1645 (+996 chars) | PASS (live evidence) |
| Gate A passes on injection-working host | Gate A check simulation: promptChars=1645 >= 1500 | PASS (plan 15-05 evidence) | PASS |
| Gate A diagnostic on no-match path | bash -c 'set -euo pipefail; ...' with no-promptChars JSON | PIPELINE_ABORTED_exit=1 — bare exit, no message | FAIL (CR-01 reproduced) |
| SC2 halt-honoring under NemoClaw | Live session sc2halted2 (plan 15-03) | Halt message returned; model honored halted:true | PASS (live evidence) |
| SC3 end-to-end marker write | ls markers/*.jsonl after rv-b05-1780978277 exec turn (plan 15-05) | NO_RUN_STATE, NO_MARKERS | FAIL (B-05) |
| WR-01: marked:true preserved after non-string exec | node repro: marker exec → non-string exec → read disk | marked=false after non-string exec (should be true) | FAIL (WR-01 reproduced) |
| Unit test suite | `node --test plugin/src/index.test.js` | 37/37 pass | PASS |
| Unit test suite (nemoclaw copy) | `node --test plugin-nemoclaw/src/index.test.js` | 42/42 pass | PASS |
| D-06 build copy in sync | `diff -q plugin/src/gate.js plugin-nemoclaw/src/gate.js` | files_identical | PASS |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| NCENF-01 | 15-01, 15-02, 15-03, 15-04, 15-05 | Per-turn guardrail directive via before_prompt_build; halt/warn enforcement under NemoClaw; install gate validates injection | PARTIALLY SATISFIED — BLOCKER CR-01 | Directive injection confirmed live (+996 chars promptChars). Gate A B-01 rewrite correct in logic. CR-01 defect: Gate A diagnostic path aborts before error message fires under pipefail on no-match. The install script will silently fail without actionable output if injection fails on a new host. |
| NCENF-02 | 15-01, 15-02, 15-03, 15-04, 15-05 | Task/job marker writing under NemoClaw via before_agent_finalize adapter; attribution flows to Revenium | NOT SATISFIED — BLOCKER B-05 | before_tool_call never fires for Nemotron's tool_search_code-routed exec calls. No run-state file written. No marker .jsonl produced end-to-end. disk persistence code (plan 15-04) is correct and unit-tested but cannot be triggered by Nemotron's indirect exec pattern. |
| NCDEPLOY-01 | 15-02 (pulled forward per D-08) | Skill deployed via nemoclaw skill install | PARTIALLY SATISFIED | install_skill_nemoclaw() present and wired; live workaround required (SSHFS ~/ issue — Deviation 1 in 15-VALIDATION.md). REQUIREMENTS.md maps this to Phase 16 with a Phase 15 parenthetical; Phase 16 is the responsible phase. |

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `scripts/post-install-nemoclaw.sh` | 230-231 | `_prompt_chars=$(... grep ... head -1)` lacks `|| true` under `set -euo pipefail` | BLOCKER (CR-01) | When _prompt_json has no promptChars field, grep exits 1, pipefail aborts script before the `-z` check. Diagnostic fail message is dead code on no-match path. Confirmed reproduced. |
| `plugin/src/gate.js` | 189 | `persistRunState(runId, false)` unconditional on non-string-command exec path | WARNING (WR-01) | Overwrites prior `marked:true` disk record to `marked:false` on a later non-string exec in the same run. After nemoclaw recover, before_agent_finalize issues spurious revise for already-classified run. Confirmed reproduced. |
| `plugin-nemoclaw/src/gate.js` | 189 | Same WR-01 defect (D-06 build copy) | WARNING | Inherits WR-01 from plugin/src/gate.js; fix propagates automatically via build copy. |

No TBD/FIXME/XXX unresolved debt markers found in any phase-modified file.

---

### Human Verification Required

None. All three remaining gaps (B-05 deeper root cause, CR-01, WR-01) are fully observable in code and confirmed by automated reproduction or live test evidence. No additional human testing is required to classify them.

---

## Gaps Summary

**Three gaps block phase goal achievement after the plan 15-04 gap-closure round.**

### B-01 STATUS (CLOSED)

The original B-01 gap (Gate A grepping the removed `finalPromptText` field) is RESOLVED by plan 15-04 and confirmed live in plan 15-05. `finalPromptText` is gone (grep -c = 0). promptChars threshold is present and passes on the live host (promptChars=1645 >= 1500). This truth is CLOSED.

---

### BLOCKER 1 — CR-01 (affects NCENF-01 / SC1 Gate A diagnostic quality)

`scripts/post-install-nemoclaw.sh` lines 230-231: the `_prompt_chars` parse pipeline runs under `set -euo pipefail` (line 30) without a `|| true` guard. When `_prompt_json` is empty or lacks a `promptChars` field — exactly the condition Gate A exists to detect — the first `grep` exits 1, `pipefail` aborts the command substitution, and `set -e` terminates the script at line 230 before the `-z` check on line 232. The carefully-worded actionable fail message on line 233 (`"guard directive NOT injected — could not parse currentTurn.promptChars"`) is dead code on this path. Operators debugging a real injection failure receive a bare `exit 1` with no context. Reproduced locally.

**Fix:** Add `|| true` to the `_prompt_chars` pipeline:
```bash
_prompt_chars=$(echo "${_prompt_json}" \
    | grep -oE '"promptChars"[[:space:]]*:[[:space:]]*[0-9]+' \
    | grep -oE '[0-9]+$' | head -1 || true)
```
Optionally combine with the WR-02 scope fix (scope to `currentTurn` object first).

---

### BLOCKER 2 — B-05 deeper root cause (affects NCENF-02 / SC3)

`before_tool_call` in the plugin never fires for Nemotron's exec invocations on this NemoClaw host. The Nemotron model consistently routes all shell execution through `tool_search_code` + `openclaw.tools.call('openclaw:core:exec', ...)`. The plugin's `before_tool_call` hook fires only on direct top-level tool dispatch — sub-calls inside `tool_search_code` are not surfaced at the plugin API layer. Session JSONL from rv-b05-1780978277 confirms: `toolName=tool_search_code`, not `toolName=exec`. As a result:

- `execRuns.add(runId)` is never called
- `persistRunState(runId, ...)` is never called
- No `~/.openclaw/run-state/` file is written
- `handleBeforeAgentFinalize` sees no in-process state and no disk state → passes through → no `write-marker.sh` → no marker `.jsonl`

The plan 15-04 disk-persistence code is correct and passes 42 unit tests. The defect is at the observation boundary: `before_tool_call` is the wrong hook for Nemotron's indirect exec pattern.

**Remediation options for next gap-closure round:**

1. **Intercept tool_search_code directly:** Register a `before_tool_call` handler for `'tool_search_code'` and inspect `params.code` for `openclaw.tools.call('openclaw:core:exec', ...)` patterns. This catches Nemotron's indirect exec path. Requires testing whether the plugin API exposes the code parameter reliably.

2. **Transcript-based observation in before_agent_finalize:** `handleBeforeAgentFinalize` already has `allowConversationAccess: true`. Scan `ctx.conversation.messages` for `toolResult` entries with `toolName='tool_search_code'` whose content contains an `openclaw:core:exec` invocation. This is resilient to process restarts and does not depend on which hook fires first. Requires validating the conversation schema.

3. **Scope NCENF-02 to non-Nemotron agents and document the limitation:** Accept that the revise loop only works for agents that invoke `exec` directly (not through `tool_search_code`). Requires renegotiating SC3 in ROADMAP.md.

---

### WARNING — WR-01 (undermines B-05 disk-persistence guarantee)

`plugin/src/gate.js` line 189 calls `persistRunState(runId, false)` unconditionally on the non-string-command exec path without checking `markedTaskRuns.has(runId)`. A marker exec (which writes `marked:true`) followed by a non-string-command exec in the same run overwrites the disk record to `marked:false`. After `nemoclaw recover`, `handleBeforeAgentFinalize` reads disk, sees `marked:false`, and issues a spurious revise for a run that was already classified. Confirmed reproduced.

Even though B-05's root cause is the `before_tool_call` hook not firing, WR-01 is a real correctness defect in the disk-persistence code that should be fixed in the same gap-closure round.

**Fix:** Change line 189:
```js
// Current (wrong):
persistRunState(runId, false);
// Correct:
persistRunState(runId, markedTaskRuns.has(runId));
```
Add the WR-04 regression test from the code review report.

---

_Verified: 2026-06-09_
_Verifier: Claude (gsd-verifier)_
_Re-verification: Yes — plans 15-04 (gap-closure code) and 15-05 (live re-validation) assessed_
