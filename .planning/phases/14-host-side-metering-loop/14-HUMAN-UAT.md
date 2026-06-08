---
status: passed
phase: 14-host-side-metering-loop
source: [14-VERIFICATION.md]
started: 2026-06-08T23:24:16Z
updated: 2026-06-08T23:31:00Z
verified_on: 34.224.27.67 (nemoclaw v0.0.55, sandbox revenium-spike)
verified_by: agent (live-host run)
---

## Current Test

[complete — both items confirmed on the live Linux host]

## Tests

### 1. End-to-end metering loop on the live NemoClaw Linux host
expected: Running `install-nemoclaw-cron.sh` on host 34.224.27.67 with the `revenium-spike` sandbox installs a tagged crontab entry, `nemoclaw-cron-tick.sh` fires at the next minute boundary, the SSHFS mount establishes, and a refreshed `guardrail-status.json` (with `_maxAgeSeconds`) is written back through the mount.
result: PASS — install mounted `/sandbox/.openclaw` → `~/sbx-openclaw-revenium-spike` and wrote a tagged crontab entry (`# revenium-metering-nemoclaw:revenium-spike`). The cron fired automatically (metering log shows unattended ticks at 23:29:01-02Z). `guardrail-status.json` mtime advanced from 2026-06-07 15:03 (stale) to 2026-06-08 23:28:54 (fresh) through the mount, with content `{"_via":"host-mount-cron","_maxAgeSeconds":180,...}`. Real session JSONL logs were present in the mount as input. Uninstall cleanly removed the crontab entry and unmounted. NOTE: the `revenium` CLI is not on this spike host's PATH, so the tick's fail-open metering-skip path fired (`WARN: revenium CLI not found — skipping metering`) — actual metering emission was not exercised (host provisioning gap, not a Phase 14 code defect); the SC1 guardrail-status refresh works regardless.

### 2. GROUP F (D-04) sshfs-missing message on Linux
expected: Running `install-nemoclaw-cron.sh` with no sshfs on PATH includes the string 'sshfs' in the error message and writes no crontab entry. (The non-zero-exit + no-crontab-entry behavior is already verified; only the message content needs Linux confirmation — it fails on macOS due to a documented PATH restriction.)
result: PASS — run with a curated PATH excluding sshfs/apt-get/dnf: exit 1, output contained "sshfs not found — attempting install... ERROR: sshfs not available and auto-install failed. Install sshfs manually (e.g. apt-get install sshfs)" (mentions sshfs), and no crontab entry was written.

## Summary

total: 2
passed: 2
issues: 0
pending: 0
skipped: 0
blocked: 0

## Gaps
