---
status: partial
phase: 04-task-metering-attribution
source: [04-VERIFICATION.md]
started: 2026-06-03T00:00:00Z
updated: 2026-06-03T00:00:00Z
---

## Current Test

[complete — user accepted phase with 2 residual caveats tracked as Gaps]

## Tests

### 1. Legacy-filter reconfigure notice (D-08) appears exactly once
expected: Run `/revenium` in an agent session with a known legacy rule (`AGENT:IS:OpenClaw`) in Revenium. The verbatim notice — "Your budget rules use the old filter and won't track spend — run reconfigure." — appears exactly once. After closing the session and opening a new one, the notice does NOT reappear (persisted via `_legacyNoticeShown` in config.json). No auto-rewrite of rules occurs.
result: partial — The underlying legacy rule (`4vKdQl`, `AGENT:IS:OpenClaw`) was reconfigured directly to `AGENT:STARTS_WITH:openclaw-` via the CLI during debugging (verified), which is the end state the notice is meant to drive. The in-skill one-time `/revenium` notice itself was NOT independently observed firing. CAVEAT tracked in Gaps.

### 2. Subagent spend rolls up under root session
expected: In a multi-subagent scenario, run a parent session that spawns a subagent. After the cron tick, the subagent's meter completions in Revenium carry `--agent openclaw-<parent-session-id>`, NOT `--agent openclaw-<subagent-session-id>` — enabling spend rollup per root conversation.
result: partial — Agent attribution confirmed working at the data level: real completions emit `openclaw-<session_id>` (verified via `revenium metrics completions`, team DZxzEl) and now match the reconfigured `STARTS_WITH` budget rule. True subagent→root rollup (child completions collapsing under the PARENT uuid) was NOT verified — the test session had no subagents. CAVEAT tracked in Gaps.

### 3. End-to-end task classification reaches Revenium
expected: Run `write-marker.sh` for a valid label (e.g. `generation`), trigger a cron tick, and query Revenium. The completion row shows `task_type=generation` (not `unclassified`) — report.sh correctly correlates the marker to the completion.
result: PASS — Confirmed working by user on the test machine after the correlation fix (commit `48f7e44`, Approach A completion_id keying + Phase D fallback). The original NP-1 timestamp-precedence bug (marker written after completion → never matched → always `unclassified`) is resolved; live-verified `taskType=generation`.

## Summary

total: 3
passed: 1
issues: 0
pending: 0
skipped: 0
blocked: 2

## Gaps

- gap: In-skill D-08 legacy-filter notice on `/revenium` was never independently observed firing. The rule was fixed directly via CLI, so spend tracking is correct, but the agent-side notice path is unverified. Low priority (cosmetic/UX; does not affect metering correctness).
- gap: Subagent→root spend rollup unverified — needs a live parent-spawns-subagent run confirming child completions carry `openclaw-<parent_session_id>` (the root), not the child's own session id. The resolver (`get-root-session-id.py`) and unit tests pass, but end-to-end multi-session attribution is unconfirmed.
