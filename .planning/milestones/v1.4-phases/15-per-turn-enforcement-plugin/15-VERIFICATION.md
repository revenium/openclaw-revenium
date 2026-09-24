---
phase: 15-per-turn-enforcement-plugin
verified: 2026-06-10T00:00:00Z
status: passed
score: 5/5 must-haves verified
overrides_applied: 0
re_verification:
  previous_status: gaps_found
  previous_score: 3/5
  gaps_closed:
    - "CR-01 (Gate A pipefail abort): || true guard added to _prompt_chars pipeline (scripts/post-install-nemoclaw.sh line 231). Live evidence: diagnostic message fires correctly on no-injection path; Gate A passes on injection-working path (promptChars=1645 >= 1500). RESOLVED."
    - "WR-01 (non-string exec downgrades marked:true): persistRunState(runId, false) changed to persistRunState(runId, markedTaskRuns.has(runId)) on non-string-command exec path (plugin/src/gate.js line 190 / plugin-nemoclaw/src/gate.js identical via D-06). Live evidence: marked:true preserved across recover; no spurious revise. RESOLVED."
    - "Stale plugin/dist/ code-review blocker (b711e9d): plugin/dist/gate.js now contains scanTranscriptForExec (grep count=2) and plugin/dist/index.js:39 forwards event?.messages via safeBeforeAgentFinalize(runId, messages, opts). Build self-syncs gate.js via bake-directive.js copyFileSync. RESOLVED."
  gaps_remaining: []
  regressions: []
deferred: []
---

# Phase 15: Per-Turn Enforcement Plugin — Verification Report (Round-3 Re-Verification)

**Phase Goal:** Every agent turn inside the NemoClaw sandbox receives the mandatory guardrail directive via an OpenClaw `before_prompt_build` plugin, and task/job marker writing is preserved via a deployed `before_agent_finalize` adapter — making halt and warn-and-ask enforcement and Revenium attribution work under NemoClaw.

**Verified:** 2026-06-10
**Status:** PASSED
**Re-verification:** Yes — round 3, after gap-closure plans 15-06 (code fixes) and 15-07 (live re-validation)

---

## Goal Achievement

### Observable Truths (Roadmap Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| SC1 | Custom OpenClaw `before_prompt_build` plugin installed via `openclaw plugins install`, authoritatively trusted, guardrail directive in agent context on every turn — verified on live sandbox 34.224.27.67 | VERIFIED | Live (15-07): Gate A positive sub-check: promptChars=1645 >= 1500 (session rv-cr01-pos-1781109376, exit 0). CR-01 fix present: `|| true` guard on `_prompt_chars` pipeline (post-install-nemoclaw.sh line 231). No-injection diagnostic fires with correct message and non-zero exit (CR-01 negative sub-check). Plugin status: loaded, Origin: global, allowConversationAccess: true. Directive injection: promptChars 657→1645 (+988 chars). |
| SC2 | Agent turn halted under NemoClaw when `guardrail-status.json` has `halted:true` | VERIFIED | Live (15-03): session sc2halted2 — halt message returned instead of answering; model honored halted:true status. Unchanged across subsequent rounds. |
| SC3 (renegotiated) | `before_agent_finalize` marker-gate plugin deployed/adapted for sandbox; markers written for agents that invoke exec directly (full gateway messaging sessions); Nemotron tool_search_code/agent-embedded CLI limitation documented as known constraint | VERIFIED | Code: `scanTranscriptForExec` present in plugin/src/gate.js, plugin-nemoclaw/src/gate.js (src files identical via D-06), plugin/dist/gate.js, plugin-nemoclaw/dist/gate.js (each grep count=2). `event?.messages` forwarded to `safeBeforeAgentFinalize` in both index.js files (plugin/dist/index.js line 39, plugin-nemoclaw/dist/index.js line 61). WR-01 fix: `persistRunState(runId, markedTaskRuns.has(runId))` on non-string-command exec path (gate.js line 190). Unit tests: plugin 52/52 pass (including transcript-scan B-05 suite), plugin-nemoclaw 57/57 pass. Renegotiation: ROADMAP.md SC3 note documents agent/embedded runner limitation as human-approved accepted scope reduction. |
| SC4 | Plugin hook error or timeout is fail-open — never blocks the agent's reply | VERIFIED | Structural: double try/catch on every handler in both index.js files. safeBeforeAgentFinalize / safeBeforeToolCall / safeAgentEnd wrappers in gate.js contain independent fail-open boundaries. Unit test suite includes fail-open boundary tests (WRAPPER-THREADING suites pass). 52/52 and 57/57 pass. |
| SC5 | Plugin authored from official `openclaw plugins init` scaffold with `configSchema` and `openclaw.extensions` in package.json | VERIFIED | Live (15-03): `openclaw plugins inspect revenium-enforcement` shows Status: loaded, Format: openclaw, Origin: global, Policy: allowConversationAccess: true. package.json: `"openclaw": {"extensions": ["./dist/index.js"]}`. openclaw.plugin.json: `activation.onStartup: true`, `configSchema: {type: object, additionalProperties: false}`. |

**Score: 5/5 truths verified**

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `plugin-nemoclaw/src/index.ts` | Combined plugin: before_prompt_build guard + gate.js marker hooks (4 hooks) | VERIFIED | Registers before_prompt_build (guard directive injection), before_tool_call, before_agent_finalize (event?.messages forwarded), agent_end |
| `plugin-nemoclaw/src/gate.js` | Build-time copy of plugin/src/gate.js (D-06 bake-directive.js copyFileSync) | VERIFIED | diff -q plugin/src/gate.js plugin-nemoclaw/src/gate.js → FILES_IDENTICAL. Contains scanTranscriptForExec, WR-01 fix, disk persistence |
| `plugin-nemoclaw/dist/gate.js` | Compiled gate.js with scanTranscriptForExec + WR-01 fix | VERIFIED | grep -c scanTranscriptForExec = 2; persistRunState(runId, markedTaskRuns.has(runId)) at compiled line 180 |
| `plugin-nemoclaw/dist/index.js` | Compiled plugin entry: event?.messages forwarded to safeBeforeAgentFinalize | VERIFIED | Line 61: `safeBeforeAgentFinalize(ctx?.runId, event?.messages, { log: ... })` |
| `plugin/dist/gate.js` | Previously-stale standalone dist — now contains scanTranscriptForExec + WR-01 fix | VERIFIED | grep -c scanTranscriptForExec = 2; persistRunState(runId, markedTaskRuns.has(runId)) at compiled line 190. Stale-dist blocker from code review CLOSED (commit b711e9d). |
| `plugin/dist/index.js` | event?.messages forwarded to safeBeforeAgentFinalize | VERIFIED | Line 39: `safeBeforeAgentFinalize(ctx?.runId, event?.messages, { log: ... })` |
| `plugin/src/gate.js` | Source of truth: scanTranscriptForExec + WR-01 fix + disk persistence | VERIFIED | 454 lines; scanTranscriptForExec function defined lines 243-277; safeBeforeAgentFinalize signature (runId, transcript, opts, impl) at line 416 |
| `scripts/post-install-nemoclaw.sh` | Gate A: `|| true` guard on `_prompt_chars` pipeline (CR-01 fix) | VERIFIED | Line 231: `| head -1 \|\| true)` present. Positive sub-check passes (1645 >= 1500). Negative sub-check: diagnostic message fires with non-zero exit on no-promptChars JSON |
| `plugin-nemoclaw/openclaw.plugin.json` | onStartup:true + valid configSchema | VERIFIED | activation.onStartup: true; configSchema: {type: object, additionalProperties: false}; confirmed in live plugins inspect output |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `plugin-nemoclaw/src/index.ts` | `./gate.js` | import safeBeforeToolCall / safeBeforeAgentFinalize / safeAgentEnd | VERIFIED | plugin-nemoclaw/dist/index.js line 23: `import { safeBeforeToolCall, safeBeforeAgentFinalize, safeAgentEnd } from "./gate.js"` |
| `plugin-nemoclaw/src/index.ts` | `./guard.js` | import { GUARD_DIRECTIVE } | VERIFIED | plugin-nemoclaw/dist/index.js line 22: `import { GUARD_DIRECTIVE } from "./guard.js"` |
| `plugin-nemoclaw/scripts/bake-directive.js` | `BUDGET-GUARD.md` | readFileSync at build time | VERIFIED | bake-directive.js lines 62-69: copyFileSync(gateSrc, gateDst) syncs plugin/src/gate.js → src/gate.js at build |
| `scripts/post-install-nemoclaw.sh` | `plugin-nemoclaw/` | cp to mount/extensions/revenium-enforcement | VERIFIED | Lines 169-174: cp -r plugin-nemoclaw to MNT/extensions/revenium-enforcement |
| `scripts/post-install-nemoclaw.sh` Gate A | `openclaw agent --json currentTurn.promptChars` | grep -oE with `|| true` guard | VERIFIED | Line 231: pipeline has `|| true`; threshold 1500 confirmed; both positive and negative sub-checks pass (live evidence, 15-VALIDATION.md round-3) |
| `gate.js before_agent_finalize` | transcript scan (B-05 path) | `scanTranscriptForExec(transcript)` called at Source 3 | VERIFIED | gate.js lines 328-332: transcript scan is Source 3 in handleBeforeAgentFinalize; event?.messages flows from both index.js files |
| `gate.js handleBeforeToolCall` non-string path | `persistRunState` | `persistRunState(runId, markedTaskRuns.has(runId))` | VERIFIED | gate.js line 190 (src), line 190 (plugin/dist), line 180 (plugin-nemoclaw/dist): WR-01 fix confirmed in all three files |

---

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|--------------|--------|--------------------|--------|
| `plugin-nemoclaw/dist/index.js` before_prompt_build | GUARD_DIRECTIVE | Baked from BUDGET-GUARD.md into dist/guard.js at build via bake-directive.js | Yes — inlined constant; +988 chars confirmed live (promptChars 657→1645) | FLOWING |
| `gate.js` safeBeforeAgentFinalize Source 3 | transcript (event?.messages) | before_agent_finalize event forwarded from index.js | Code path wired; activates for full gateway messaging sessions; agent/embedded CLI runner skips hook (known limitation, SC3 renegotiation) | WIRED — structural activation for gateway sessions |
| `gate.js` persistRunState non-string path | marked flag on disk | `markedTaskRuns.has(runId)` (WR-01 fix) | Correct — prior marked:true preserved; no spurious downgrade | FLOWING (WR-01 RESOLVED) |

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Plugin installs and loads | Live: `openclaw plugins inspect revenium-enforcement` (15-07 deploy) | Status: loaded, Origin: global, allowConversationAccess: true, Installed at: 2026-06-10T16:35:32.653Z | PASS |
| before_prompt_build injects directive | Live: promptChars comparison (15-07 session rv-cr01-pos-1781109376) | 657 (no-plugin) → 1645 (with-plugin), +988 chars | PASS |
| CR-01 positive: Gate A passes with injection | Live: promptChars=1645 >= 1500, exit 0 | Gate A passed: currentTurn.promptChars=4599 >= 1500 | PASS |
| CR-01 negative: diagnostic fires on no-injection | Live: /tmp/cr01_pipefail_test.sh on host 34.224.27.67 | "guard directive NOT injected — could not parse currentTurn.promptChars" + exit 1 | PASS |
| SC2 halt-honoring under NemoClaw | Live (15-03): session sc2halted2, halted:true in guardrail-status.json | Halt message returned; model honored halted:true | PASS |
| WR-01: marked:true preserved after non-string exec across recover | Live: /tmp/wr01_test2.mjs on host (imports deployed gate.js) | disk {marked:true} preserved; before_agent_finalize returns undefined (pass-through) | PASS |
| Unit test suite (plugin) | `node --test plugin/src/index.test.js` (local) | 52/52 pass, 0 fail | PASS |
| Unit test suite (plugin-nemoclaw) | `node --test plugin-nemoclaw/src/index.test.js` (local) | 57/57 pass, 0 fail | PASS |
| D-06 build copy in sync | `diff -q plugin/src/gate.js plugin-nemoclaw/src/gate.js` (local) | FILES_IDENTICAL | PASS |
| Stale plugin/dist/gate.js (code-review blocker) | `grep -c scanTranscriptForExec plugin/dist/gate.js` (local) | 2 | PASS — not stale |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| NCENF-01 | 15-01, 15-02, 15-04, 15-06 | Per-turn guardrail directive via before_prompt_build; halt/warn enforcement under NemoClaw; Gate A validates injection | SATISFIED | CR-01 resolved: Gate A `|| true` guard present (post-install-nemoclaw.sh line 231); diagnostic fires correctly on no-injection path (live 15-07). Injection confirmed: +988 chars (promptChars 657→1645, live 15-07). Halt-honoring confirmed: SC2 session sc2halted2 (live 15-03). |
| NCENF-02 | 15-01, 15-04, 15-06 | Task/job marker writing under NemoClaw via before_agent_finalize adapter — attribution flows to Revenium | SATISFIED (against renegotiated SC3) | WR-01 resolved: persistRunState non-downgrade fix present (gate.js line 190, all dist files). scanTranscriptForExec wired (Source 3 in handleBeforeAgentFinalize); event?.messages forwarded from both index.js. Unit tests 57/57 pass including transcript-scan suite. SC3 renegotiation: agent/embedded CLI runner limitation documented in ROADMAP.md as human-approved scope reduction — B-05 end-to-end CLI demo not required. Marker gate activates for full gateway messaging sessions (SMS/web UI/channel-mediated turns). |
| NCDEPLOY-01 | 15-02 (D-08 pull-forward) | Skill deployed via nemoclaw skill install | DEFERRED to Phase 16 (see REQUIREMENTS.md traceability) | install_skill_nemoclaw() wired in post-install-nemoclaw.sh; live deployment performed with workaround (Deviation 1 from 15-VALIDATION.md). Phase 16 owns the polished skill-deploy path. |

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| None | — | — | — | No TBD/FIXME/XXX unresolved debt markers found in any phase-modified file. No stubs or empty implementations found in critical paths. |

---

### Human Verification Required

None. All prior gaps were closed by code fixes with live evidence and unit-test coverage. The SC3 renegotiation (B-05 structural OpenClaw constraint) is human-approved and documented in ROADMAP.md. No items require additional human testing beyond what was recorded in 15-VALIDATION.md round-3.

---

## Re-verification Summary

**Previous status:** gaps_found (3/5, round 2, 2026-06-09)**

**Gaps closed this round:**

1. **CR-01 RESOLVED** — `|| true` guard added to `_prompt_chars` pipeline in `post-install-nemoclaw.sh` (line 231). Live evidence (15-07): no-injection condition now prints actionable diagnostic and exits non-zero. Gate A positive path confirmed: promptChars=1645 >= 1500.

2. **WR-01 RESOLVED** — `persistRunState(runId, false)` changed to `persistRunState(runId, markedTaskRuns.has(runId))` on non-string-command exec path (`plugin/src/gate.js` line 190, propagated via D-06 build copy to `plugin-nemoclaw/src/gate.js`). Live evidence (15-07): `marked:true` preserved across recover; no spurious revise. All dist files contain the fix.

3. **Stale plugin/dist/ RESOLVED (commit b711e9d)** — `plugin/dist/gate.js` now contains `scanTranscriptForExec` (grep count=2); `plugin/dist/index.js` line 39 forwards `event?.messages` via the correct `safeBeforeAgentFinalize(runId, messages, opts)` signature. Build via `bake-directive.js` self-syncs `gate.js` from `plugin/src/` on every `npm run build`.

4. **B-05 RENEGOTIATED (SC3 scope reduction, human-approved)** — `before_agent_finalize` does not fire for `openclaw agent --json` CLI runs (agent/embedded runner). `scanTranscriptForExec` is correctly implemented and unit-tested (57/57). Will activate for full gateway messaging sessions. Structural OpenClaw constraint documented in ROADMAP.md SC3 renegotiation note. No further gap-closure cycle required.

**Phase goal achieved.** NCENF-01 and NCENF-02 satisfied against the renegotiated success criteria. Both unit suites pass (52/52, 57/57). All critical code paths wired and verified.

---

_Verified: 2026-06-10_
_Verifier: Claude (gsd-verifier)_
_Re-verification: Yes — round 3, plans 15-06 (code fixes) and 15-07 (live re-validation) assessed_

---

## Post-ship hardening (v1.4.1 — 2026-06-11)

The **live UAT pass on a clean host (2026-06-11)** found that the enforcement install-time gates false-failed against OpenClaw **v2026.5.22**, aborting the whole install with exit 1. This was previously mis-attributed to the B-05 Nemotron limitation; the actual root cause was two stale probes (the plugin itself loads fine — `Status: loaded`, `allowConversationAccess: true`). Fixed on `origin/main` (HEAD `fa7deeb`):

- **Gate A/B probe fix for v2026.5.22** (`323a2c6`) — Gate A ran `openclaw agent --json` with no routing target → "No target session selected"; it now derives the default agent (`openclaw agents list` "(default)" row, fallback `main`) and passes `--agent <id>`. Gate B grepped hook names that v2026.5.22 no longer enumerates; it now asserts `Status: loaded` + `allowConversationAccess: true`.
- **`common.sh` OPENCLAW_HOME sandbox normalization + Gate D path/label** (`c0e14e3`) — inside an OpenShell sandbox OpenClaw sets `OPENCLAW_HOME=/sandbox` with data under `$OPENCLAW_HOME/.openclaw`; `common.sh` assumed OPENCLAW_HOME *was* the `.openclaw` dir, which broke **in-sandbox `write-marker.sh` in general** (not just Gate D). Now normalizes by descending into `.openclaw` when `agents/` is absent there. Gate D fixed to a valid taxonomy label + the correct `${MNT}/skills/revenium/markers/` path. New `tests/test_common_paths.sh` (5/0).
- **Gate D marker-visibility resilience** (`58c52e6`) — the over-the-mount marker check now warns-not-aborts (SSHFS cache lag is transient; the in-sandbox write is the real proof; the metering loop self-heals the mount).

**Result:** `install.sh --nemoclaw` now exits **0** with all four gates passing live on Nemotron — including **Gate A proving the per-turn guardrail directive is injected every turn** (promptChars ~4599 vs ~649 baseline). The SC3 B-05 limitation (Nemotron routes `exec` via `tool_search_code` so the structural `before_tool_call` marker chain doesn't fire as on Claude) **remains a known limitation** affecting task-type attribution — it does **not** affect the per-turn directive, which is now proven to inject. Still not validated end-to-end: an actual budget-**breach** → hard HALT on Nemotron.

---

_Post-ship hardening addendum: 2026-06-11 (v1.4.1)_
