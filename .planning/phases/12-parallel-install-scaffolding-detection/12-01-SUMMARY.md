---
phase: 12-parallel-install-scaffolding-detection
plan: "01"
subsystem: install-scaffolding
status: complete
tags: [bash, install, nemoclaw, detection, test-harness, probe]
dependency_graph:
  requires: []
  provides:
    - scripts/probe-host-compat.sh (preflight probe for plan 02 D-08/D-09)
    - tests/test_install_dispatcher.sh (RED harness for plan 02 routing)
  affects:
    - scripts/install.sh (plan 02 must implement; will turn test GREEN)
    - scripts/post-install-nemoclaw.sh (plan 02 must implement; tested via GROUP A/B/F)
tech_stack:
  added: []
  patterns:
    - STUB_UNAME_S env-var override for hermetic OS detection in tests
    - mktemp -d HOME isolation for controlling ~/.nemoclaw/~/.openclaw presence
    - pass()/fail() PASS/FAIL counter idiom with ((N++)) || true
    - bash subprocess invocation (never source) for probe-host-compat.sh
key_files:
  created:
    - scripts/probe-host-compat.sh
    - tests/test_install_dispatcher.sh
  modified: []
decisions:
  - "probe-host-compat.sh copied verbatim with banner-only edit — exit-code contract (fail>0 -> exit 1, else exit 0) and set -u discipline preserved byte-for-byte"
  - "test_install_dispatcher.sh is RED before plan 02: 3 routing groups fail because install.sh is absent; 7 groups pass (absence-of-markers, idempotency, byte-stability)"
metrics:
  duration: "~2 minutes"
  completed: "2026-06-07"
  tasks_completed: 2
  files_created: 2
  files_modified: 0
---

# Phase 12 Plan 01: Test Harness and Probe Preflight Summary

Hermetic dispatcher test harness (RED) + verbatim probe copy for the parallel install path: `tests/test_install_dispatcher.sh` covers all 7 VALIDATION.md groups using `STUB_UNAME_S` + `mktemp -d` HOME isolation; `scripts/probe-host-compat.sh` is a byte-identical copy of the spike probe with only the banner comment updated.

## Tasks

| # | Name | Commit | Files |
|---|------|--------|-------|
| 1 | Copy probe-host-compat.sh verbatim into scripts/ | ac09477 | scripts/probe-host-compat.sh |
| 2 | Write hermetic test_install_dispatcher.sh covering all VALIDATION rows | c0a61f1 | tests/test_install_dispatcher.sh |

## Verification Results

- `bash -n` clean on both files
- `scripts/probe-host-compat.sh` contains `set -u`, `VERDICT`, `Host Compatibility Preflight`; does NOT contain `set -euo pipefail`; logic diff against source (tail -n +3) is empty
- `tests/test_install_dispatcher.sh` is RED (exit 1, 3 failed) before plan 02 creates `scripts/install.sh`; all 3 failures are due to install.sh absent (127 exit)
- `git diff --name-only HEAD -- scripts/post-install.sh` is empty — byte-stability preserved

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None. This plan creates test infrastructure and a probe; no data sources stubbed.

## Threat Flags

None. No new network endpoints, auth paths, or schema changes introduced.

## Self-Check: PASSED

- [x] scripts/probe-host-compat.sh exists
- [x] tests/test_install_dispatcher.sh exists
- [x] Commit ac09477 exists (Task 1)
- [x] Commit c0a61f1 exists (Task 2)
- [x] Test suite is RED (exit != 0) confirming hermetic behavior
- [x] probe-host-compat.sh logic diff against source is empty
