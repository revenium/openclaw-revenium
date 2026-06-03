---
status: partial
phase: 04-task-metering-attribution
source: [04-VERIFICATION.md]
started: 2026-06-03T00:00:00Z
updated: 2026-06-03T00:00:00Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. Legacy-filter reconfigure notice (D-08) appears exactly once
expected: Run `/revenium` in an agent session with a known legacy rule (`AGENT:IS:OpenClaw`) in Revenium. The verbatim notice — "Your budget rules use the old filter and won't track spend — run reconfigure." — appears exactly once. After closing the session and opening a new one, the notice does NOT reappear (persisted via `_legacyNoticeShown` in config.json). No auto-rewrite of rules occurs.
result: [pending]

### 2. Subagent spend rolls up under root session
expected: In a multi-subagent scenario, run a parent session that spawns a subagent. After the cron tick, the subagent's meter completions in Revenium carry `--agent openclaw-<parent-session-id>`, NOT `--agent openclaw-<subagent-session-id>` — enabling spend rollup per root conversation.
result: [pending]

### 3. End-to-end task classification reaches Revenium
expected: Run `write-marker.sh` for a valid label (e.g. `generation`), trigger a cron tick, and query Revenium. The completion row shows `task_type=generation` (not `unclassified`) — the timestamp-precedence correlation in report.sh correctly matched the marker to the completion. (Also exercises the WR-02 same-second timestamp tie edge case.)
result: [pending]

## Summary

total: 3
passed: 0
issues: 0
pending: 3
skipped: 0
blocked: 0

## Gaps
