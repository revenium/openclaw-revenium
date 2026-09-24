---
phase: 16-skill-deploy-docs
plan: "01"
subsystem: nemoclaw-install
status: complete
tags: [nemoclaw, skill-install, bash, install-gate, tdd]
completed: "2026-06-10"
duration: "~8 minutes"

dependency_graph:
  requires: [scripts/post-install-nemoclaw.sh (Phase 15 install_skill_nemoclaw skeleton)]
  provides: [SKILL.md path guard, ready assertion, GROUP I test coverage]
  affects: [scripts/post-install-nemoclaw.sh, tests/stub-nemoclaw.sh, tests/test_nemoclaw_provisioning.sh]

tech_stack:
  added: []
  patterns:
    - "REVENIUM_SKILL_DIR env override hook for hermetic testability"
    - "|| true CR-01 guard on in-sandbox command substitution"
    - "Ledger pre-seeding helper (_seed_phase13_14_ledger) in test harness"

key_files:
  created: []
  modified:
    - scripts/post-install-nemoclaw.sh
    - tests/stub-nemoclaw.sh
    - tests/test_nemoclaw_provisioning.sh

decisions:
  - "Ledger pre-seeding in GROUP I: install_skill_nemoclaw() is guarded by install_metering_loop() which requires sshfs (unavailable in hermetic env); pre-seeding Phase 13+14 ledger keys lets GROUP I exercise only the skill-deploy function without sshfs"
  - "REVENIUM_SKILL_DIR override hook: enables I-a to point at a SKILL.md-less dir without needing the real repo root to lack SKILL.md"
  - "grep 'revenium' | grep -q 'ready' pattern: Unicode-safe (no literal ✓ checkmark) per RESEARCH Open Question 1"

metrics:
  duration: "~8 minutes"
  completed: "2026-06-10"
  tasks_completed: 2
  files_modified: 3
---

# Phase 16 Plan 01: SKILL.md Guard and Ready Assertion Summary

Self-proving skill deploy gate via two fail-hard assertions in `install_skill_nemoclaw()`: SKILL.md path guard prevents SSHFS tainted-path installs, `openclaw skills list` assertion confirms `✓ ready` before writing the ledger key.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Extend stub + add GROUP I (RED) | 1fadd7d | tests/stub-nemoclaw.sh, tests/test_nemoclaw_provisioning.sh |
| 2 | Add SKILL.md guard + ready assertion + fix banner (GREEN) | 88920da | scripts/post-install-nemoclaw.sh, tests/test_nemoclaw_provisioning.sh |

## What Was Built

### scripts/post-install-nemoclaw.sh

Three changes to `install_skill_nemoclaw()`:

1. **REVENIUM_SKILL_DIR override hook** — `skill_dir="${REVENIUM_SKILL_DIR:-${SCRIPT_DIR}/..}"` — testability hook so GROUP I-a can point at a SKILL.md-less dir without affecting production.

2. **SKILL.md path guard (T-16-01)** — inserted before `nemoclaw skill install`:
   ```bash
   if [[ ! -f "${skill_dir}/SKILL.md" ]]; then
       fail "SKILL.md not found at ${skill_dir} — cannot determine skill root. ..."
   fi
   ```
   Prevents the SSHFS unsafe-filename abort that hit every Phase 15 live run by catching a wrong path resolution before the install attempt.

3. **`openclaw skills list` assertion (T-16-02, D-02)** — inserted after `nemoclaw skill install` succeeds but before `ledger_set`:
   ```bash
   _skill_list=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
       "openclaw skills list 2>/dev/null" 2>/dev/null || true)
   if ! echo "${_skill_list}" | grep "revenium" | grep -q "ready"; then
       fail "revenium skill NOT ready after install ..."
   fi
   ```
   The `|| true` is the mandatory CR-01 guard. The `grep "revenium" | grep -q "ready"` pattern is Unicode-safe (no literal `✓`).

4. **Stale banner removed** — replaced `echo " Phase 16 (skill deploy + docs) still pending."` with `echo " Skill:     revenium (✓ ready)"`.

### tests/stub-nemoclaw.sh

Two new dispatch branches:

- **`skill install` handler** — `[[ "${2:-}" == "skill" && "${3:-}" == "install" ]]` exits `STUB_NEMOCLAW_SKILL_INSTALL_RC` (default 0).
- **`openclaw skills list` exec branch** — inside the exec dispatcher, matches `grep -qF "openclaw skills list"` and echoes `STUB_NEMOCLAW_SKILLS_LIST_OUTPUT` (default `✓ ready  💰 revenium`) or `No skills installed.` when `STUB_NEMOCLAW_SKILL_NOT_READY` is set. Both branches `exit 0`.

### tests/test_nemoclaw_provisioning.sh

Added **GROUP I** with three sub-cases:

- **I-a**: `REVENIUM_SKILL_DIR` pointing at a dir with no `SKILL.md` → asserts non-zero exit + "SKILL.md not found" in output.
- **I-b**: `STUB_NEMOCLAW_SKILL_NOT_READY=1` → asserts non-zero exit + "NOT ready" in output.
- **I-c**: default env (ready output) → asserts `skill-installed-nemoclaw=` appears in ledger.

All three cases pre-seed the Phase 13+14 ledger keys (via `_seed_phase13_14_ledger` helper) to skip past `install_metering_loop` (which requires sshfs, unavailable in the hermetic env).

## Test Results

```
Results: 23 passed, 0 failed
```

Sibling suites: `test_install_dispatcher.sh` 10/10, `test_nemoclaw_cron.sh` 22/23 (1 macOS-only sshfs-PATH artifact, pre-existing).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] GROUP I ledger pre-seeding gap**

- **Found during:** Task 1 → Task 2 integration
- **Issue:** The original GROUP I implementation did not pre-seed Phase 13+14 ledger keys. The script aborts at `install_metering_loop` (sshfs unavailable in hermetic env) before reaching `install_skill_nemoclaw`, so GROUP I tests failed for the wrong reason (sshfs error, not missing guard/assertion).
- **Fix:** Added `_seed_phase13_14_ledger` helper to pre-populate `revenium-policy-applied`, `gh-release-policy-applied`, `cli-delivered`, `creds-written`, `meter-probe-passed`, and `metering-loop-installed`; I-c also pre-seeds `enforcement-plugin-installed` to bypass the mount/plugin gate. Each GROUP I case calls this helper before `run_provision`.
- **Files modified:** `tests/test_nemoclaw_provisioning.sh`
- **Commit:** 88920da

## TDD Gate Compliance

- RED gate: commit `1fadd7d` — `test(16-01): extend stub + add GROUP I...`
- GREEN gate: commit `88920da` — `feat(16-01): add SKILL.md guard + ready assertion...`

Both gates present in git log. During RED, GROUP I-a, I-b, I-c were all failing (but for the wrong reason — discovered during GREEN implementation that ledger pre-seeding was needed). The fix to the test infrastructure was applied as part of GREEN (Task 2 scope deviation per Rule 1).

## Known Stubs

None — all stub behavior in `tests/stub-nemoclaw.sh` mirrors real nemoclaw CLI dispatch for the tested paths.

## Threat Surface Scan

No new network endpoints, auth paths, file access patterns, or schema changes introduced. Changes are entirely within bash scripts and test harness. T-16-01 and T-16-02 mitigations are implemented as required.

## Self-Check: PASSED

- SUMMARY.md: FOUND at .planning/phases/16-skill-deploy-docs/16-01-SUMMARY.md
- Commit 1fadd7d (Task 1 RED): FOUND
- Commit 88920da (Task 2 GREEN): FOUND
- scripts/post-install-nemoclaw.sh: FOUND
- tests/stub-nemoclaw.sh: FOUND
- tests/test_nemoclaw_provisioning.sh: FOUND
