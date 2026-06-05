---
phase: 11-structural-marker-enforcement-via-before-agent-finalize-plug
verified: 2026-06-05T00:00:00Z
status: passed
score: 10/11 must-haves verified (1 waived)
overrides_applied: 1
override_note: "SC-1 numeric coverage record waived by user 2026-06-05 — gate behavior confirmed working end-to-end on the live ClawHub host ('working great', attribution flowing on the Revenium side); only the before/after percentages were lost when terminal history cleared. Tracked as a non-blocking follow-up in 11-HUMAN-UAT.md."
human_verification:
  - test: "Re-run scripts/verify-markers.sh on the ClawHub host (98.82.34.123) before and after a batch of substantive turns and record the numeric before/after coverage percentages."
    expected: "Coverage rises well above ~1/64 baseline. Exact numbers captured and added to 11-03-SUMMARY.md."
    why_human: "Terminal history was cleared before the numbers were recorded (documented in 11-03-SUMMARY.md). Qualitative pass was user-confirmed ('working great'), but the numeric record called for in SC-1 and the plan <output> spec is absent. The gap is documentation-only — the gate behavior was confirmed working — but the plan explicitly required recording before/after coverage %."
---

# Phase 11: Structural Marker Enforcement via before_agent_finalize Plugin — Verification Report

**Phase Goal:** Per-turn task classification is structurally enforced, not LLM-compliance-dependent — a typed OpenClaw `before_agent_finalize` plugin (`revenium-marker-gate`) forces the agent to run `write-marker.sh` before it can finalize a substantive turn, bounded (`retry.maxAttempts`) and fail-open (never blocks the reply). Plus a `scripts/verify-markers.sh` diagnostic that makes the completions-vs-markers gap measurable.
**Verified:** 2026-06-05T00:00:00Z
**Status:** passed (SC-1 numeric record waived by user — see override_note)
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

Truths are drawn from the five ROADMAP success criteria and the merged PLAN frontmatter must-haves across all three plans.

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `before_agent_finalize` returns a bounded revise action when an exec turn ran but `write-marker.sh` did not | VERIFIED | `node --test` 30/30; test "exec ran but write-marker.sh did NOT run → returns revise action (SC-1)" passes; `handleBeforeAgentFinalize` in `gate.js:103-127` returns `{ action: "revise", retry: { maxAttempts: 1 } }` |
| 2 | Gate is fail-open and bounded: `maxAttempts: 1`; hook error never blocks the reply | VERIFIED | `node --test` CR-01 suite (5 cases): `safeBeforeAgentFinalize` resolves to `undefined` when the gate throws; `undefined` returned for no-runId / non-substantive / already-marked; `index.ts` and `gate.js` have nested try/catch at boundary |
| 3 | Plugin reads no conversation content — observes exec via `before_tool_call` only; `allowConversationAccess: true` set in post-install for `before_agent_finalize` + `agent_end` CONVERSATION_HOOK_NAMES | VERIFIED | `before_tool_call` handler accesses only `event.toolName` and `event.params` (tool data, not conversation); `post-install.sh:626` patches `hooks.allowConversationAccess: true`; `post-install.sh:631-636` verifies `before_agent_finalize` in hookNames via `plugins inspect` |
| 4 | `scripts/verify-markers.sh` reports per-session completions vs markers and coverage % so the gap is observable before/after | VERIFIED | `bash tests/test_verify_markers.sh` 16/16 pass; script produces `session_id \| completions \| markers \| gap \| coverage%` table + `TOTAL:` summary; cron sessions excluded; read-only (no tee, no file writes) |
| 5 | No change to budget-rule logic, `config.json` ruleIds, `guardrail-status.json` halt/warn contract; `report.sh` unclassified default + completion_id correlation preserved | VERIFIED | `bash tests/test_report_argv.sh` 10/10 pass; `bash tests/test_guardrail_argv.sh` 18/18 pass; `git diff --name-only scripts/report.sh scripts/guardrail-check.sh` is empty |
| 6 | `before_agent_finalize` returns `undefined` (pass-through) for non-substantive turns, already-marked turns, and missing runId | VERIFIED | `node --test` covers all three paths explicitly |
| 7 | Plugin observes exec/bash tool calls via `before_tool_call` without needing `allowConversationAccess` for that hook | VERIFIED | Confirmed by code structure: `before_tool_call` is NOT a CONVERSATION_HOOK_NAME; `index.ts` comment and `allowConversationAccess` is set only for `before_agent_finalize`/`agent_end` |
| 8 | `agent_end` cleans both tracking sets per runId so in-process state does not leak | VERIFIED | `node --test` "agent_end clears both sets" and "does not clear other runIds" pass; `gate.js:136-141` deletes both entries |
| 9 | A committed `plugin/dist/index.js` (and `dist/gate.js`) artifact exists so a host without tsc can load the plugin | VERIFIED | `git ls-files plugin/dist/index.js plugin/dist/gate.js` both tracked; `node --check` passes on both; `before_agent_finalize` string present in `dist/index.js`; MARKER_INVOKE regex identical in src and dist |
| 10 | `post-install.sh` installs plugin idempotently, patches config with `allowConversationAccess`, verifies `before_agent_finalize` in hookNames, documents gateway restart, and does NOT auto-restart | VERIFIED | `bash -n scripts/post-install.sh` clean; all four acceptance criteria confirmed by grep checks; step positioned after §7b, before §8 budget-guard step |
| 11 | Marked-completion coverage rises well above ~1/64 on the ClawHub host after install (SC-1 host proof with before/after numeric record) | UNCERTAIN | User-confirmed qualitatively ("working great", attribution flowing on Revenium side). Gate behavior (revise loop firing, agent classifying on forced pass, fail-open after bounded pass) is user-confirmed. **Exact before/after `verify-markers.sh` percentages were NOT captured** — terminal history cleared before recording. Qualitative pass is sufficient to confirm the gate works; numeric record is absent. |

**Score:** 10/11 truths verified (Truth 11 is uncertain/human-needed, not failed)

---

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `plugin/src/index.ts` | `definePluginEntry` wiring, min 50 lines, `before_agent_finalize` handlers | VERIFIED | 59 lines; imports `safeBeforeToolCall`, `safeBeforeAgentFinalize`, `safeAgentEnd` from `./gate.js`; registers all three hooks |
| `plugin/src/gate.js` | Pure gate logic; `handleBeforeAgentFinalize`, `handleBeforeToolCall`, `handleAgentEnd`, `resetState`, `safeBeforeAgentFinalize`, `safeBeforeToolCall`, `safeAgentEnd` | VERIFIED | 206 lines; all named exports present; MARKER_INVOKE regex; fail-open safe wrappers |
| `plugin/dist/index.js` | Pre-built ESM artifact, contains `before_agent_finalize`, committed | VERIFIED | 51 lines; `node --check` passes; `before_agent_finalize` present; tracked by git |
| `plugin/dist/gate.js` | Compiled `gate.js`, MARKER_INVOKE regex identical to src | VERIFIED | 167 lines; regex bit-for-bit identical to `src/gate.js` |
| `plugin/package.json` | `"type": "module"`, `openclaw.extensions[0] === "./dist/index.js"` | VERIFIED | Both confirmed |
| `plugin/openclaw.plugin.json` | `id: revenium-marker-gate` | VERIFIED | Confirmed |
| `plugin/.gitignore` | Ignores `node_modules/` only; does NOT ignore `dist/` | VERIFIED | Content: `node_modules/` only |
| `plugin/src/index.test.js` | node:test suite covering SC-1/SC-2, all behavior bullets | VERIFIED | 30/30 cases pass including CR-01 throw-path tests, WR-02 mention-only false-positive cases |
| `scripts/verify-markers.sh` | Per-session diagnostic, min 40 lines, references `common.sh` (in comments/notes), cron exclusion | VERIFIED | 191 lines; `agent:main:cron:` exclusion present; no tee, no report.sh invocation; WR-01 resolved by not sourcing common.sh (see note) |
| `tests/test_verify_markers.sh` | Integration test, min 40 lines, drives `verify-markers.sh` | VERIFIED | 16/16 pass; 5 fixture scenarios covered |
| `scripts/post-install.sh` | Contains `openclaw plugins install`, `allowConversationAccess`, `plugins inspect` | VERIFIED | §7c step present and syntactically clean |

---

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `plugin/package.json` | `plugin/dist/index.js` | `openclaw.extensions` array | WIRED | `p.openclaw.extensions[0] === "./dist/index.js"` confirmed |
| `plugin/src/index.ts` | `openclaw/plugin-sdk/plugin-entry` | `import definePluginEntry from "openclaw/plugin-sdk/plugin-entry"` | WIRED | Present on line 15 of `src/index.ts` |
| `plugin/src/index.ts` | `./gate.js` | imports `safeBeforeToolCall`, `safeBeforeAgentFinalize`, `safeAgentEnd` | WIRED | Line 16; all three wrappers imported and used in `register()` |
| `scripts/verify-markers.sh` | `scripts/common.sh` | deliberate non-source; mirrors path constants inline (WR-01 fix) | WIRED (deviation) | WR-01 resolved: script does NOT source common.sh (would create state dir as side effect); instead mirrors OPENCLAW_HOME discovery and SESSIONS_DIR/MARKERS_DIR inline. The spirit of "reuses common.sh constants without re-declaration" is met via mirroring; the artifact `contains: "common.sh"` check passes because the file has 5 comment-only references to `common.sh` explaining the deliberate non-source. |
| `tests/test_verify_markers.sh` | `scripts/verify-markers.sh` | `OPENCLAW_HOME` override invocation | WIRED | `grep -q "verify-markers.sh"` passes; test invokes script under isolated `TMP_HOME` |
| `scripts/post-install.sh` | `plugin/` | `openclaw plugins install "${SKILL_DIR}/plugin" --force` | WIRED | Line 621 |
| `scripts/post-install.sh` | `openclaw config` | `config patch --stdin` with `allowConversationAccess` | WIRED | Lines 626-628 |

---

### Data-Flow Trace (Level 4)

Not applicable — this phase produces no data-rendering components. The plugin observes event data (tool call params) and produces a static return value; `verify-markers.sh` reads from JSONL files on disk via Python heredoc. Both are logic/script artifacts, not dynamic UI.

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| `node --test` 30 cases pass | `cd plugin && node --test` | 30/30, 0 failures | PASS |
| `verify-markers.sh` 16 test cases pass | `bash tests/test_verify_markers.sh` | 16/16, 0 failures | PASS |
| `test_report_argv.sh` SC-5 regression | `bash tests/test_report_argv.sh` | 10/10 pass | PASS |
| `test_guardrail_argv.sh` SC-5 regression | `bash tests/test_guardrail_argv.sh` | 18/18 pass | PASS |
| `test_write_marker.sh` no regression | `bash tests/test_write_marker.sh` | 12/12 pass | PASS |
| `test_get_root_session_id.py` no regression | `python3 tests/test_get_root_session_id.py` | 7/7 pass | PASS |
| `dist/index.js` syntax valid | `node --check plugin/dist/index.js` | clean | PASS |
| `dist/gate.js` syntax valid | `node --check plugin/dist/gate.js` | clean | PASS |
| `post-install.sh` syntax valid | `bash -n scripts/post-install.sh` | clean | PASS |
| `verify-markers.sh` syntax valid | `bash -n scripts/verify-markers.sh` | clean | PASS |
| `dist/gate.js` MARKER_INVOKE regex matches `src/gate.js` | python3 regex comparison | byte-for-byte identical | PASS |

---

### Probe Execution

No conventional `scripts/*/tests/probe-*.sh` probes exist for Phase 11. Plan 03 Task 2 was declared `checkpoint:human-verify` (not an automatable probe); its execution is recorded as user-confirmed in 11-03-SUMMARY.md.

---

### Requirements Coverage

Phase 11 plans declare requirements [SC-1, SC-2, SC-3] (Plans 01 + 03) and [SC-4, SC-5] (Plan 02). There is no standalone `REQUIREMENTS.md` file for v1.3; the authoritative source is ROADMAP.md Success Criteria 1–5. All five are accounted for.

| Requirement | Source Plan(s) | Description | Status | Evidence |
|-------------|---------------|-------------|--------|----------|
| SC-1 | 11-01, 11-03 | `before_agent_finalize` returns `revise` when exec ran without marker; coverage rises above ~1/64 on host | VERIFIED (local) / UNCERTAIN (host numeric record) | Unit: 30/30 tests. Host: user-confirmed qualitatively; exact before/after percentages not captured |
| SC-2 | 11-01, 11-03 | Bounded (`maxAttempts: 1`); fail-open (no block on error or missing runId) | VERIFIED | `node --test` CR-01 suite + gate logic tests; nested try/catch in `gate.js` and `index.ts` |
| SC-3 | 11-01, 11-03 | `before_tool_call` observation without `allowConversationAccess`; `before_agent_finalize` registered with the flag; plugin installable on ClawHub host | VERIFIED | Code structure confirmed; `post-install.sh` §7c confirmed; host install user-confirmed |
| SC-4 | 11-02 | `verify-markers.sh` reports per-session completions vs markers + coverage %, cron excluded | VERIFIED | 16/16 test cases pass |
| SC-5 | 11-02 | No change to `report.sh` / guardrail behavior | VERIFIED | 10/10 report tests + 18/18 guardrail tests pass; `git diff` shows no changes to those files |

**D-01 through D-07** (design decisions): All honored — plugin in `plugin/` dir, `post-install.sh` automation (D-02), task marker only (D-03), exec-turn detection only (D-04), `allowConversationAccess` set per revised D-05, `verify-markers.sh` built independently (D-06), no change to metering/guardrail contract (D-07).

No orphaned requirements: ROADMAP.md maps exactly SC-1..SC-5 to Phase 11, and all five are claimed and verified above.

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| No TBD/FIXME/XXX markers found in any phase-modified file | — | — | — | None |
| `gate.js:20` | 20 | `_loggedFirstExec` one-time `console.log` diagnostic (IN-01 from review) | Info | Intentional temporary scaffolding to resolve open question A1 from host logs; noted as "plan to remove once A1 confirmed" in review. Not a blocker. |
| `gate.js:60-63` | 60 | Non-string params adds to `execRuns` conservatively (IN-02 from review) | Info | Defensible conservative choice documented in review. Not a blocker. |
| Deferred review items WR-03, WR-04, WR-05, WR-06, IN-03, IN-04 | — | See 11-REVIEW.md | Warning (all deferred) | All four are post-shipping improvements; none block the phase goal. WR-03/WR-04 are design observations; WR-05/WR-06 are post-install hardening; IN-03 is a tsconfig latent footgun for future rebuilds; IN-04 is a test-assertion fragility. |

---

### Human Verification Required

#### 1. SC-1 Numeric Coverage Record

**Test:** On ClawHub host (98.82.34.123), run `scripts/verify-markers.sh`, note the current coverage %, run a batch of substantive turns (exec tool calls), then run `scripts/verify-markers.sh` again.
**Expected:** Coverage % is substantially higher than the ~1/64 (~1.5%) baseline that motivated Phase 11. Record the before and after percentages.
**Why human:** Terminal history was cleared after the original validation (documented in 11-03-SUMMARY.md). The gate behavior was user-confirmed ("working great") and attribution is flowing on the Revenium side, but the PLAN's `<output>` spec and the SC-1 success criterion both called for recorded numeric evidence. This is a documentation gap, not a behavioral failure — but the verification spec requires it to be flagged as needing human confirmation.

---

### Gaps Summary

No hard gaps. The single uncertain item (SC-1 numeric coverage record) is a documentation gap stemming from terminal-history loss during the human-performed host validation. The gate behavior itself is fully implemented, unit-tested, and user-confirmed working end-to-end on the live ClawHub host. Automated local evidence (30/30 node tests, 16/16 shell tests, 10/10 + 18/18 regression tests) is complete. The only outstanding item is recording the before/after `verify-markers.sh` percentages — which the user can obtain by re-running the script on the live host at any time without re-validating any behavior.

**Dist parity:** `dist/gate.js` and `dist/index.js` mirror their `src/` counterparts. The MARKER_INVOKE regex is bit-for-bit identical between `src/gate.js` and `dist/gate.js`. The structural difference between src and dist is comment verbosity (src has extended multi-line block comments; dist has condensed single-line equivalents) — functionally identical.

**WR-01 deviation (verify-markers.sh):** The plan truth said "reuses common.sh SESSIONS_DIR / MARKERS_DIR (no re-declaration)." The implementation deliberately does NOT source `common.sh` (per review finding WR-01: sourcing it runs `mkdir -p "${STATE_DIR}"` at source time, violating the read-only contract). Instead, verify-markers.sh mirrors the OPENCLAW_HOME discovery and path constants inline. The artifact `contains: "common.sh"` check passes (5 comment references). The spirit of the must-have — reusing the same path logic without duplicating production state-writing behavior — is achieved through the WR-01 fix. This is a verified improvement, not a gap.

---

_Verified: 2026-06-05T00:00:00Z_
_Verifier: Claude (gsd-verifier)_
