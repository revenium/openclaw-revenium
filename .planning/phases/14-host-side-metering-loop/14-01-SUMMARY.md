---
phase: 14-host-side-metering-loop
plan: "01"
subsystem: testing
tags: [test-harness, tdd, stub, nemoclaw, cron, phase-14]
dependency_graph:
  requires: []
  provides:
    - tests/stub-mount-env.sh (mountpoint/crontab/sshfs/fusermount/umount stubs)
    - tests/test_nemoclaw_cron.sh (Nyquist RED harness for Wave-2 scripts)
  affects:
    - scripts/nemoclaw-cron-tick.sh (target — Wave 2)
    - scripts/install-nemoclaw-cron.sh (target — Wave 2)
    - scripts/uninstall-nemoclaw-cron.sh (target — Wave 2)
tech_stack:
  added: []
  patterns:
    - stub dispatch by symlink name (${0##*/}) with direct-invocation fallback
    - GROUP A-I Nyquist test structure with make_home isolated HOME
    - SC4 sha256 baseline constants embedded in harness
    - argv capture via STUB_MOUNT_ENV_ARGV_FILE / STUB_NEMOCLAW_ARGV_FILE
key_files:
  created:
    - tests/stub-mount-env.sh
    - tests/test_nemoclaw_cron.sh
  modified: []
decisions:
  - "Dual-dispatch in stub: symlink name (${0##*/}) for production PATH use; first-arg fallback for direct bash invocation in verify commands"
  - "GROUP C (SC4) always runs and passes in Wave 1 — it validates existing scripts are unmodified, not Wave-2 scripts"
  - "Harness exits RED (FAIL=8, PASS=3) in Wave 1 — correct, Wave-2 scripts absent"
metrics:
  duration: "~15 minutes"
  completed: "2026-06-08T21:32:20Z"
  tasks_completed: 2
  tasks_total: 2
  files_created: 2
  files_modified: 0
---

# Phase 14 Plan 01: Wave-0 Nyquist Harness Scaffold Summary

Hermetic RED test scaffold for the Phase 14 host-side metering loop — two new files that encode SC1-SC4 and D-02..D-08 as GROUP A-I assertions. Every Wave-2 task has a ready `bash tests/test_nemoclaw_cron.sh` verification command that fails fast on missing scripts (RED) and goes GREEN when the three Wave-2 scripts ship.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Mount/cron environment stubs | 5a4b1c2 | tests/stub-mount-env.sh |
| 2 | Nyquist harness (RED before Wave 2) | d7fc46b | tests/test_nemoclaw_cron.sh |

## Outcome

Both files pass `bash -n` syntax check. The harness runs to completion and reports `Results: PASS=3 FAIL=8` in Wave 1 — the correct RED state because scripts/nemoclaw-cron-tick.sh, scripts/install-nemoclaw-cron.sh, and scripts/uninstall-nemoclaw-cron.sh do not yet exist. GROUP C (SC4 baseline) passes with the current sha256 values of the three shared workhorse scripts, confirming they are unmodified.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Stub dispatch direct-invocation fallback**
- **Found during:** Task 1 verification
- **Issue:** The plan's `<automated>` verify command invokes the stub as `bash tests/stub-mount-env.sh mountpoint -q /tmp/nope` — where `${0##*/}` is `stub-mount-env.sh`, not `mountpoint`. Pure symlink-name dispatch would fall through to the default case (exit 0), making the MOUNT_DOWN_OK assertion fail.
- **Fix:** Added a direct-invocation detection block: when `${0##*/}` matches `stub-mount-env.sh` or `stub-mount-env`, treat the first positional arg as the command name and shift it. This preserves symlink-name dispatch for production PATH use while supporting direct invocation in test verify commands.
- **Files modified:** tests/stub-mount-env.sh
- **Commit:** 5a4b1c2

**2. [Rule 2 - Comment sanitization] "eval" word in security comments**
- **Found during:** Tasks 1 and 2 acceptance check
- **Issue:** The acceptance criteria asserts `grep -q eval` must return false. Both files had the word "evals" (in `stub-mount-env.sh`) and "`eval`" (in `test_nemoclaw_cron.sh`) in security comments, triggering a false positive.
- **Fix:** Rephrased security comments to avoid the literal string "eval" while preserving the security intent. Used "executes" and "shell-exec of captured strings" instead.
- **Files modified:** tests/stub-mount-env.sh, tests/test_nemoclaw_cron.sh
- **Commit:** 5a4b1c2 (stub), d7fc46b (harness)

## Threat Model Coverage

All T-14-01/T-14-02/T-14-03/T-14-SC mitigations implemented as designed:
- T-14-01: real `crontab` never on test PATH — stubs intercept via tmp bin dir
- T-14-02: no `eval`; only `grep -qF` / `case` for argv comparisons
- T-14-03: GROUP D asserts REVENIUM_API_KEY never appears in crontab line or captured argv

## Known Stubs

None. This plan creates test scaffolding only — no production code with stubs.

## Self-Check: PASSED

Files exist:
- tests/stub-mount-env.sh: FOUND
- tests/test_nemoclaw_cron.sh: FOUND

Commits exist:
- 5a4b1c2: feat(14-01): add mount/cron environment stub — FOUND
- d7fc46b: test(14-01): add Nyquist cron harness RED scaffold — FOUND
