---
status: partial
phase: 14-host-side-metering-loop
source: [14-VERIFICATION.md]
started: 2026-06-08T23:24:16Z
updated: 2026-06-08T23:24:16Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. End-to-end metering loop on the live NemoClaw Linux host
expected: Running `install-nemoclaw-cron.sh` on host 34.224.27.67 with the `revenium-spike` sandbox installs a tagged crontab entry, `nemoclaw-cron-tick.sh` fires at the next minute boundary, the SSHFS mount establishes, and a refreshed `guardrail-status.json` (with `_maxAgeSeconds`) is written back through the mount.
result: [pending]

### 2. GROUP F (D-04) sshfs-missing message on Linux
expected: Running `install-nemoclaw-cron.sh` with no sshfs on PATH includes the string 'sshfs' in the error message and writes no crontab entry. (The non-zero-exit + no-crontab-entry behavior is already verified; only the message content needs Linux confirmation — it fails on macOS due to a documented PATH restriction.)
result: [pending]

## Summary

total: 2
passed: 0
issues: 0
pending: 2
skipped: 0
blocked: 0

## Gaps
