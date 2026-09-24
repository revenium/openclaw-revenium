---
phase: 14-host-side-metering-loop
plan: "03"
subsystem: scripts
tags: [cron, nemoclaw, uninstall, host-metering, post-install, wave-3, sc4]
dependency_graph:
  requires:
    - scripts/install-nemoclaw-cron.sh (Wave-2 installer — invoked by post-install)
    - tests/test_nemoclaw_cron.sh (Wave-1 Nyquist harness — GROUP H asserts)
    - tests/stub-mount-env.sh (crontab/mountpoint/fusermount stubs for GROUP H)
  provides:
    - scripts/uninstall-nemoclaw-cron.sh (per-sandbox NemoClaw cron uninstaller)
    - scripts/post-install-nemoclaw.sh (stub replaced — real ledger-gated metering loop)
  affects:
    - NCMETER-01 (now fully delivered end-to-end — install path wired)
tech_stack:
  added: []
  patterns:
    - Two-step capture-then-write crontab pattern (avoids read/write race)
    - Sandbox-scoped marker removal via grep -vF (T-14-07)
    - Fail-open unmount with mountpoint -q gate (T-14-08)
    - Ledger-gated provisioning step (metering-loop-installed key)
    - Existing helpers reused: step/info/fail/ledger_has/ledger_set/SCRIPT_DIR/SANDBOX_NAME
key_files:
  created:
    - scripts/uninstall-nemoclaw-cron.sh
  modified:
    - scripts/post-install-nemoclaw.sh (stub_install_metering_loop replaced with real install_metering_loop)
decisions:
  - "Two-step crontab pattern (capture-then-write) required: single pipeline crontab -l | grep | crontab - has a read/write race on the stub file (crontab - truncates before crontab -l finishes reading); installer already uses two-step — uninstaller mirrors that pattern"
  - "install_metering_loop reuses only existing helpers (step/info/fail/ledger_has/ledger_set/SCRIPT_DIR/SANDBOX_NAME) — no new helpers invented per plan constraint"
metrics:
  duration: "~15 minutes"
  completed: "2026-06-08T21:51:27Z"
  tasks_completed: 2
  tasks_total: 2
  files_created: 1
  files_modified: 1
---

# Phase 14 Plan 03: Uninstaller + Post-Install Wiring Summary

Per-sandbox NemoClaw cron uninstaller with sandbox-scoped `grep -vF` removal and fail-open unmount; `post-install-nemoclaw.sh` stub replaced with a real ledger-gated `install_metering_loop` that invokes `install-nemoclaw-cron.sh --sandbox "${SANDBOX_NAME}"` — making NCMETER-01 fire during actual NemoClaw provisioning.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Per-sandbox uninstaller (scripts/uninstall-nemoclaw-cron.sh) | bedc449 | scripts/uninstall-nemoclaw-cron.sh |
| 2 | Wire install_metering_loop into post-install-nemoclaw.sh + SC4 guard | c9a243a | scripts/post-install-nemoclaw.sh |

## Outcome

Both scripts pass `bash -n` syntax check. The harness runs and reports `PASS=22 FAIL=1`:
- GROUP A/B/C/D/E/G/H/I: PASS (all required groups)
- GROUP F: 1 assertion fails on macOS only (pre-existing limitation from Plan 02 — documented there, not a regression)

SC4 sha256 verification: `shasum -a 256 -c` reports OK for all three baseline scripts (cron.sh / report.sh / guardrail-check.sh). No workhorse scripts were modified.

`grep -F stub_install_metering_loop scripts/post-install-nemoclaw.sh` matches nothing — stub fully removed.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Single-pipeline crontab -l | grep -vF | crontab - has read/write race**
- **Found during:** Task 1 test harness verification (GROUP H assertion "standalone # revenium-metering preserved after uninstall" failing)
- **Issue:** The plan's pattern map shows `uninstall-cron.sh` using `crontab -l | grep -v | crontab -` as a single pipeline. In the hermetic test environment, the `crontab -` stub truncates `STUB_CRONTAB_FILE` on open (via `cat > file`) while `crontab -l` is still reading from the same file. The race caused the entire crontab to be lost, including the standalone line.
- **Fix:** Changed to the two-step pattern already used by `install-nemoclaw-cron.sh`:
  1. Capture: `REMAINING="$(crontab -l 2>/dev/null | grep -vF "${CRON_MARKER}" || true)"`
  2. Write: `if [[ -n "${REMAINING}" ]]; then printf '%s\n' "${REMAINING}" | crontab -; else echo "" | crontab -; fi`
- **Files modified:** scripts/uninstall-nemoclaw-cron.sh
- **Commit:** bedc449

## Threat Model Coverage

All T-14-07/T-14-08/T-14-09/T-14-SC mitigations implemented:
- T-14-07: `grep -vF "${CRON_MARKER}"` on the exact sandbox-scoped marker — standalone `# revenium-metering` and other sandboxes' markers are never matched (GROUP H asserts)
- T-14-08: `mountpoint -q "${MNT}"` gate before unmount; `fusermount -u || umount || true` makes absent/busy mount fail-open
- T-14-09: SC4 `shasum -a 256 -c` against three recorded baselines — all report OK (no workhorse touched)
- T-14-SC: No packages installed; no Package Legitimacy Gate triggered

## Known Stubs

None. All scripts are fully implemented with no placeholder logic. `stub_install_metering_loop` in `post-install-nemoclaw.sh` has been replaced with the real `install_metering_loop`.

## Threat Flags

None. No new network endpoints, auth paths, or schema changes introduced beyond what the threat model covers.

## Self-Check: PASSED

Files exist:
- scripts/uninstall-nemoclaw-cron.sh: FOUND
- scripts/post-install-nemoclaw.sh (modified): FOUND

Commits exist:
- bedc449: feat(14-03): add per-sandbox NemoClaw cron uninstaller — FOUND
- c9a243a: feat(14-03): wire real install_metering_loop into post-install-nemoclaw.sh — FOUND
