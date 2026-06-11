---
phase: 16-skill-deploy-docs
plan: "03"
subsystem: infra
tags: [nemoclaw, live-validation, e2e, honesty-gate, install-idempotency]

# Dependency graph
requires:
  - phase: 16-skill-deploy-docs (plans 01 and 02)
    provides: install_skill_nemoclaw() with D-02 ready assertion + docs/nemoclaw-setup.md runbook
  - phase: 15-per-turn-enforcement-plugin
    provides: enforcement plugin install path and live sandbox (34.224.27.67 / revenium-spike)
provides:
  - Live SC1/SC2 validation evidence (Commands/Exit/Output) in 16-VALIDATION.md
  - Confirmed: D-02 `✓ ready` assertion fires and passes live (SC1 PASSED)
  - Confirmed: zero undocumented install steps in docs/nemoclaw-setup.md (SC2 PASS)
  - Bug fix: `--force` flag added to `openclaw plugins install` for idempotent enforcement plugin re-installs
  - Follow-up todo: install.sh overall exit-1 at Phase 15 Gate A logged as nemoclaw-install-gate-a-exit1.md
affects: [v1.4-milestone-close, phase-17-if-any, operator-documentation]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Live sandbox validation with CRITICAL HONESTY RULE: record verbatim output, never claim a pass without captured evidence"
    - "Multi-re-run validation protocol: Re-run 1 (discovers bugs) → Re-run 2 (post-code-push) → Re-run 3 (post-fix, confirms repair)"
    - "Idempotent plugin install via --force flag to handle pre-existing extension directories in SSHFS mounts"

key-files:
  created:
    - .planning/phases/16-skill-deploy-docs/16-03-SUMMARY.md
    - .planning/todos/pending/nemoclaw-install-gate-a-exit1.md
  modified:
    - .planning/phases/16-skill-deploy-docs/16-VALIDATION.md (live evidence sections Re-run 1/2/3 + human checkpoint decision)
    - scripts/post-install-nemoclaw.sh (--force flag on openclaw plugins install, line ~205)

key-decisions:
  - "SC1/NCDEPLOY-01 and SC2/NCDEPLOY-02 verified via live Re-run 3 evidence (2026-06-11)"
  - "--force idempotency fix scoped to Phase 16 (authorized deviation): the install script was non-idempotent for enforcement plugin re-installs; fix is correct and immediately testable"
  - "Overall install exit-1 is Phase 15 Gate A (B-01/NCENF-01) limitation — out of scope for Phase 16; tracked as follow-up todo nemoclaw-install-gate-a-exit1"
  - "Re-run 1 undocumented steps (stale clone, rsync workaround) were caused by Phase 16 code not yet pushed to GitHub; resolved by pushing main before Re-run 2"

patterns-established:
  - "Phase-16 validation pattern: three re-runs with progressive bug elimination, each with test setup + verbatim evidence + host restore"
  - "Follow-up todo for known out-of-scope limitation: .planning/todos/pending/ with source, severity, and relate_phase metadata"

requirements-completed: [NCDEPLOY-01, NCDEPLOY-02]

# Metrics
duration: ~120min (across 3 re-run cycles over 2 days)
completed: 2026-06-11
---

# Phase 16 Plan 03: Live SC1/SC2 Validation + --force Idempotency Fix Summary

**Live clean-host doc-driven validation of nemoclaw skill install: SC1 (D-02 ready assertion) PASSED and SC2 (zero undocumented steps) PASS via three re-runs, plus a discovered+fixed --force idempotency bug in the enforcement plugin install step.**

## Performance

- **Duration:** ~120 min (Re-run 1 on 2026-06-10; Re-runs 2+3 plus fix on 2026-06-11)
- **Started:** 2026-06-10T (Re-run 1 evidence captured)
- **Completed:** 2026-06-11
- **Tasks:** 2 (Task 1: live validation; Task 2: human checkpoint — now resolved)
- **Files modified:** 3 (16-VALIDATION.md, scripts/post-install-nemoclaw.sh, new todo file)

## Accomplishments

- SC1/NCDEPLOY-01 PASSED: The D-02 `✓ ready` assertion in `install_skill_nemoclaw()` fired live (not ledger-skipped) across all three re-runs on the live NemoClaw sandbox (34.224.27.67 / revenium-spike). Independent `openclaw skills list` confirmed `✓ ready  💰 revenium` in every run.
- SC2/NCDEPLOY-02 PASS: After the Phase 16 NemoClaw scripts were pushed to GitHub (fixing Re-run 1's critical doc-bug-1), Re-runs 2 and 3 showed zero undocumented steps. Every command run was documented in `docs/nemoclaw-setup.md`.
- Discovered and fixed `--force` idempotency bug: `openclaw plugins install` without `--force` fails on re-installs because the SSHFS copy places the plugin dir before the registry call. Adding `--force` eliminates the "plugin already exists" abort, making the install idempotent for operators who re-run.
- Logged Phase 15 Gate A (B-01/NCENF-01) install exit-1 as a tracked follow-up todo — not a Phase 16 issue.

## Task Commits

Each task was committed atomically:

1. **Task 1 (Re-run 1): Live clean-host SC1/SC2 evidence captured** - `c4cb54b` (docs)
2. **Task 1 (Re-run 2): Post-push fully doc-driven SC2 re-validation** - `533aa62` (docs)
3. **Task 1 (Re-run 2 → Re-run 3): --force idempotency fix** - `faab3be` (fix)
4. **Task 1 (Re-run 3): Post --force-fix end-to-end re-validation** - `888af19` (docs)
5. **Gate A follow-up todo committed by orchestrator** - `5daac3f` (docs)

**Plan metadata commit:** (this summary + VALIDATION.md checkpoint update + STATE.md + ROADMAP.md)

## Files Created/Modified

- `.planning/phases/16-skill-deploy-docs/16-VALIDATION.md` — Added Re-run 1/2/3 live evidence blocks and the human checkpoint decision (Task 2) section; per-task map updated to show all 16-03 tasks green.
- `scripts/post-install-nemoclaw.sh` — Added `--force` to the `openclaw plugins install` call in `install_enforcement_plugin()` to make re-installs idempotent.
- `.planning/todos/pending/nemoclaw-install-gate-a-exit1.md` — Follow-up todo for the Phase 15 Gate A install exit-1 limitation (out of scope for Phase 16).
- `.planning/phases/16-skill-deploy-docs/16-03-SUMMARY.md` — This file.

## Decisions Made

- **SC1 verdict:** PASSED — D-02 assertion fires and passes live; `openclaw skills list` confirms `✓ ready  💰 revenium`. The skill-deploy half of the install is proven correct.
- **SC2 verdict:** PASS — Zero undocumented steps in Re-runs 2 and 3. Re-run 1's undocumented steps (rsync workaround, stale clone removal) were caused by Phase 16 code not being pushed to GitHub yet; that was a pre-validation omission, not a doc bug in the published runbook.
- **Overall install exit-1 classification:** Phase 15 Gate A (B-01/NCENF-01) limitation, not a Phase 16 issue. The `openclaw agent --json` CLI path requires `--agent <id>` on the live Nemotron host. Tracked as follow-up todo; does not block Phase 16 closure.
- **--force fix scope:** Authorized deviation (Rule 1 bug). The non-idempotent install was a genuine bug that would fail any operator re-running the install. Fix is minimal, immediately testable, and does not introduce new behavior for first-time installs.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Added `--force` to `openclaw plugins install` for idempotent enforcement plugin re-installs**
- **Found during:** Task 1 Re-run 2 (post-push validation)
- **Issue:** `post-install-nemoclaw.sh` install_enforcement_plugin() runs `cp -r plugin_dir → SSHFS mount` BEFORE calling `openclaw plugins install`. This means the directory is already present when the registry call runs. Without `--force`, openclaw rejects it with "plugin already exists (delete it first)". Any operator re-running the install hits this failure; the install is NOT idempotent.
- **Fix:** Added `--force` to the `openclaw plugins install` call (~line 205 in scripts/post-install-nemoclaw.sh)
- **Files modified:** `scripts/post-install-nemoclaw.sh`
- **Verification:** Re-run 3 confirmed: "Installed plugin: revenium-enforcement" appears instead of the prior "plugin already exists" abort.
- **Committed in:** `faab3be` (fix(16-03): add --force to openclaw plugins install for idempotent re-install)

---

**Total deviations:** 1 auto-fixed (1 Rule 1 bug)
**Impact on plan:** The --force fix is necessary for operator correctness. No scope creep — the fix addresses a discovered idempotency failure in the install script that would affect any operator running the documented install more than once.

### Follow-up Todo (Out of Scope)

**Gate A install exit-1 (Phase 15 B-01/NCENF-01):** The overall `install.sh --nemoclaw` exits 1 at Phase 15's Gate A verification step because `openclaw agent --json --message ping` requires `--agent <id>` on the live Nemotron host. This is a pre-existing Phase 15 limitation, not caused by any Phase 16 changes. Tracked at `.planning/todos/pending/nemoclaw-install-gate-a-exit1.md`.

## Issues Encountered

- **Re-run 1 critical doc-bug-1 (resolved):** The initial live run discovered the GitHub repo did not yet have the Phase 16 NemoClaw scripts published. The git clone gave the pre-NemoClaw version of the repo. This was resolved by pushing the accumulated phase work to `origin/main` (commit `c4cb54b`). Re-runs 2 and 3 confirmed the repo now contains the correct scripts.
- **Re-run 2 enforcement plugin conflict (resolved by --force fix):** The SSHFS copy places the plugin dir before the registry call, causing `openclaw plugins install` to fail on non-fresh sandboxes. Fixed in Re-run 3 via the `--force` flag.
- **Re-run 3 Gate A exit-1 (tracked as follow-up):** Phase 15 limitation; does not affect SC1 or SC2 verdicts.

## User Setup Required

None — no external service configuration required beyond the existing `REVENIUM_*` environment variables documented in `docs/nemoclaw-setup.md`.

## Next Phase Readiness

Phase 16 is the final phase of the v1.4 NemoClaw/OpenShell Support milestone. With plan 16-03 complete:

- NCDEPLOY-01 and NCDEPLOY-02 are verified.
- All 3/3 plans for Phase 16 are complete.
- All 5/5 phases (12–16) of the v1.4 milestone are complete.
- Remaining open item: Gate A follow-up todo (`.planning/todos/pending/nemoclaw-install-gate-a-exit1.md`) — medium severity, does not block v1.4 milestone close.

---
*Phase: 16-skill-deploy-docs*
*Completed: 2026-06-11*

## Self-Check: PASSED

- [x] `.planning/phases/16-skill-deploy-docs/16-03-SUMMARY.md` — exists (this file)
- [x] `.planning/phases/16-skill-deploy-docs/16-VALIDATION.md` — human checkpoint decision section added
- [x] Commits c4cb54b, 533aa62, faab3be, 888af19, 5daac3f — all confirmed in git log
- [x] SC1/NCDEPLOY-01 PASSED, SC2/NCDEPLOY-02 PASS — human approved 2026-06-11
- [x] Overall install exit-1 documented as Phase 15 Gate A limitation, follow-up todo committed
