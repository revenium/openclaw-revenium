---
phase: 04-task-metering-attribution
verified: 2026-06-03T00:00:00Z
status: passed
human_verification_outcome: "User accepted 2026-06-03. SC3 (task-type end-to-end) live-confirmed working after correlation fix 48f7e44. SC1 (legacy notice) and SC2 (subagent rollup) accepted with caveats tracked in 04-HUMAN-UAT.md Gaps — notice path unverified (rule fixed directly via CLI); subagent->root rollup unverified (no subagents in test session). Neither caveat affects core metering correctness."
score: 5/5 must-haves verified
overrides_applied: 0
human_verification:
  - test: "Run /revenium in an agent session with a known legacy rule (AGENT:IS:OpenClaw) in Revenium and confirm exactly-once notice text matches the verbatim string: 'Your budget rules use the old filter and won't track spend — run reconfigure.'"
    expected: "Notice appears exactly once. After closing the session and opening a new one, the notice does NOT reappear (persisted via _legacyNoticeShown in config.json). No auto-rewrite of rules occurs."
    why_human: "Requires a live Revenium API session with a pre-existing legacy rule, and verifies one-time persistence behavior across separate agent invocations. Cannot simulate with grep."
  - test: "In a multi-subagent scenario, run a parent session that spawns a subagent. After the cron tick, check that the subagent's meter completions in Revenium carry --agent openclaw-<parent-session-id>, NOT --agent openclaw-<subagent-session-id>."
    expected: "Subagent completions appear in Revenium under the root session agent name, enabling spend rollup per root conversation."
    why_human: "Requires a live OpenClaw multi-session execution and Revenium API query to verify agent attribution. The unit tests cover the resolver logic but not the end-to-end attribution in production data."
  - test: "Run write-marker.sh for a valid label (e.g. 'generation'), then trigger a cron tick, and query Revenium to confirm the meter completion for that session carries --task-type generation (not unclassified)."
    expected: "The completion row in Revenium dashboard shows task_type=generation. The timestamp-precedence correlation in report.sh correctly matched the marker to the completion."
    why_human: "Requires end-to-end live metering pipeline: real session JSONL, real marker file, real cron tick, real Revenium API query. Integration tests use stubs and verify argv capture, not actual Revenium ingestion."
---

# Phase 4: Task Metering & Attribution Verification Report

**Phase Goal:** Every meter completion carries a `--task-type` from the controlled taxonomy; SKILL.md mandates task classification before every substantive turn; subagent spend rolls up under the root session via `AGENT:STARTS_WITH:openclaw-{root_session_id}` naming; setup offers optional per-task-type guardrail rules.
**Verified:** 2026-06-03T00:00:00Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `task-taxonomy.json` exists with the 8 canonical labels (METER-01) | ✓ VERIFIED | File at repo root. `python3 -c` label-set assertion confirms exact match: {research, analysis, generation, review, code_review, refactor, planning, debugging}. Seeded into `${SKILL_DIR}/task-taxonomy.json` by post-install.sh. |
| 2 | SKILL.md contains mandatory TASK CLASSIFICATION section that fires before every substantive turn and writes a per-session task marker (METER-02) | ✓ VERIFIED | Section at SKILL.md:63 (`## TASK CLASSIFICATION`), marked MANDATORY NON-NEGOTIABLE. Trigger rules at SKILL.md:67-79 (binary — tool use OR >200 words OR multi-step reasoning). write-marker.sh directive at SKILL.md:98-108. `unclassified` default documented. No agentic_job_id, JOB DECLARATION, or classifier-plugin references present. |
| 3 | `report.sh` reads task markers and passes `--task-type <label>` on every `revenium meter completion` call, defaulting to `unclassified` (METER-03) | ✓ VERIFIED | `--task-type "${task_type:-unclassified}"` at report.sh:247 (always-present). NP-1 timestamp-precedence lookup at report.sh:448-471 using env-passing heredoc. Default `unclassified` initialized at line 448, overridden only when marker ts <= completion ts. Integration test (`test_report_argv.sh`) confirms all 6 cases: correct label by precedence, unclassified default, always-present invariant — 6/6 passed. |
| 4 | `report.sh` resolves the root session ID and passes `--agent "openclaw-{root_session_id}"` so subagent spend aggregates correctly (TRACE-01/02) | ✓ VERIFIED | `get_root_session_id()` inline wrapper at report.sh:49-57 delegates to `get-root-session-id.py`. Root resolved once per session at report.sh:312-314 with belt-and-suspenders fallback `root_sid="${root_sid:-${session_id}}"`. `--agent "${REVENIUM_AGENT_PREFIX}${root_sid}"` at report.sh:246. Resolver unit tests (7/7 passed): no-parent, one-hop, cycle, missing-dir, malformed, empty-sid × 2. |
| 5 | `setup-guardrails.sh --interactive` offers optional per-task-type budget rules drawn from `task-taxonomy.json` (ROADMAP SC5) | ✓ VERIFIED | Capability gate at setup-guardrails.sh:686 (`grep -q 'TASK_TYPE'`). Picker reads TAXONOMY_FILE labels via env-passing heredoc at line 690. Each per-task rule: `TASK_TYPE:IS:<label>` extra filter + `--group-by TASK_TYPE` override (NP-4 fix). Base filter both branches: `AGENT:STARTS_WITH:${REVENIUM_AGENT_PREFIX}` (2 occurrences at lines 292, 312). No legacy `AGENT:IS` filter remains. Integration test (11/11 passed): Suite A verifies base+per-task rules with correct filters; Suite B verifies gate blocks picker and base rule still created. |

**Score:** 5/5 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `task-taxonomy.json` | 8-label vocabulary (METER-01) | ✓ VERIFIED | Exists at repo root. Contains `code_review`. Dict-form labels key. 8 labels exact. Post-install seeds to SKILL_DIR. |
| `scripts/common.sh` | REVENIUM_AGENT_PREFIX + TAXONOMY_FILE + MARKERS_DIR + SESSIONS_DIR + get_root_session_id() | ✓ VERIFIED | All 4 constants at lines 53-55, 66. get_root_session_id() wrapper at lines 150-158. REVENIUM_AGENT_PREFIX defaults to `"openclaw-"`. |
| `scripts/get-root-session-id.py` | JSONL childSessionKey reverse-walk resolver (TRACE-01) | ✓ VERIFIED | Contains `childSessionKey` scan, max_depth=10 cycle guard, per-line try/except, blanket except, __main__ block. All 5 specified behaviors covered. |
| `scripts/write-marker.sh` | Taxonomy-validated ISO8601 marker writer with flock (METER-02) | ✓ VERIFIED | Allowlist validation, sid charset guard, LOCK_EX+O_APPEND, mode 0700 markers dir, ISO8601 ts, env-passing heredoc. |
| `scripts/report.sh` | task-type correlation + --agent/--task-type wiring (METER-03/TRACE-01/02) | ✓ VERIFIED | MARKERS_DIR, REVENIUM_AGENT_PREFIX, get_root_session_id inline. root_sid once per session. NP-1 lookup. --agent openclaw-{root}. --task-type always present. |
| `scripts/setup-guardrails.sh` | STARTS_WITH base filter + per-task-type picker (D-07/D-10) | ✓ VERIFIED | 2 occurrences of `AGENT:STARTS_WITH`. 0 occurrences of `AGENT:IS`. TAXONOMY_FILE read in picker. TASK_TYPE:IS:<label> + group-by TASK_TYPE on per-task rules. |
| `scripts/cron.sh` | Marker prune stage in both lock branches (D-04) | ✓ VERIFIED | prune_markers() at lines 84-86 using `find -mtime +7 -delete 2>/dev/null`. Called with `|| true` in both flock (line 94) and mkdir (line 109) branches. bash -n passes. |
| `scripts/post-install.sh` | chmod new scripts + taxonomy seed + markers dir 0700 | ✓ VERIFIED | write-marker.sh and get-root-session-id.py in chmod loop at line 114. Taxonomy seed at lines 125-135. `mkdir -p "${SKILL_DIR}/markers" && chmod 700` at lines 140-141. bash -n passes. |
| `SKILL.md` | TASK CLASSIFICATION section + legacy reconfigure notice | ✓ VERIFIED | Section at line 63. write-marker.sh directive. unclassified default. Legacy notice at lines 191-234: verbatim string `"Your budget rules use the old filter and won't track spend — run reconfigure."` present. _legacyNoticeShown flag + atomic write. No auto-rewrite. |
| `references/task-classification.md` | Trigger rules + worked examples, plugin/job refs stripped | ✓ VERIFIED | File exists. References write-marker.sh. No agentic_job_id or classifier plugin references. |
| `tests/stub-revenium.sh` | Argv-capturing revenium stub for integration tests | ✓ VERIFIED | Exists at tests/stub-revenium.sh, executable. |
| `tests/test_get_root_session_id.py` | Resolver unit tests (7 cases) | ✓ VERIFIED | 7/7 pass on live run. |
| `tests/test_write_marker.sh` | write-marker.sh integration tests (10 cases) | ✓ VERIFIED | 10/10 pass on live run. |
| `tests/test_report_argv.sh` | report.sh argv-capture integration tests (6 cases) | ✓ VERIFIED | 6/6 pass on live run. |
| `tests/test_setup_guardrails_argv.sh` | setup-guardrails.sh argv-capture integration tests (11 cases) | ✓ VERIFIED | 11/11 pass on live run. |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `scripts/common.sh` | `scripts/get-root-session-id.py` | `python3 "${SKILL_DIR}/scripts/get-root-session-id.py"` in get_root_session_id() | ✓ WIRED | common.sh:156 invokes the sidecar with OPENCLAW_HOME passthrough. |
| `scripts/report.sh` | `get_root_session_id` wrapper | Inline definition in report.sh:49-57 (not source common.sh — avoids double-define) | ✓ WIRED | Invoked at report.sh:313 once per session. |
| `scripts/report.sh` | `markers/<sid>.jsonl` | `MARKERS_DIR/${session_id}.jsonl` at report.sh:321 read into cache | ✓ WIRED | Marker cache built once per session from MARKERS_DIR. |
| `scripts/write-marker.sh` | `task-taxonomy.json` | `TAXONOMY_FILE` env var passed to python3 heredoc; labels loaded from it | ✓ WIRED | write-marker.sh:39-55 env-passes TAXONOMY_FILE and validates task_type against labels set. |
| `SKILL.md` | `scripts/write-marker.sh` | `bash ~/.openclaw/skills/revenium/scripts/write-marker.sh <task_type>` directive | ✓ WIRED | SKILL.md:99-101. Step 2 of Required Action. |
| `scripts/setup-guardrails.sh` | `task-taxonomy.json` | TAXONOMY_FILE read in picker via env-passing heredoc | ✓ WIRED | setup-guardrails.sh:688-698. Picker conditional on TAXONOMY_FILE existence. |
| `scripts/cron.sh` | `markers/*.jsonl` | `prune_markers()` uses MARKERS_DIR variable | ✓ WIRED | cron.sh:78 defines MARKERS_DIR; prune_markers at line 85 references it. |
| `scripts/post-install.sh` | `task-taxonomy.json` | Seed copy into SKILL_DIR if absent | ✓ WIRED | post-install.sh:125-135. |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|-------------------|--------|
| `scripts/report.sh` | `task_type` | `markers_cache_file` built from `${MARKERS_DIR}/${session_id}.jsonl`, written by `write-marker.sh` | Yes — real JSONL from marker files; defaults to `unclassified` when no marker | ✓ FLOWING |
| `scripts/report.sh` | `root_sid` | `get_root_session_id()` → `get-root-session-id.py` → JSONL childSessionKey scan | Yes — real session JSONL walk; fail-open to own sid | ✓ FLOWING |
| `scripts/report.sh` | `--agent` value | `"${REVENIUM_AGENT_PREFIX}${root_sid}"` — prefix constant + resolved root_sid | Yes — always populated (openclaw- + either parent uuid or own sid) | ✓ FLOWING |
| `scripts/report.sh` | `--task-type` value | `task_type` from NP-1 marker lookup | Yes — real marker timestamp comparison; defaults to `unclassified` | ✓ FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| task-taxonomy.json has 8 exact labels | `python3 -c "import json,sys; d=json.load(open('task-taxonomy.json')); sys.exit(0 if set(d['labels'])=={...} else 1)"` | MATCH | ✓ PASS |
| Resolver unit tests pass | `python3 -m unittest tests.test_get_root_session_id -v` | 7 tests, OK | ✓ PASS |
| write-marker integration tests pass | `bash tests/test_write_marker.sh` | 10 passed, 0 failed | ✓ PASS |
| report.sh argv-capture integration tests pass | `bash tests/test_report_argv.sh` | 6 passed, 0 failed | ✓ PASS |
| setup-guardrails argv-capture integration tests pass | `bash tests/test_setup_guardrails_argv.sh` | 11 passed, 0 failed | ✓ PASS |
| cron.sh and post-install.sh syntax-check | `bash -n scripts/cron.sh && bash -n scripts/post-install.sh` | Both PASSED | ✓ PASS |
| No AGENT:IS filter remains in setup-guardrails.sh | `grep 'AGENT:IS' scripts/setup-guardrails.sh` | NONE FOUND | ✓ PASS |
| AGENT:STARTS_WITH appears exactly 2 times in filter args | `grep -c '"AGENT:STARTS_WITH:' scripts/setup-guardrails.sh` | 2 | ✓ PASS |

### Probe Execution

Step 7c: SKIPPED — no probe-*.sh scripts declared or conventionally present for this phase. Integration tests (`test_*.sh`, `test_*.py`) serve as the runnable verification layer; all pass (confirmed in Behavioral Spot-Checks above).

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| METER-01 | 04-01-PLAN.md | task-taxonomy.json with 8-label vocabulary | ✓ SATISFIED | task-taxonomy.json verified with exact 8 labels. TAXONOMY_FILE constant in common.sh. |
| METER-02 | 04-02-PLAN.md, 04-04-PLAN.md | write-marker.sh validates + appends; SKILL.md mandates classification before every substantive turn | ✓ SATISFIED | write-marker.sh: taxonomy allowlist, ISO8601, flock. SKILL.md: TASK CLASSIFICATION at line 63, write-marker.sh directive. |
| METER-03 | 04-02-PLAN.md | report.sh passes --task-type on every meter completion (default unclassified) | ✓ SATISFIED | report.sh:247 always-present --task-type. NP-1 precedence lookup. test_report_argv.sh 6/6. |
| TRACE-01 | 04-01-PLAN.md, 04-02-PLAN.md | Root session resolution via JSONL childSessionKey walk | ✓ SATISFIED | get-root-session-id.py: child_to_parent reverse map. 7 unit tests pass. |
| TRACE-02 | 04-02-PLAN.md | report.sh passes --agent openclaw-{root} for subagent attribution | ✓ SATISFIED | report.sh:246 `--agent "${REVENIUM_AGENT_PREFIX}${root_sid}"`. test_report_argv.sh case 5. |

**REQUIREMENTS.md note:** METER-01 through TRACE-02 are referenced in ROADMAP.md but not individually defined in REQUIREMENTS.md (which only covers SKAF-*, SETUP-*, and GUARD-* v1/v2 requirements). The ROADMAP success criteria serve as the functional definitions for these phase-4 requirement IDs. No orphaned requirements were found.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `scripts/report.sh` | 487-502 | `python3 -c` with `${request_time}` and `${timestamp}` interpolated directly into the program string — code injection vector (CR-01 from review) | ⚠️ WARNING | Affects duration_ms calculation only. Does NOT affect `--agent` or `--task-type` values (those use env-passing heredocs). Duration corruption is masked by `2>/dev/null || echo 0` guard. Does not block the phase goal (completions still carry correct agent/task-type), but violates the project's own env-passing rule (T-04-09) and is a security defect. |
| `scripts/report.sh` | 178-204 | `python3 -c` with `${OFFSETS_FILE}` and `${sid}`/`${count}` interpolated in get_offset/set_offset (IN-02 from review; related to CR-01) | ⚠️ WARNING | OFFSETS_FILE is a controlled constant (not untrusted input), but sid comes from session filenames. Not exploitable under normal operation. Part of the CR-01 fix scope. |
| `scripts/report.sh` | 604 | `set_offset "${session_id}" "${total_lines}"` unconditionally after the per-line loop — offset advances even when `post_to_revenium` failed (CR-02 from review) | ⚠️ WARNING | Silent permanent loss of metering events on transient post failure. Does NOT affect correctness of --task-type or --agent on events that DO post, but means failed completions are never retried. Data integrity defect for a billing product, but does not prevent the phase goal from being OBSERVABLE when the API is available. |
| `scripts/report.sh` | 350, 377 | Double `trap ... EXIT` — second trap replaces first; `markers_cache_file` never cleaned up across sessions (WR-01 from review) | ℹ️ INFO | Temp file accumulation under cron (3 files per session, every tick). Not a correctness defect for the phase goal. |

**Debt marker gate:** No `TBD`, `FIXME`, or `XXX` markers found in any phase-4 modified file. Gate: PASSED.

**Stub classification assessment:**
- CR-01 (duration_ms python3 -c interpolation): Affects supplementary field only, not the two fields the phase goal requires (`--agent`, `--task-type`). Not a stub of goal functionality — the goal-required wiring uses env-passing heredocs correctly. Classified as WARNING, not BLOCKER.
- CR-02 (unconditional offset advance): Does not cause `--task-type` or `--agent` to be absent from successful posts. Classified as WARNING (data integrity gap), not BLOCKER for this phase's goal.
- Neither critical finding blocks the 5 success criteria from being TRUE in the codebase.

### Human Verification Required

#### 1. Legacy-filter one-time notice (D-08)

**Test:** In an agent session where Revenium has an existing budget rule with `AGENT:IS:OpenClaw` filter, invoke `/revenium`. Observe the notice text. Close the session and open a new one; invoke `/revenium` again.
**Expected:** First invocation shows exactly: "Your budget rules use the old filter and won't track spend — run reconfigure." Second invocation does NOT show the notice (suppressed by `_legacyNoticeShown: true` in config.json). No rule auto-rewrite occurs.
**Why human:** Requires a live Revenium API with a pre-existing legacy rule. The SKILL.md prose and atomic write code can be read, but the one-time suppression behavior across sessions cannot be verified by static analysis.

#### 2. Subagent spend rollup in Revenium dashboard

**Test:** Run a parent session that spawns a subagent via OpenClaw's subagent mechanism. Allow the cron to tick. Query the Revenium API for completions from that time window.
**Expected:** Both parent and subagent completions appear under the same agent string `openclaw-<parent-session-uuid>`. The Revenium spend dashboard shows them grouped under one root session.
**Why human:** Requires live multi-session OpenClaw execution + Revenium API verification. The resolver unit tests and argv-capture integration tests are comprehensive for the logic, but end-to-end subagent spend rollup in production Revenium requires runtime observation.

#### 3. End-to-end task classification reaching Revenium

**Test:** Call `write-marker.sh generation` before a turn, complete the turn, wait for cron tick, check Revenium dashboard for the session's completions.
**Expected:** Completion rows for that session carry `task_type=generation` (not `unclassified`). Completions before the marker write carry `unclassified`. Timestamp-precedence correlation works in production JSONL (WR-02 timestamp tie-breaking edge case noted — may affect same-second marker+completion).
**Why human:** Requires live metering pipeline end-to-end. The integration test stubs revenium and verifies argv; it does not verify actual Revenium ingestion or real session JSONL timestamp format compatibility.

### Gaps Summary

No gaps blocking the phase goal. All 5 success criteria have verified implementations in the codebase. Both critical code review findings (CR-01, CR-02) affect secondary behaviors (duration computation and failure retry), not the goal-critical paths (`--task-type` and `--agent` on every successful post). Three items require human verification to confirm end-to-end runtime behavior that cannot be checked by static analysis or stubs.

---

_Verified: 2026-06-03T00:00:00Z_
_Verifier: Claude (gsd-verifier)_
