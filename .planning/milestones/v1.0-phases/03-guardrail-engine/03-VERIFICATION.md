---
phase: 03-guardrail-engine
verified: 2026-05-31T23:30:00Z
status: human_needed
score: 12/12 must-haves verified
overrides_applied: 0
re_verification:
  previous_status: gaps_found
  previous_score: 10/12
  gaps_closed:
    - "GUARD-03: guardrail-check.sh now writes warned:true + warnedRules[] when autonomousMode=false and a non-shadow rule is blocked; SKILL.md warn branch emits spend context (rule name, currentValue vs hardLimit)"
    - "GUARD-04: SKILL.md asks the user for permission before continuing when warned:true"
  gaps_remaining: []
  regressions: []
human_verification:
  - test: "Verify GUARD-03/04 warn-and-ask behavior with a staged guardrail-status.json"
    expected: "With autonomousMode=false and warned:true in guardrail-status.json (one warnedRules entry with name, currentValue, hardLimit), agent emits a 'Budget warning — rule ...' line per rule and asks 'Do you want me to proceed anyway, or stop?' before doing any work"
    why_human: "Agent instruction-following behavior cannot be verified from static code analysis. Requires staging guardrail-status.json with warned:true and warnedRules populated, then observing the live agent's response before it makes any tool call."
  - test: "Verify halt notification fires exactly once on false->true transition (not on every cron tick while halted)"
    expected: "When guardrail-check.sh runs multiple times with a persistent block breach, openclaw message send is called exactly once"
    why_human: "Requires cron execution with a real or stubbed enforcement-rules endpoint returning a block rule across two runs."
  - test: "Verify shadow notification (D-12) fires one-shot only on first breach entry"
    expected: "Shadow rule entering block state triggers one openclaw message send; subsequent cron ticks with same rule blocked do not re-send"
    why_human: "Requires staged guardrail-status.json and enforcement API responses across multiple cron ticks."
  - test: "Verify clear-halt.sh preserves haltedRule and haltedAt after clearing"
    expected: "After running clear-halt.sh against a halted:true status file, halted=false but haltedRule and haltedAt fields remain"
    why_human: "Runnable with: echo '{\"halted\":true,\"haltedAt\":\"2026-05-31T00:00:00Z\",\"haltedRule\":{\"name\":\"test\",\"currentValue\":5.1,\"hardLimit\":5.0},\"rules\":[]}' > /tmp/test-status.json && GUARDRAIL_STATUS_FILE=/tmp/test-status.json bash scripts/clear-halt.sh && cat /tmp/test-status.json"
---

# Phase 3: Guardrail Engine Verification Report (Re-verification)

**Phase Goal:** Replace budget-check.sh with a Revenium guardrail-native enforcement engine — poll guardrail rule state, write guardrail-status.json, rewrite SKILL.md/BUDGET-GUARD.md for guardrail halt logic, AND implement the warn-and-ask path for non-autonomous mode.
**Verified:** 2026-05-31T23:30:00Z
**Status:** human_needed
**Re-verification:** Yes — after gap closure (plans 03-06 and 03-07 executed to close GUARD-03/GUARD-04)

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | setup-guardrails.sh --interactive creates budget rule via revenium guardrails budget-rules create and writes ruleIds to config.json | VERIFIED | Unchanged from initial verification — confirmed by regression check (bash -n PASSED; no source changes to setup path) |
| 2 | guardrail-check.sh polls enforcement-rules get and writes guardrail-status.json atomically on every cron tick | VERIFIED | Unchanged from initial verification — os.replace atomic write at line 313; enforcement-rules get at line 109 |
| 3 | When any non-shadow rule is in block state and autonomous mode is on, guardrail-status.json sets halted:true and agent emits verbatim halt string | VERIFIED | new_halted = autonomous and any_blocked (line 212) — unchanged; SKILL.md HALT CHECK block byte-for-byte preserved; `grep -c 'Guardrail halt active' SKILL.md` = 1 |
| 4 | Legacy alertId-only installs trigger Setup Flow; guardrail-check.sh exits 0 silently (D-13) | VERIFIED | Unchanged from initial verification — D-13 guard at lines 36-52 still present and unchanged |
| 5 | SKILL.md reads guardrail-status.json (not budget-status.json) and halt check uses haltedRule fields | VERIFIED | `grep -c 'budget-status.json\|percentUsed' SKILL.md` = 0; halt check references haltedRule at lines 13-30 |
| 6 | BUDGET-GUARD.md references guardrail-status.json and is injected via bootstrap-extra-files | VERIFIED | Unchanged from initial verification |
| 7 | cron.sh runs report.sh then guardrail-check.sh, no budget-check.sh reference | VERIFIED | Unchanged from initial verification |
| 8 | budget-check.sh is deleted and no script references it | VERIFIED | Unchanged from initial verification |
| 9 | SKILL.md setup gate triggers Setup Flow when ruleIds is absent/empty | VERIFIED | Unchanged from initial verification — lines 69-72 |
| 10 | SKILL.md Setup Flow delegates to setup-guardrails.sh --interactive and does not prompt for budget details itself | VERIFIED | Unchanged from initial verification — lines 104-108 |
| 11 | GUARD-03: When autonomousMode=false and a non-shadow rule is blocked, guardrail-check.sh writes warned:true + warnedRules[], and SKILL.md warn branch emits spend context (rule name, currentValue vs hardLimit) | VERIFIED | **CLOSED.** guardrail-check.sh line 218: `new_warned = (not autonomous) and any_blocked`; lines 222-235: warned_rules built from all non-shadow blocked rules; lines 292-293: `'warned': new_warned` and `'warnedRules': warned_rules` written into data document. SKILL.md line 42: parses `warned` and `warnedRules`; line 48: `Else if warned is true` branch; line 51: per-rule "Budget warning — rule '[name]' ([metricType], [windowType]) at [currentValue] of [hardLimit] hard-limit." |
| 12 | GUARD-04: SKILL.md asks the user for permission before continuing when warned:true; agent waits and does not proceed until user grants permission | VERIFIED | **CLOSED.** SKILL.md lines 52-54: "Do you want me to proceed anyway, or stop?" — explicit ask; "WAIT for the user's answer. Do NOT perform the requested operation or any tool calls until the user grants permission." — wait instruction present; decline path ("stop without performing the operation") and grant path both specified. |

**Score:** 12/12 truths verified

### Re-verification Gap Closure Detail

**GUARD-03 gap — root cause was:** `new_halted = autonomous and any_blocked` produced `halted:false` when `autonomousMode=false`, and SKILL.md only branched on `halted:true/false` — no warn signal existed.

**Fix delivered by plan 03-06 (guardrail-check.sh):**
- Line 218: `new_warned = (not autonomous) and any_blocked` — independent warn signal
- Lines 222-235: `warned_rules` list built from all non-shadow blocked rules with `ruleId/name/metricType/windowType/currentValue/hardLimit` shape
- Lines 292-293: `'warned': new_warned` and `'warnedRules': warned_rules` written into the JSON document alongside existing `halted` keys
- Line 333: `|| { warn "guardrail status update failed — status file may be stale"; exit 0; }` fail-open guard on the HALT_OUTPUT subshell (CR-02)

**Fix delivered by plan 03-07 (SKILL.md):**
- Line 42: step 2 now extracts `warned` and `warnedRules` (not just `halted`)
- Lines 46-56: three-way evaluate branch — `halted:true` → halt (unchanged) → `warned:true` → NEW warn-and-ask branch → `else` → silent proceed (unchanged)
- Warn-and-ask branch: per-rule spend-context warning line + permission ask + wait instruction + decline/grant paths

**Regression check for GUARD-02 (silent proceed when no breach):** `grep -c 'Proceed silently' SKILL.md` = 1 at line 56: "Else (both halted and warned are false): Proceed silently." — preserved.

**Regression check for autonomous halt path (truth #3):** `new_halted = autonomous and any_blocked` at line 212 — unchanged. `grep -c 'Guardrail halt active' SKILL.md` = 1 — verbatim halt string preserved byte-for-byte.

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `scripts/guardrail-check.sh` | Cron enforcement stage with warn-mode signal | VERIFIED | 447 lines (was 421); new_warned at line 218; warnedRules at lines 222-235; written at lines 292-293; fail-open guard at line 333; bash -n PASSED |
| `SKILL.md` | Three-way evaluate branch (halted / warned / silent) | VERIFIED | 174 lines (was 165); warned parse at line 42; warn-and-ask branch at lines 48-54; silent-proceed at line 56; halt message unchanged |
| `scripts/setup-guardrails.sh` | Recreate path clears ruleIds before deletion (CR-01) | VERIFIED | `write_rule_ids_to_config '[]'` at line 493; deletion loop at line 498; line 493 < 498 confirmed; bash -n PASSED |
| `scripts/common.sh` | Shared path constants and helpers | VERIFIED | Unchanged — regression check only |
| `scripts/cron.sh` | Updated cron pipeline | VERIFIED | Unchanged — regression check only |
| `scripts/post-install.sh` | Install and wiring | VERIFIED | Unchanged — regression check only |
| `scripts/clear-halt.sh` | Halt clear utility | VERIFIED | Unchanged — regression check only |
| `BUDGET-GUARD.md` | Minimal bootstrap halt directive | VERIFIED | Unchanged — regression check only |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| scripts/guardrail-check.sh | guardrail-status.json | `'warned': new_warned` and `'warnedRules': warned_rules` in data document | WIRED | Lines 292-293; written by same os.replace atomic write at line 313 |
| SKILL.md | guardrail-status.json | warn-and-ask branch reads `warned` + `warnedRules` | WIRED | Lines 42, 48-54: parses warned and warnedRules from guardrail-status.json |
| scripts/guardrail-check.sh | scripts/common.sh | source "${SCRIPT_DIR}/common.sh" | WIRED | Line 21 — unchanged |
| scripts/setup-guardrails.sh | config.json | `write_rule_ids_to_config '[]'` before deletion loop in recreate branch | WIRED | Line 493 (clear) before line 498 (delete loop) — CR-01 fix confirmed |
| SKILL.md | scripts/setup-guardrails.sh | Setup Flow delegation | WIRED | Line 106: `setup-guardrails.sh --interactive` — unchanged |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| guardrail-check.sh | ENFORCEMENT_JSON | `revenium guardrails enforcement-rules get "${TEAM_ID}" --output json` | Yes — live API call | FLOWING |
| guardrail-check.sh | new_warned | `(not autonomous) and any_blocked` derived from API data | Yes — computed from live API response | FLOWING |
| guardrail-check.sh | warned_rules | non-shadow blocked rules from new_rules (API-derived) | Yes — populated from live rule data | FLOWING |
| guardrail-check.sh | guardrail-status.json | os.replace atomic write includes warned/warnedRules | Yes — computed from API data | FLOWING |
| SKILL.md | warned | reads `~/.openclaw/skills/revenium/guardrail-status.json` | Yes — file written by guardrail-check.sh cron | FLOWING |
| SKILL.md | warnedRules | reads `warned_rules` array from guardrail-status.json | Yes — populated by guardrail-check.sh when autonomousMode=false and any rule blocked | FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| bash -n guardrail-check.sh | `bash -n scripts/guardrail-check.sh` | exit 0 | PASS |
| bash -n setup-guardrails.sh | `bash -n scripts/setup-guardrails.sh` | exit 0 | PASS |
| new_warned computed in guardrail-check.sh | `grep -c "new_warned" scripts/guardrail-check.sh` | 3 (>= 2 required) | PASS |
| warnedRules key in data document | `grep -c "'warnedRules'" scripts/guardrail-check.sh` | 1 | PASS |
| warned key in data document | `grep -c "'warned'" scripts/guardrail-check.sh` | 1 | PASS |
| fail-open guard on HALT_OUTPUT subshell | `grep -cE '\)\s*\|\| \{ *warn' scripts/guardrail-check.sh` | 1 | PASS |
| write_rule_ids_to_config '[]' before deletion loop | line 493 < line 498 | confirmed | PASS |
| SKILL.md warns with hardLimit | `grep -c 'hardLimit' SKILL.md` within procedure | 2 (line 21 + line 51) | PASS |
| SKILL.md asks permission | `grep -iE 'proceed anyway' SKILL.md` | 1 match (line 52) | PASS |
| GUARD-02 silent-proceed preserved | `grep -c 'Proceed silently' SKILL.md` | 1 (line 56) | PASS |
| halt message verbatim string preserved | `grep -c 'Guardrail halt active' SKILL.md` | 1 (line 21) | PASS |
| no budget-status.json regression in SKILL.md | `grep -c 'budget-status.json\|percentUsed' SKILL.md` | 0 | PASS |
| no TBD/FIXME/XXX in modified source files | `grep -n "TBD\|FIXME\|XXX" scripts/guardrail-check.sh SKILL.md scripts/setup-guardrails.sh` | no output | PASS |

### Probe Execution

No probe scripts declared in PLAN frontmatter. No conventional `scripts/*/tests/probe-*.sh` files found. Step 7c: SKIPPED (no probes defined for this phase).

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| GUARD-01 | 03-01, 03-02, 03-04, 03-05 | Agent checks guardrails before every operation | SATISFIED | guardrail-check.sh polls enforcement-rules get; SKILL.md reads guardrail-status.json before every turn |
| GUARD-02 | 03-02, 03-05 | When not exceeded, agent proceeds silently | SATISFIED | SKILL.md line 56: "Else (both halted and warned are false): Proceed silently. Do NOT mention the guardrail status to the user." |
| GUARD-03 | 03-06, 03-07 | When exceeded (warn mode), warns with spend context | SATISFIED | guardrail-check.sh writes warned:true + warnedRules[]; SKILL.md warn branch emits "Budget warning — rule '[name]' ([metricType], [windowType]) at [currentValue] of [hardLimit] hard-limit." per rule |
| GUARD-04 | 03-06, 03-07 | When exceeded (non-autonomous mode), asks user for permission | SATISFIED | SKILL.md lines 52-54: explicit ask "Do you want me to proceed anyway, or stop?"; WAIT instruction; tool-call block until permission granted |
| GUARD-05 | 03-02, 03-05, 03-07 | Warning includes actionable budget status | SATISFIED | Warn message template (line 51): `rule '[name]' ([metricType], [windowType]) at [currentValue] of [hardLimit] hard-limit` — currentValue vs hardLimit framing present for both halt and warn paths |
| GUARD-06 | 03-01, 03-03 | User can configure grace mode | SATISFIED | setup-guardrails.sh --interactive prompts for autonomous mode; autonomousMode field written to config.json; true=hard-stop, false=warn-and-ask |

**Orphaned requirements check:** All GUARD-01 through GUARD-06 appear in at least one plan's requirements field. No orphaned requirements.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | — | — | No TBD, FIXME, or XXX markers found in any source files modified by plans 03-06 or 03-07. No stubs or placeholder returns found in the warn-and-ask code paths. |

### Human Verification Required

#### 1. GUARD-03/04 Warn-and-Ask Behavior (End-to-End)

**Test:** Stage `~/.openclaw/skills/revenium/guardrail-status.json` with `warned: true`, `warnedRules: [{"name":"OpenClaw Daily Budget","metricType":"TOTAL_COST","windowType":"MONTHLY","currentValue":6.0,"hardLimit":5.0}]`, `halted: false`, `autonomousMode: false`. Ask the agent any question (e.g., "List my files").
**Expected:** Before doing any work, agent emits "Budget warning — rule 'OpenClaw Daily Budget' (TOTAL_COST, MONTHLY) at 6.0 of 5.0 hard-limit." followed by "This rule's hard limit has been reached and you are in warn-and-ask mode (autonomous mode disabled). Do you want me to proceed anyway, or stop?" Agent does NOT list files until the user responds.
**Why human:** Agent instruction-following behavior (does the agent actually pause and wait, or does it proceed immediately?) cannot be verified from static code analysis. Requires observing live agent behavior with a staged status file.

#### 2. Halt Notification Transition Guard (D-11)

**Test:** Run `guardrail-check.sh` twice with a block rule staged. Confirm `openclaw message send` is called exactly once (on the first run), not on the second run.
**Expected:** `openclaw message send` invoked exactly 1 time total across 2 consecutive cron-tick simulations with the same block rule.
**Why human:** Requires a real or stubbed `enforcement-rules` endpoint returning a block rule across two runs. Static analysis confirms the HALT_TRANSITION gate is present; runtime confirms it fires correctly.

#### 3. Shadow Notification One-Shot (D-12)

**Test:** Run `guardrail-check.sh` with a shadow rule entering block state. Run it again with the same rule still blocked.
**Expected:** Shadow `[shadow]` notification sent once on first entry into block state. Silent on second run.
**Why human:** Requires staged API responses across two cron ticks.

#### 4. Clear-halt.sh Audit Trail Preservation

**Test:** `echo '{"halted":true,"haltedAt":"2026-05-31T00:00:00Z","haltedRule":{"name":"test","currentValue":5.1,"hardLimit":5.0},"rules":[]}' > /tmp/test-status.json && GUARDRAIL_STATUS_FILE=/tmp/test-status.json bash scripts/clear-halt.sh && cat /tmp/test-status.json`
**Expected:** Output shows `halted: false` AND `haltedRule` and `haltedAt` fields still present.
**Why human:** Directly runnable but requires the developer to execute against their shell environment.

### Gaps Summary

No gaps. All 12 must-haves are now verified. GUARD-03 and GUARD-04 are closed.

**Gap closure summary:**
- Plan 03-06 added the producer signal: `warned`/`warnedRules` written to guardrail-status.json by guardrail-check.sh when `autonomousMode=false` and at least one non-shadow rule is in block state. The halt derivation (`new_halted = autonomous and any_blocked`) was not altered.
- Plan 03-07 added the consumer: SKILL.md now has a three-way evaluate branch. The `warned:true` branch reads `warnedRules`, emits per-rule spend-context warnings with `currentValue` vs `hardLimit`, and asks the user for permission before making any tool call. The `halted:true` (hard-stop) and `else` (silent-proceed) branches are byte-for-byte unchanged.
- CR-01 and CR-02 were resolved as part of the same plans. CR-02: fail-open guard on the HALT_OUTPUT subshell at line 333 of guardrail-check.sh. CR-01: `write_rule_ids_to_config '[]'` called at line 493 of setup-guardrails.sh before the deletion loop at line 498.

Human verification items #1-4 are carried forward from the initial verification unchanged. Item #1 (warn-and-ask live agent behavior) is the primary human check gating the GUARD-03/04 closure acceptance.

---

_Verified: 2026-05-31T23:30:00Z_
_Verifier: Claude (gsd-verifier)_
