---
phase: 03-guardrail-engine
verified: 2026-05-31T22:00:00Z
status: gaps_found
score: 10/12 must-haves verified
overrides_applied: 0
gaps:
  - truth: "GUARD-03: When budget is exceeded (warn-and-ask mode), agent warns user with current spend vs threshold context"
    status: failed
    reason: "SKILL.md only branches on halted:true/false. When autonomousMode=false (the default), guardrail-check.sh writes halted:false even on a block breach (new_halted = autonomous AND any_blocked = False AND True = False). SKILL.md reads halted:false and proceeds SILENTLY with no warn. The warn-and-ask path is never triggered by any code path."
    artifacts:
      - path: "scripts/guardrail-check.sh"
        issue: "Line 212: new_halted = autonomous and any_blocked — halted:false always written when autonomousMode=false"
      - path: "SKILL.md"
        issue: "Guardrail Check Procedure line 49: 'If halted is false: Proceed silently' — no warn state inspection, no rules[].state check"
    missing:
      - "SKILL.md needs a third branch: when halted:false but any rule has state=block or state=warn, emit the warn-and-ask message (rule name, currentValue vs hardLimit) and ask for permission before continuing"
      - "OR guardrail-check.sh needs to set halted:true (or a separate warned:true field) when autonomous=false AND any_blocked=true, so SKILL.md has a signal to act on"
  - truth: "GUARD-04: When budget is exceeded (non-autonomous mode), agent asks user for permission before continuing"
    status: failed
    reason: "Identical root cause as GUARD-03 gap. The 03-RESEARCH.md explicitly states GUARD-04 requires 'autonomousMode=false produces warn-and-ask'. The data flow is broken: guardrail-check.sh writes halted:false when autonomous=false, SKILL.md sees halted:false and proceeds silently — no ask-for-permission behavior exists."
    artifacts:
      - path: "SKILL.md"
        issue: "No code path exists to ask user for permission when halted:false but budget is over limit"
      - path: "scripts/guardrail-check.sh"
        issue: "Does not emit a warn-mode signal that SKILL.md could act on"
    missing:
      - "Implement the warn-and-ask path in SKILL.md — check rules[].state when halted:false; if any rule state is 'block' (and autonomous=false), warn with GUARD-05 spend context and ask permission"
human_verification:
  - test: "Verify GUARD-03/04 warn-and-ask behavior with a live rule breach"
    expected: "With autonomousMode=false and a rule in block state, agent should warn with spend context and ask for permission before continuing"
    why_human: "Requires a live Revenium rule breach or staged guardrail-status.json with block state and autonomousMode=false in config.json. Cannot verify from static code analysis alone for agent behavior."
  - test: "Verify halt notification fires exactly once on false->true transition (not on every cron tick while halted)"
    expected: "When guardrail-check.sh runs multiple times with a persistent block breach, openclaw message send is called exactly once"
    why_human: "Requires cron execution with a real or stubbed enforcement-rules endpoint returning a block rule"
  - test: "Verify shadow notification (GUARD D-12) fires one-shot only on first breach entry"
    expected: "Shadow rule entering block state triggers one openclaw message send; subsequent cron ticks with same rule blocked do not re-send"
    why_human: "Requires staged guardrail-status.json and enforcement API responses across multiple cron ticks"
  - test: "Verify clear-halt.sh preserves haltedRule and haltedAt after clearing"
    expected: "After running clear-halt.sh against a halted:true status file, halted=false but haltedRule and haltedAt fields remain"
    why_human: "Can be verified manually with: echo '{\"halted\":true,\"haltedAt\":\"2026-05-31T00:00:00Z\",\"haltedRule\":{\"name\":\"test\"},\"rules\":[]}' > /tmp/test-status.json && GUARDRAIL_STATUS_FILE=/tmp/test-status.json bash scripts/clear-halt.sh && cat /tmp/test-status.json"
---

# Phase 3: Guardrail Engine Verification Report

**Phase Goal:** Replace the budget-check.sh engine with a Revenium guardrail-native enforcement engine: poll guardrail rule state, write guardrail-status.json, and rewrite SKILL.md/BUDGET-GUARD.md to use guardrail halt logic.
**Verified:** 2026-05-31T22:00:00Z
**Status:** gaps_found
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | setup-guardrails.sh --interactive creates budget rule via revenium guardrails budget-rules create and writes ruleIds to config.json | VERIFIED | scripts/setup-guardrails.sh 619 lines; `create_rule()` uses `revenium guardrails budget-rules create --output json --filter "AGENT:IS:${REVENIUM_AGENT_NAME}"`; `write_rule_ids_and_config()` atomic write confirmed |
| 2 | guardrail-check.sh polls enforcement-rules get and writes guardrail-status.json atomically on every cron tick | VERIFIED | scripts/guardrail-check.sh 421 lines; `os.replace` atomic write at line 288; `revenium guardrails enforcement-rules get "${TEAM_ID}" --output json` at line 109 |
| 3 | When any non-shadow rule is in block state and autonomous mode is on, guardrail-status.json sets halted:true and agent emits verbatim halt string | VERIFIED | guardrail-check.sh line 212: `new_halted = autonomous and any_blocked`; D-09 shadow exclusion verified; SKILL.md HALT CHECK emits exact Pattern 7 template from haltedRule fields |
| 4 | Legacy alertId-only installs trigger Setup Flow; guardrail-check.sh exits 0 silently (D-13) | VERIFIED | D-13 guard at lines 36-52 in guardrail-check.sh; live test confirmed exit 0 with zero log lines when config has only alertId and no ruleIds |
| 5 | SKILL.md reads guardrail-status.json (not budget-status.json) and halt check uses haltedRule fields | VERIFIED | `grep -c 'budget-status.json\|percentUsed' SKILL.md` = 0; SKILL.md line 13: reads `~/.openclaw/skills/revenium/guardrail-status.json`; haltedRule substitution at lines 17-30 |
| 6 | BUDGET-GUARD.md references guardrail-status.json and is injected via bootstrap-extra-files | VERIFIED | BUDGET-GUARD.md 9 lines, references guardrail-status.json and halted field; post-install.sh lines 504-532 configure bootstrap-extra-files hook |
| 7 | cron.sh runs report.sh then guardrail-check.sh, no budget-check.sh reference | VERIFIED | cron.sh lines 70-71: `run_report "$@" \|\| true` then `bash "${SKILL_DIR}/scripts/guardrail-check.sh" \|\| true`; `grep -c budget-check.sh scripts/cron.sh` = 0 |
| 8 | budget-check.sh is deleted and no script references it | VERIFIED | `[ ! -f scripts/budget-check.sh ]` passes; `grep -rl budget-check.sh scripts/` returns empty |
| 9 | SKILL.md setup gate triggers Setup Flow when ruleIds is absent/empty (legacy alertId also triggers it) | VERIFIED | SKILL.md lines 61-66: explicit note that alertId-only config triggers Setup Flow; ruleIds is sole signal |
| 10 | SKILL.md Setup Flow delegates to setup-guardrails.sh --interactive and does not prompt for budget details itself | VERIFIED | SKILL.md lines 96-105: Setup Flow step 3 runs `bash ~/.openclaw/skills/revenium/scripts/setup-guardrails.sh --interactive`; explicit instruction "do NOT prompt the user for budget details yourself" |
| 11 | GUARD-03: When budget is exceeded (non-autonomous mode), agent warns user with spend context | FAILED | guardrail-check.sh writes halted:false when autonomousMode=false; SKILL.md sees halted:false and proceeds silently — no warn path exists for the default warn-and-ask mode |
| 12 | GUARD-04: When budget is exceeded (non-autonomous mode), agent asks user for permission | FAILED | Same root cause as GUARD-03; no ask-for-permission code path in SKILL.md or guardrail-check.sh when autonomous=false and budget breached |

**Score:** 10/12 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `scripts/common.sh` | Shared path constants and helpers | VERIFIED | 118 lines; GUARDRAIL_STATUS_FILE, REVENIUM_AGENT_NAME:-OpenClaw, /agents probe, has_guardrails_cli, ensure_path, log/info/warn/error; zero Hermes identifiers |
| `scripts/guardrail-check.sh` | Cron enforcement stage | VERIFIED | 421 lines; sources common.sh; atomic write via os.replace; all --output json; D-09/D-11/D-12/D-13/D-14/D-15 all present |
| `scripts/setup-guardrails.sh` | Interactive guardrail rule creation | VERIFIED | 619 lines; two-mode dispatch; budget-rules create; AGENT:IS: filter; OpenClaw naming; no migration code; shadow/autonomous prompts |
| `scripts/cron.sh` | Updated cron pipeline | VERIFIED | guardrail-check.sh wired; run_report before guardrail-check.sh; flock guard present; no budget-check.sh |
| `scripts/post-install.sh` | Install and wiring | VERIFIED | chmod loop includes common.sh/setup-guardrails.sh/guardrail-check.sh; seeds guardrail-status.json; AGENTS.md injection uses halted field; no budget-status.json/budget-check.sh refs |
| `scripts/clear-halt.sh` | Halt clear utility | VERIFIED | targets guardrail-status.json; atomic write via os.replace; preserves haltedRule/haltedAt (no pop calls); correct message strings |
| `SKILL.md` | Guardrail-native enforcement instructions | VERIFIED | 165 lines; guardrail-status.json halt check; haltedRule substitution; ruleIds gate; setup-guardrails.sh delegation; /revenium per-rule display; no budget-status.json/percentUsed/exceeded |
| `BUDGET-GUARD.md` | Minimal bootstrap halt directive | VERIFIED | 9 lines; guardrail-status.json reference; halted field check; redirects to SKILL.md; no budget-status.json/exceeded |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| scripts/guardrail-check.sh | scripts/common.sh | source "${SCRIPT_DIR}/common.sh" | WIRED | Line 21 |
| scripts/guardrail-check.sh | guardrail-status.json | os.replace atomic write | WIRED | Lines 280-293 |
| scripts/setup-guardrails.sh | scripts/common.sh | source "${SCRIPT_DIR}/common.sh" | WIRED | Line 16 |
| scripts/setup-guardrails.sh | config.json | write_rule_ids_and_config atomic write | WIRED | Lines 353-387; os.rename; preserves alertId |
| scripts/setup-guardrails.sh | revenium guardrails budget-rules create | AGENT:IS:${REVENIUM_AGENT_NAME} filter | WIRED | Lines 256-281 |
| scripts/cron.sh | scripts/guardrail-check.sh | pipeline invocation after run_report | WIRED | Line 71 |
| scripts/post-install.sh | guardrail-status.json | seed placeholder + chmod scripts | WIRED | Lines 389-400 (seed); line 114 (chmod) |
| SKILL.md | guardrail-status.json | halt check reads haltedRule block | WIRED | Lines 13-30 |
| SKILL.md | scripts/setup-guardrails.sh | Setup Flow delegation | WIRED | Line 98: `setup-guardrails.sh --interactive` |
| BUDGET-GUARD.md | SKILL.md | redirect for halt string | WIRED | Line 7 |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| guardrail-check.sh | ENFORCEMENT_JSON | `revenium guardrails enforcement-rules get "${TEAM_ID}" --output json` | Yes — live API call | FLOWING |
| guardrail-check.sh | BUDGET_RULES_JSON | `revenium guardrails budget-rules list --output json` | Yes — live API call | FLOWING |
| guardrail-check.sh | guardrail-status.json | os.replace atomic write from derived state | Yes — computed from API data | FLOWING |
| SKILL.md | halted | reads `~/.openclaw/skills/revenium/guardrail-status.json` | Yes — file written by guardrail-check.sh cron | FLOWING |
| SKILL.md | warn-and-ask (autonomousMode=false) | N/A — not implemented | No — no data flow path | DISCONNECTED |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| D-13 silent exit with alertId-only config | `TMP=$(mktemp -d); echo '{"alertId":"x"}' > ${TMP}/config.json; mkdir -p ${TMP}/agents; OPENCLAW_HOME=${TMP} bash scripts/guardrail-check.sh; echo $?; wc -l < ${TMP}/revenium-metering.log 2>/dev/null` | exit 0, 0 log lines | PASS |
| bash -n syntax all scripts | `bash -n scripts/{common,guardrail-check,setup-guardrails,cron,post-install,clear-halt}.sh` | all exit 0 | PASS |
| No budget-check.sh references anywhere in scripts/ | `grep -rl budget-check.sh scripts/` | empty output | PASS |
| guardrail-check.sh uses --output json (not --json) | `grep 'guardrails.*--json[^a-z]' scripts/guardrail-check.sh` | empty | PASS |
| D-13 guard line precedes first warn call | silent exit line 13 < first warn line 55 | confirmed | PASS |

### Probe Execution

No probe scripts declared in PLAN.md frontmatter. No conventional `scripts/*/tests/probe-*.sh` files found. Step 7c: SKIPPED (no probes defined for this phase).

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| GUARD-01 | 03-01, 03-02, 03-04, 03-05 | Agent checks guardrails before every operation | SATISFIED | guardrail-check.sh polls enforcement-rules get; SKILL.md reads guardrail-status.json before every turn |
| GUARD-02 | 03-02, 03-05 | When not exceeded, agent proceeds silently | SATISFIED | SKILL.md: "If halted is false: Proceed silently. Do NOT mention the guardrail status to the user." |
| GUARD-03 | 03-02, 03-05 | When exceeded, warns with spend context | BLOCKED | Only the autonomous halt path emits spend context (halt message with currentValue/hardLimit). When autonomousMode=false and a rule is in block state, halted:false is written and SKILL.md proceeds silently. |
| GUARD-04 | 03-02, 03-05 | When exceeded, asks user for permission | BLOCKED | No ask-for-permission code path exists in SKILL.md for the warn-and-ask mode. The design intent per 03-RESEARCH.md ("autonomousMode=false produces warn-and-ask") is not implemented. |
| GUARD-05 | 03-02, 03-05 | Warning includes actionable budget status | SATISFIED for autonomous path | Halt message template: `rule '[name]' (metricType, windowType) at currentValue of hardLimit hard-limit`. BLOCKED for warn-and-ask path (GUARD-04 gap). |
| GUARD-06 | 03-01, 03-03 | User can configure grace mode | SATISFIED | setup-guardrails.sh --interactive prompts for autonomous mode; autonomousMode field written to config.json; true=hard-stop, false=warn-and-ask |

**Orphaned requirements check:** All GUARD-01 through GUARD-06 appear in at least one plan's requirements field. No orphaned requirements.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| .planning/phases/03-guardrail-engine/03-01-SUMMARY.md | 68 | `TBD` in "Plan metadata: \`TBD\` (docs: complete plan)" | INFO | This is in a planning documentation file (SUMMARY.md), not in a source file modified by this phase. The TBD is a documentation placeholder for the plan commit metadata, not a code stub. The source file modified by this plan (scripts/common.sh) has zero TBD markers. Per the debt marker gate, this is informational only — it is in a docs file, not a source artifact. |
| scripts/post-install.sh | 397 | `info "Seeded guardrail-status.json placeholder"` | INFO | The word "placeholder" appears in a log message string describing the initial state file, not as a code stub. The code writes actual JSON data: `{'halted': False, 'lastChecked': None, 'rules': []}`. Not a stub. |

No FIXME, XXX, or unreferenced TBD markers found in any source files modified by this phase.

### Human Verification Required

#### 1. GUARD-03/04 Warn-and-Ask Behavior

**Test:** Set `autonomousMode: false` in `~/.openclaw/skills/revenium/config.json`. Stage a `guardrail-status.json` with a rule in `state: "block"` but `halted: false`. Then ask the agent any question.
**Expected:** Agent should warn with budget spend context (rule name, currentValue, hardLimit) and ask for permission before continuing — per GUARD-03 and GUARD-04.
**Why human:** The code analysis shows this path produces silent proceed, not warn-and-ask. Human testing confirms whether the missing implementation produces the wrong user-visible behavior.

#### 2. Halt Notification Transition Guard (D-11)

**Test:** Run `guardrail-check.sh` twice with a block rule staged. Confirm `openclaw message send` is called exactly once (on the first run), not on the second run.
**Expected:** `openclaw message send` invoked exactly 1 time total across 2 consecutive cron-tick simulations with the same block rule.
**Why human:** Requires a real or stubbed `enforcement-rules` endpoint returning a block rule across two runs. Static analysis confirms the HALT_TRANSITION gate is present; runtime confirms it fires correctly.

#### 3. Shadow Notification One-Shot (D-12)

**Test:** Run `guardrail-check.sh` with a shadow rule entering block state. Run it again with the same rule still blocked.
**Expected:** Shadow `[shadow]` notification sent once on first entry into block state. Silent on second run.
**Why human:** Same as above — requires staged API responses across two cron ticks.

#### 4. Clear-halt.sh Audit Trail Preservation

**Test:** `echo '{"halted":true,"haltedAt":"2026-05-31T00:00:00Z","haltedRule":{"name":"test","currentValue":5.1,"hardLimit":5.0},"rules":[]}' > /tmp/test-status.json && GUARDRAIL_STATUS_FILE=/tmp/test-status.json bash scripts/clear-halt.sh && cat /tmp/test-status.json`
**Expected:** Output shows `halted: false` AND `haltedRule` and `haltedAt` fields still present.
**Why human:** This specific behavioral test is runnable but requires the developer to run it directly against their shell environment. The code analysis confirms the correct implementation (no pop calls), but the test validates end-to-end behavior.

### Gaps Summary

**Root cause:** GUARD-03 and GUARD-04 require a warn-and-ask enforcement path for `autonomousMode=false`. The implementation has a data flow gap:

1. `guardrail-check.sh` computes `new_halted = autonomous AND any_blocked`. When `autonomousMode=false`, `new_halted` is always `false` regardless of whether rules are in `block` state.
2. `SKILL.md`'s Guardrail Check Procedure only branches on `halted: true/false`. When `halted` is `false`, the instruction is "Proceed silently. Do NOT mention the guardrail status to the user."
3. No code path exists in either file to emit spend-context warnings or ask for user permission when a rule is in block state but `autonomousMode` is `false`.

The Phase 3 ROADMAP Success Criteria SC3 is scoped to "autonomous mode is on" — so the autonomous hard-stop path passes. The warn-and-ask path is the GUARD-03/GUARD-04 gap. The `03-RESEARCH.md` explicitly documents the design intent as "autonomousMode=false produces warn-and-ask" (GUARD-04 traceability row), confirming this is expected behavior that was not implemented.

**Grouped gap:** GUARD-03 and GUARD-04 share the same root cause and require the same fix — adding a warn branch to SKILL.md (or a warn signal from guardrail-check.sh) for the non-autonomous block case.

---

_Verified: 2026-05-31T22:00:00Z_
_Verifier: Claude (gsd-verifier)_
