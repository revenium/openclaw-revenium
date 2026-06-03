---
phase: 04-task-metering-attribution
plan: "04"
subsystem: skill-md-classification-and-install-plumbing
tags: [meter-02, d-04, d-08, d-09, task-classification, write-marker, cron-prune, post-install]
dependency_graph:
  requires:
    - 04-02 (write-marker.sh contract — taxonomy validation + ISO8601 + 'marker written: <path>' confirmation)
    - 04-03 (AGENT:STARTS_WITH:openclaw- filter + config.json structure)
  provides:
    - SKILL.md TASK CLASSIFICATION section (METER-02/D-09 mandatory directive)
    - references/task-classification.md (ported trigger rules + worked examples; plugin/job refs stripped)
    - scripts/cron.sh D-04 marker prune stage in both lock branches (fail-open)
    - scripts/post-install.sh write-marker.sh + get-root-session-id.py chmod + task-taxonomy.json seed + markers/ 0700
  affects:
    - All future agent sessions (SKILL.md mandate fires before every substantive turn)
    - Cron tick (prune now runs after report.sh + guardrail-check.sh)
    - Install flow (post-install now sets up full metering plumbing in one pass)
tech_stack:
  added: []
  patterns:
    - D-09: binary trigger rule (non-read-only tool OR >200 words OR multi-step reasoning; skip only when <=2 sentences AND zero tools)
    - D-08: one-time legacy notice persisted via config.json _legacyNoticeShown flag (atomic temp-then-rename, 03-PATTERNS)
    - D-04: mtime-based prune using find -mtime +7 (BSD/GNU portable); fail-open || true; runs after enforcement
    - ASVS V4: markers/ dir created at mode 0700 in post-install
key_files:
  created:
    - references/task-classification.md (trigger rules, 8-label table, read-only blocklist, worked examples)
  modified:
    - SKILL.md (TASK CLASSIFICATION section + D-08 legacy notice in /revenium command flow)
    - scripts/cron.sh (MARKERS_DIR constant + prune_markers() + prune call in both lock branches)
    - scripts/post-install.sh (write-marker.sh + get-root-session-id.py chmod + taxonomy seed + markers/ 0700)
decisions:
  - "Inline MARKERS_DIR in cron.sh (not source common.sh): cron.sh is self-contained with its own OPENCLAW_HOME probe; inlining avoids potential double-definition of path constants and set -uo pipefail interaction with the sourced library"
  - "prune_markers() as inline function in cron.sh (not in report.sh): D-04 discretion — cron.sh is the per-tick orchestrator; placing prune there (after enforcement calls) makes the fail-open posture explicit and keeps report.sh focused on per-session work"
  - "TAXONOMY_SRC == TAXONOMY_DST in post-install: OpenClaw collapses skill dir and state dir (Pitfall 6); the seed step is idempotent (skips if already present) and guards against a missing source file with a warn (not fail)"
  - "Legacy notice detection uses live revenium guardrails budget-rules list --output json as primary mechanism; config.json schemaVersion field as fallback; mechanism is Claude's discretion per D-08"
  - "_legacyNoticeShown flag in config.json uses atomic temp-then-rename (03-PATTERNS 'Atomic JSON Write') to prevent config corruption (T-04-19)"
metrics:
  duration: "~6 minutes"
  completed: "2026-06-03"
  tasks_completed: 3
  files_created: 1
  files_modified: 3
---

# Phase 4 Plan 04: SKILL.md Classification + Install Plumbing Summary

**One-liner:** SKILL.md mandatory TASK CLASSIFICATION section (D-09 binary trigger + single write-marker.sh call, METER-02), D-08 legacy-install reconfigure notice in /revenium command flow (one-time, persisted, no auto-rewrite), D-04 marker prune stage in cron.sh (both lock branches, fail-open), and post-install wiring (write-marker.sh + get-root-session-id.py chmod, task-taxonomy.json seed, markers/ 0700).

## What Was Built

### Task 1: SKILL.md TASK CLASSIFICATION section + ported reference (METER-02/D-09)

**SKILL.md** — Added `## TASK CLASSIFICATION` section between `## Guardrail Check Procedure` and `## Path Resolution`:

- Binary trigger rule: classify if called any non-read-only tool OR produced >200 words OR answered a multi-step reasoning question; skip ONLY when ≤2 sentences AND zero tools called.
- 8-label taxonomy table (research, analysis, generation, review, code_review, refactor, planning, debugging) with usage descriptions.
- Default to `unclassified` when no label fits or marker write fails (non-blocking).
- Single directive: `bash ~/.openclaw/skills/revenium/scripts/write-marker.sh <task_type>` — confirmation is `marker written: <path>`; non-zero exit is a protocol error that does not block the response.
- Linked to `references/task-classification.md` for full operational detail.
- "Why this matters" prose explaining the cron attribution chain.
- No JOB DECLARATION, agentic_job_id, classifier-plugin, or job-declaration.md references (all dropped per plan).

**references/task-classification.md** — New file (ported from Hermes, stripped of all plugin/job references):

- Trigger rules section (binary, same as SKILL.md).
- Read-only tools exempt from rule (a).
- Required action sequence: pick label from fixed 8-label set → call write-marker.sh.
- Blocked label list (ack, acknowledgment, greeting, confirmation, hello, thanks — rejected by write-marker.sh allowlist).
- Self-check checklist (3 questions before yielding).
- 4 worked examples (2 classify, 2 skip).

### Task 2: SKILL.md legacy-install reconfigure notice (D-08)

In the `/revenium` command's "If Setup Is Complete" branch, added a 4-step legacy-install detection block:

1. Read `_legacyNoticeShown` from `config.json` — if `true`, skip detection (notice already delivered).
2. Detect legacy rules via `revenium guardrails budget-rules list --output json`; check for any rule with `AGENT:IS:OpenClaw` filter. Fallback: missing `schemaVersion` in `config.json` indicates a pre-D-07 install.
3. If a legacy rule is detected, surface EXACTLY ONCE the verbatim notice: "Your budget rules use the old filter and won't track spend — run reconfigure." Point to reconfigure action. Document WHY: D-07 changed --agent to `openclaw-{root_sid}`; rules filtering `AGENT:IS:OpenClaw` now match nothing; user must reconfigure since repo edits cannot fix server-side rules. No unilateral rule rewrite.
4. Persist `_legacyNoticeShown: true` via atomic temp-then-rename write (03-PATTERNS "Atomic JSON Write", T-04-19).

### Task 3: cron.sh marker prune (D-04) + post-install.sh wiring

**scripts/cron.sh:**

- Added `MARKERS_DIR` constant (inlined as `${OPENCLAW_HOME}/skills/revenium/markers`).
- Added `prune_markers()` function: `find "${MARKERS_DIR}" -name '*.jsonl' -mtime +7 -delete 2>/dev/null` — BSD/GNU portable (mirrors existing `-mmin` usage).
- Added `prune_markers || true` in BOTH lock branches (flock + mkdir) AFTER `run_report` and `guardrail-check.sh` calls.
- Fail-open posture: prune failure (`|| true`) never blocks the tick (T-04-17).

**scripts/post-install.sh:**

- Added `write-marker.sh` and `get-root-session-id.py` to the chmod loop (line 114 pattern).
- Added `task-taxonomy.json` seed step: copies `${SKILL_DIR}/task-taxonomy.json` to `${SKILL_DIR}/task-taxonomy.json` if absent; warns (does not fail) if source missing (Pitfall 6 single path — SKILL_DIR == STATE_DIR in OpenClaw).
- Added `mkdir -p "${SKILL_DIR}/markers" && chmod 700 "${SKILL_DIR}/markers"` (ASVS V4 / T-04-18).

## Deviations from Plan

None — plan executed exactly as written. All deviation rules applied to the implementation decisions per D-04/D-08 discretion grants were within plan scope.

## Known Stubs

None. All modified files deliver their full intended behavior. The pre-existing `"Seeded guardrail-status.json placeholder"` info message in `post-install.sh` step 5 is a log string, not a stub.

## Threat Flags

No new security-relevant surface beyond the plan's threat model. All STRIDE threats from the plan register addressed:

| Threat ID | Status |
|-----------|--------|
| T-04-15 | Mitigated: SKILL.md directs only the 8 taxonomy labels; write-marker.sh allowlist rejects anything else; non-`marker written:` output treated as protocol error |
| T-04-16 | Mitigated: D-08 one-time notice in /revenium flow; detection is explicit, persisted, no silent state change |
| T-04-17 | Mitigated: prune_markers || true; prune runs AFTER report.sh + guardrail-check.sh in both lock branches |
| T-04-18 | Mitigated: post-install creates markers/ at mode 0700 (ASVS V4) |
| T-04-19 | Mitigated: config.json _legacyNoticeShown written via atomic temp-then-rename (03-PATTERNS) |

## Self-Check: PASSED

| Item | Status |
|------|--------|
| SKILL.md TASK CLASSIFICATION section | FOUND |
| references/task-classification.md | FOUND |
| SKILL.md: write-marker.sh directive | FOUND |
| SKILL.md: unclassified default | FOUND |
| SKILL.md: no agentic_job_id / JOB DECLARATION | CONFIRMED |
| SKILL.md: legacy notice verbatim string | FOUND |
| SKILL.md: AGENT:IS:OpenClaw detection | FOUND |
| SKILL.md: no forbidden rewrite terms | CONFIRMED |
| scripts/cron.sh: markers + mtime +7 | FOUND |
| scripts/cron.sh: bash -n passes | PASSED |
| scripts/post-install.sh: write-marker.sh chmod | FOUND |
| scripts/post-install.sh: get-root-session-id.py chmod | FOUND |
| scripts/post-install.sh: task-taxonomy.json seed | FOUND |
| scripts/post-install.sh: markers/ 0700 | FOUND |
| scripts/post-install.sh: bash -n passes | PASSED |
| commit 7ccd90b (Task 1) | FOUND |
| commit e98970e (Task 2) | FOUND |
| commit c47251f (Task 3) | FOUND |
