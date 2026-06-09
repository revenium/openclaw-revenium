---
phase: 15-per-turn-enforcement-plugin
verified: 2026-06-08T00:00:00Z
status: gaps_found
score: 3/5 must-haves verified
overrides_applied: 0
gaps:
  - truth: "Gate A assertion in scripts/post-install-nemoclaw.sh correctly validates directive injection (SC1 / NCENF-01)"
    status: failed
    reason: "B-01: Gate A (lines 217-222) greps openclaw agent --json output for <revenium-guard> in finalPromptText. The finalPromptText field was removed from openclaw agent --json in OpenClaw 2026.5.22 — the live host returns systemPromptReport with promptChars instead. The grep will always fail on the live host, aborting every install. The assertion method is structurally broken against the shipped OpenClaw version."
    artifacts:
      - path: "scripts/post-install-nemoclaw.sh"
        issue: "Lines 217-222: _prompt_json capture + grep for <revenium-guard> in finalPromptText field that no longer exists in openclaw agent --json output on OpenClaw 2026.5.22. Any real install will hit 'fail: guard directive NOT injected' even though the plugin IS injecting correctly."
    missing:
      - "Replace Gate A assertion in install_enforcement_plugin() to use an alternative injection proof that works in 2026.5.22. Options per 15-VALIDATION.md: (a) compare currentTurn.promptChars baseline vs. with-plugin (e.g. assert promptChars >= 1500 chars), (b) check openclaw logs for 'http server listening (... revenium-enforcement ...)' startup line, or (c) rely on Gate B (plugins inspect + Status: loaded) as the sole injection proof and drop the agent-run assertion."

  - truth: "A substantive NemoClaw turn writes a marker file end-to-end into mount/markers/ (SC3 / NCENF-02)"
    status: failed
    reason: "B-05: The before_agent_finalize revise loop relies on the in-process execRuns Set (gate.js lines 14 and 107). Each nemoclaw recover spawns a NEW OpenClaw gateway process with an empty execRuns Set, so before_agent_finalize always sees execRuns.has(runId) = false and passes through without issuing a revise action. Live evidence confirms: before_tool_call fires and logs the exec observation (execRuns.add called), but the marker .jsonl was NOT written end-to-end across the process boundary. The unit tests confirm the revise loop works in-process, but that contract does not survive NemoClaw's recover lifecycle."
    artifacts:
      - path: "plugin-nemoclaw/src/gate.js"
        issue: "execRuns and markedTaskRuns are module-level in-process Sets (lines 14-15). They are never persisted to disk. When nemoclaw recover restarts the gateway process, both Sets are empty. Any exec tool call from before the recover is invisible to before_agent_finalize in the new process."
    missing:
      - "Address the in-process state reset. Options per 15-VALIDATION.md: (a) persist exec observations to a file (e.g. ~/.openclaw/run-state/<runId>.json) that survives process restarts — gate.js must write on execRuns.add and read on before_agent_finalize; (b) architect the plugin so recover is not called between before_tool_call and before_agent_finalize within the same agent turn; (c) explicitly scope NCENF-02 to mean 'marker gate works within a single gateway process (non-NemoClaw path)' and document the NemoClaw limitation — but that would mean SC3 cannot be satisfied as written."

deferred: []
---

# Phase 15: Per-Turn Enforcement Plugin — Verification Report

**Phase Goal:** Every agent turn inside the NemoClaw sandbox receives the mandatory guardrail directive via an OpenClaw `before_prompt_build` plugin, and task/job marker writing is preserved via a deployed `before_agent_finalize` adapter — making halt and warn-and-ask enforcement and Revenium attribution work under NemoClaw.

**Verified:** 2026-06-08
**Status:** GAPS FOUND
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths (Roadmap Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| SC1 | A custom OpenClaw `before_prompt_build` plugin is installed via `openclaw plugins install`, trusted, and the guardrail directive appears in agent context on every turn — verified on live sandbox 34.224.27.67 | PARTIAL — injection evidenced, Gate A broken | Injection CONFIRMED: promptChars 649→1637 (+988 chars), model reasoning cites BUDGET-GUARD directive in every session log. Plugin trusted (Origin: global, Status: loaded in inspect). But Gate A in install script greps for finalPromptText which no longer exists — B-01 makes the install abort on the live host version. |
| SC2 | An agent turn that would be halted under the standalone path is also halted under NemoClaw | VERIFIED | Live session sc2halted2: guardrail-status.json set to halted:true, model returned halt message instead of answering. Evidence in 15-VALIDATION.md. Sandbox restored after test. |
| SC3 | The `before_agent_finalize` marker-gate plugin is deployed and task/job markers are written under NemoClaw — attribution flows to Revenium | FAILED | before_tool_call fires and logs exec observation (confirmed in live log). But no marker .jsonl was written. before_agent_finalize passes through because execRuns is empty on the new gateway process (nemoclaw recover resets in-process state). B-05 is a confirmed end-to-end blocker. |
| SC4 | A plugin hook error or timeout is fail-open — never blocks the agent's reply | VERIFIED (structural) | Every handler has double try/catch returning undefined on error (index.ts lines 43-49, 53-56, 62-67, 70-75). 35/35 unit tests pass including 5 CR-01 fail-open boundary tests (commit 89b2213). Plugin disabled: live turns complete in <10s. |
| SC5 | Plugin authored from official scaffold with `configSchema` and `openclaw.extensions` in package.json | VERIFIED | `plugin-nemoclaw/openclaw.plugin.json`: activation.onStartup:true, configSchema {type:object, additionalProperties:false}. `package.json`: openclaw.extensions: ["./dist/index.js"], type:module. Trust recorded on live host (Origin: global). |

**Score: 3/5 truths verified** (SC2, SC4, SC5 pass; SC1 partial/blocked by B-01; SC3 failed by B-05)

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `plugin-nemoclaw/src/index.ts` | Combined plugin wiring: guard hook + gate.js marker hooks | VERIFIED | Registers all 4 hooks; before_prompt_build at line 42, marker hooks wired from gate.js imports |
| `plugin-nemoclaw/src/guard.js` | Build-time generated GUARD_DIRECTIVE constant | VERIFIED | Contains `export const GUARD_DIRECTIVE` with full BUDGET-GUARD.md text including _maxAgeSeconds |
| `plugin-nemoclaw/src/gate.js` | Copied from plugin/src/gate.js at build time (D-06) | VERIFIED | Present; identical in structure to the shared source; safeBeforeToolCall/safeBeforeAgentFinalize/safeAgentEnd exported |
| `plugin-nemoclaw/dist/index.js` | Committed compiled artifact with inlined directive | VERIFIED | Contains before_prompt_build, revenium-guard tag, Guardrail Enforcement text |
| `plugin-nemoclaw/openclaw.plugin.json` | onStartup:true + valid configSchema | VERIFIED | activation.onStartup:true; configSchema {type:object, properties:{}, additionalProperties:false} |
| `plugin-nemoclaw/package.json` | openclaw.extensions + bake+tsc build | VERIFIED | openclaw.extensions: ["./dist/index.js"]; type:module present |
| `BUDGET-GUARD.md` | Contains _maxAgeSeconds freshness rule | VERIFIED | Freshness bullet present as 2nd bullet with absent-field skip branch |
| `scripts/post-install-nemoclaw.sh` | Real install_skill_nemoclaw + install_enforcement_plugin | VERIFIED (structure) / BLOCKER (Gate A) | Functions defined, ledger-gated, stub removed. Gate A fails on live host due to removed finalPromptText field (B-01). |
| `scripts/uninstall-enforcement-nemoclaw.sh` | Plugin + config teardown counterpart | VERIFIED | plugins uninstall revenium-enforcement + enforcement-plugin-installed ledger clear |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `plugin-nemoclaw/src/index.ts` | `./gate.js` | import safeBeforeToolCall/safeBeforeAgentFinalize/safeAgentEnd | VERIFIED | Lines 23-27 import from ./gate.js (copied from plugin/src/gate.js at build time) |
| `plugin-nemoclaw/src/index.ts` | `./guard.js` | import { GUARD_DIRECTIVE } | VERIFIED | Line 22 |
| `plugin-nemoclaw/scripts/bake-directive.js` | `BUDGET-GUARD.md` | readFileSync at build time | VERIFIED | GUARD_DIRECTIVE in dist/guard.js contains _maxAgeSeconds from BUDGET-GUARD.md |
| `scripts/post-install-nemoclaw.sh` | `plugin-nemoclaw/` | cp to mount/extensions/revenium-enforcement | VERIFIED | Lines 169-174 |
| `scripts/post-install-nemoclaw.sh` | `openclaw plugins install` | nemoclaw exec clean install | VERIFIED | Lines 182-185 |
| `scripts/post-install-nemoclaw.sh` | Gate A: `finalPromptText` | openclaw agent --json grep | BROKEN | Lines 217-222 grep for field removed in OpenClaw 2026.5.22. Link exists in code but target field no longer exists at runtime (B-01). |
| `gate.js execRuns` | `before_agent_finalize` revise action | in-process Set.has(runId) | BROKEN across process restarts | execRuns is module-level in-process state, resets on nemoclaw recover. before_agent_finalize sees empty Set after any recover. End-to-end marker write does not happen (B-05). |

---

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|--------------|--------|--------------------|--------|
| `plugin-nemoclaw/src/index.ts` before_prompt_build | GUARD_DIRECTIVE | Baked from BUDGET-GUARD.md at build time into guard.js | Yes — inlined constant, 988 chars confirmed live | FLOWING |
| `gate.js` execRuns | in-process Set | before_tool_call hook calls execRuns.add(runId) | Yes in-process; No across nemoclaw recover | STATIC after process restart |
| `gate.js` handleBeforeAgentFinalize | execRuns.has(runId) | Same process execRuns Set | Empty on new gateway process → revise loop never fires in NemoClaw | DISCONNECTED (cross-process) |

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| before_prompt_build injects directive | promptChars comparison (live, 15-VALIDATION.md) | 649 → 1637 (+988 chars) | PASS (live evidence) |
| SC2 halt-honoring under NemoClaw | Live session sc2halted2 with halted:true status | Halt message returned; model did not proceed | PASS (live evidence) |
| Gate A revenium-guard grep | grep against openclaw agent --json on OpenClaw 2026.5.22 | finalPromptText absent; grep fails | FAIL — B-01 |
| SC3 end-to-end marker write | ls markers/*.jsonl after substantive exec turn | NO_JSONL_FILES | FAIL — B-05 |
| SC4 fail-open | 35 unit tests + live disable/recover | 35/35 pass; turns complete <10s with plugin disabled | PASS |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| NCENF-01 | 15-01, 15-02, 15-03 | Per-turn guardrail directive via before_prompt_build, halt/warn enforcement under NemoClaw | PARTIALLY SATISFIED — BLOCKER B-01 | Directive injection confirmed live. Gate A assertion in install script is broken (finalPromptText removed). The install script would abort on every fresh install on the live host, making the automated provision path non-functional. |
| NCENF-02 | 15-01, 15-02, 15-03 | Task/job marker writing under NemoClaw via before_agent_finalize adapter | NOT SATISFIED — BLOCKER B-05 | before_tool_call fires (confirmed live). before_agent_finalize passes through because in-process execRuns resets on nemoclaw recover. No marker .jsonl written end-to-end. Attribution does not flow. |
| NCDEPLOY-01 | 15-02 (pulled forward per D-08) | Skill deployed via nemoclaw skill install | PARTIALLY SATISFIED | install_skill_nemoclaw() function exists and is wired. Live workaround required (clean skill dir, not ~/). The production install_skill_nemoclaw() uses SCRIPT_DIR/.. which resolves to ~/ on the live host, causing skill install to fail due to SSHFS node_modules with unsafe characters. |

Note on NCDEPLOY-01: Plan 02 declares it was "pulled forward" into Phase 15 per D-08. REQUIREMENTS.md maps it to Phase 16 (with the Phase 15 parenthetical). Per roadmap traceability, NCDEPLOY-01 is Phase 16's responsibility, but Plan 02 and 15-02-SUMMARY.md explicitly claim it. The install function is present and wired; the live Deviation 1 (SSHFS ~/ issue) is a separate but real deficiency that would affect any fresh provision.

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `scripts/post-install-nemoclaw.sh` | 217-222 | Gate A greps for finalPromptText field removed in OpenClaw 2026.5.22 | BLOCKER | Install aborts on every real provision on the live host version. B-01. |
| `plugin-nemoclaw/src/gate.js` | 14-15 | In-process module-level Sets with no persistence | BLOCKER | execRuns resets on nemoclaw recover, making before_agent_finalize revise loop dead in NemoClaw's process restart lifecycle. B-05. |
| `scripts/post-install-nemoclaw.sh` | 132 | install_skill_nemoclaw uses SCRIPT_DIR/.. resolving to ~/ on live host | WARNING | Causes skill install to fail due to SSHFS node_modules in ~/. Requires workaround (clean skill dir). Not a code smell but a path resolution defect. |

No TBD/FIXME/XXX debt markers found in any phase-modified file.

---

### Human Verification Required

None beyond what is described above as gaps. The two blockers (B-01, B-05) are fully observable in code and confirmed by live test evidence — no additional human testing is needed to classify them.

---

## Gaps Summary

**Two real blockers prevent phase goal achievement. Both were recorded honestly in 15-VALIDATION.md and are confirmed by direct code inspection and live evidence.**

### BLOCKER 1 — B-01 (affects NCENF-01 / SC1)

`scripts/post-install-nemoclaw.sh` Gate A (lines 217–222) asserts that `openclaw agent --json` output contains `<revenium-guard>` in the `finalPromptText` field. This field was removed from the `openclaw agent --json` response in OpenClaw 2026.5.22 — the version running on the live sandbox. The grep will always fail on the live host, causing `install_enforcement_plugin()` to abort with "guard directive NOT injected" even though the plugin IS injecting correctly (+988 promptChars confirmed live). Any operator running `post-install-nemoclaw.sh` against the live host today gets a broken install despite the plugin itself working.

**Remediation:** Replace the Gate A assertion with an injection proof that works on 2026.5.22. The simplest sound alternatives are: (a) assert `currentTurn.promptChars` from `openclaw agent --json` exceeds a threshold (e.g. > 1500 chars — baseline is 649, with plugin is 1637); or (b) drop the agent-run assertion and rely solely on Gate B (`plugins inspect` Status:loaded + before_prompt_build present) as the injection proof. Do NOT assert on the removed `finalPromptText` field.

### BLOCKER 2 — B-05 (affects NCENF-02 / SC3)

`gate.js` `execRuns` and `markedTaskRuns` are module-level in-process JavaScript `Set` objects (lines 14–15). They are never persisted to disk. `nemoclaw recover` spawns a new OpenClaw gateway process — all in-process state is lost. `before_agent_finalize` evaluates `execRuns.has(runId)` (line 107), which is always `false` in a new process, so it returns `undefined` (pass-through) for every agent turn after a recover. The revise loop that forces `write-marker.sh` never fires end-to-end under NemoClaw. No marker `.jsonl` file was produced in live testing.

**Remediation:** Persist exec observations across process restarts. The simplest approach: on `execRuns.add(runId)` in `handleBeforeToolCall`, also write a small JSON file to `~/.openclaw/run-state/<runId>.json`; on `handleBeforeAgentFinalize`, if `execRuns.has(runId)` is false, check for the file on disk as fallback. Alternatively, redesign the flow so `nemoclaw recover` is not called between `before_tool_call` and `before_agent_finalize` within the same agent turn (may not be controllable). A third option is to scope NCENF-02's guarantee explicitly to single-gateway-process sessions and document the NemoClaw limitation, but that would require the roadmap success criterion SC3 to be renegotiated.

---

_Verified: 2026-06-08_
_Verifier: Claude (gsd-verifier)_
