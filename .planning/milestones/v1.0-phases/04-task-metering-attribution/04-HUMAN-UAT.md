---
status: complete
phase: 04-task-metering-attribution
source: [04-VERIFICATION.md]
started: 2026-06-03T00:00:00Z
updated: 2026-06-03T00:00:00Z
---

## Current Test

[complete — all 3 scenarios verified by user on 2026-06-03]

## Tests

### 1. Legacy-filter reconfigure notice (D-08) appears exactly once
expected: Run `/revenium` in an agent session with a known legacy rule (`AGENT:IS:OpenClaw`) in Revenium. The verbatim notice — "Your budget rules use the old filter and won't track spend — run reconfigure." — appears exactly once. After closing the session and opening a new one, the notice does NOT reappear (persisted via `_legacyNoticeShown` in config.json). No auto-rewrite of rules occurs.
result: PASS — User confirmed 2026-06-03: the in-skill `/revenium` legacy notice fires as designed. (The underlying rule was also reconfigured to `AGENT:STARTS_WITH:openclaw-` during debugging.)

### 2. Subagent spend rolls up under root session
expected: In a multi-subagent scenario, run a parent session that spawns a subagent. After the cron tick, the subagent's meter completions in Revenium carry `--agent openclaw-<parent-session-id>`, NOT `--agent openclaw-<subagent-session-id>` — enabling spend rollup per root conversation.
result: PASS — User confirmed 2026-06-03: subagent completions roll up under the root session's `openclaw-<parent_session_id>` agent, verified end-to-end with a live parent-spawns-subagent run. Agent attribution also verified at the data level via `revenium metrics completions` (team DZxzEl).

### 3. End-to-end task classification reaches Revenium
expected: Run `write-marker.sh` for a valid label (e.g. `generation`), trigger a cron tick, and query Revenium. The completion row shows `task_type=generation` (not `unclassified`) — report.sh correctly correlates the marker to the completion.
result: PASS — Confirmed working by user on the test machine after the correlation fix (commit `48f7e44`, Approach A completion_id keying + Phase D fallback). The original NP-1 timestamp-precedence bug (marker written after completion → never matched → always `unclassified`) is resolved; live-verified `taskType=generation`.

## Summary

total: 3
passed: 3
issues: 0
pending: 0
skipped: 0
blocked: 0

## Gaps

(None — all scenarios verified by user on 2026-06-03. The two prior caveats — legacy-notice firing and subagent→root rollup — both checked out.)
